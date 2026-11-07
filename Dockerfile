# Clean-room image for the syntactic-analysis benchmark (pillofkcn/mt_public).
#
# The benchmark already checks itself: plan/LOCK.json pins the plan digest, the
# commit, the data digests and the model digests, and scripts/fetch_data.py and
# scripts/lock_plan.py recompute them. What none of that establishes is that the
# checks pass anywhere other than the machine they were written on. This image
# is the missing half: the same checks, on a base image pinned by digest, with
# nothing on it but what is installed here.
#
# Three targets, cheapest first. Each one installs only what its checks need, so
# a failure says which layer broke rather than "the environment".
#
#   verify  core only (numpy, nltk, pyyaml) - digests and the plan lock
#   smoke   + the analyzers that run on CPU without torch
#   full    + requirements-lock.txt, the exact environment of version 1.0
#
# The lock was taken on Python 3.13.0 (requirements.lock header) and pyproject
# declares >=3.10,<3.14, so the base is 3.13 and not "3" or "latest": a base that
# floats would eventually move to 3.14, where spaCy fails through pydantic v1,
# and it would fail on a commit that changed nothing.
#
# The tag is also pinned to the digest it resolved to on the first build. A tag
# is rebuilt for security patches, so it is the last thing in this chain that
# could move between runs: MT_REF names a commit and the core packages come from
# the lock, but the same tag can name a different image after its next rebuild.
# Given both, Docker pulls by the digest and ignores the tag, so PYTHON_VERSION
# only documents which version the digest is - bump the two together, with the
# new digest from `docker buildx imagetools inspect python:<tag>`. The digest is
# the multi-platform index, not the amd64 manifest, so arm64 hosts still build.
ARG PYTHON_VERSION=3.13.0

# =============================================================================
# Stage: source
# =============================================================================
# The project is NOT vendored here. It is cloned at a ref the caller names, so
# this repository holds no copy of the thesis code that could drift from it, and
# the image records which commit it was built from.
#
# MT_REF defaults to nothing on purpose: an image built from "main" would be a
# different image next week under the same tag, which is the failure this whole
# repository exists to catch. Pass a full commit hash.
FROM python:${PYTHON_VERSION}-slim-bookworm@sha256:0de818129b26ed8f46fd772f540c80e277b67a28229531a1ba0fdacfaed19bcb AS source

ARG MT_REPO=https://github.com/pillofkcn/mt_public.git
ARG MT_REF

RUN test -n "${MT_REF}" || { \
      echo "ERROR: build with --build-arg MT_REF=<full commit hash>." >&2; \
      echo "       A floating ref would make this image unreproducible." >&2; \
      exit 2; }

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Fetch the one commit rather than the history: the image needs the tree, and
# scripts/lock_plan.py needs a git repository whose HEAD is that commit and
# whose working tree is clean. A shallow fetch of the exact object gives both.
WORKDIR /src
RUN git init -q . \
 && git remote add origin "${MT_REPO}" \
 && git fetch -q --depth 1 origin "${MT_REF}" \
 && git checkout -q FETCH_HEAD \
 && git rev-parse HEAD > /src/COMMIT

# =============================================================================
# Stage: verify
# =============================================================================
FROM python:${PYTHON_VERSION}-slim-bookworm@sha256:0de818129b26ed8f46fd772f540c80e277b67a28229531a1ba0fdacfaed19bcb AS verify

# PYTHONDONTWRITEBYTECODE: __pycache__ written as root into a bind-mounted
# checkout is a nuisance to delete from the host afterwards, and the project's
# .gitignore already treats stray artefacts as something that makes `git status`
# dirty - which lock_plan.py refuses to lock against.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# git is needed at RUN time, not only at build time: provenance.collect_provenance
# shells out to git to record the commit and whether the tree is dirty, and
# lock_plan.py refuses to run where `git status --porcelain` cannot be taken.
# curl fetches the EWT test split below, the way setup.sh does.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# A non-root user, because the smoke target writes results/ and a bind mount
# would otherwise come back owned by root on the host. 1000 is simply a fixed,
# non-root uid. It is not chosen to match any host user, and on GitHub Actions
# it does not: the runner user there is uid 1001. The workflow and `make smoke`
# make the directories they mount writable instead of trying to match the host
# uid.
RUN useradd --create-home --uid 1000 runner

COPY --from=source --chown=runner:runner /src /app
WORKDIR /app/prog

# git refuses to operate on a tree owned by another user; the copy above is
# already chowned, but a bind mount at runtime may not be.
RUN git config --system --add safe.directory /app \
 && git config --system --add safe.directory '*'

USER runner

# Core only. pyproject declares numpy, nltk and pyyaml as real dependencies
# (evaluation/evalb.py imports nltk.Tree, plan.py reads plan/v1.yaml), so this
# is enough to load the plan, hash the data and recompute the lock - and not
# enough to run a single analyzer, which is the point: if this layer fails, the
# problem is the project, not an analyzer.
#
# Pinned from plan/LOCK.json rather than resolved from pyproject's ranges. This
# is not caution in the abstract: the first clean-room run of this repository
# installed nltk 3.10.4 under the range ">=3.9,<4", and 3.10.4 changed how
# Tree.fromstring handles an escaped leaf, so the lone "\" token at line 514 of
# MCTB's dialogue.cleaned.txt stopped parsing - 999 trees where DATASET.md
# records 1000, and scripts/fetch_data.py exiting 1 on a dataset whose bytes
# still matched their digest. The lock pins 3.9.3, where it parses.
#
# Taking the pins from the lock rather than writing them here means this image
# follows the project when the project relocks, and cannot drift from it.
RUN python - <<'PY' > /tmp/core-pins.txt
import json
libs = json.load(open("plan/LOCK.json", encoding="utf-8"))["versions"]["libraries"]
for name in ("numpy", "nltk", "pyyaml"):
    version = libs.get(name)
    if version:
        print(f"{name}=={version}")
PY
RUN cat /tmp/core-pins.txt \
 && python -m pip install --no-cache-dir -r /tmp/core-pins.txt \
 && python -m pip install --no-cache-dir -e . --no-deps

# The EWT test split, release r2.17: the exploratory set every number of version
# 1.0 was measured on, and the `ewt_test` entry of the lock's `data` key.
# scripts/fetch_data.py fetches only the datasets the plan gives a `source`, and
# EWT has none - setup.sh downloads it (step 4) - so the image does it here, the
# same way: the release tag, curl -f, and the digest the project records in
# data/en_ewt-ud-test.conllu.sha256.
#
# At build time and in this stage, not in verify.sh: smoke is FROM verify and
# runs smoke_plan.py directly, so a download at run time would never reach it.
# CI builds from scratch on every run, so a moved r2.17 tag fails the weekly
# build loudly. verify.sh check 3 then re-hashes the file on disk against the
# lock itself. data/*.conllu is in the project's .gitignore, so the tree stays
# clean.
RUN curl -fsSL --retry 3 --retry-delay 2 \
      https://raw.githubusercontent.com/UniversalDependencies/UD_English-EWT/r2.17/en_ewt-ud-test.conllu \
      -o data/en_ewt-ud-test.conllu \
 && (cd data && sha256sum -c en_ewt-ud-test.conllu.sha256)

COPY --chown=runner:runner scripts/verify.sh /usr/local/bin/verify.sh
COPY --chown=runner:runner scripts/check_plan_digest.py /usr/local/bin/check_plan_digest.py
COPY --chown=runner:runner scripts/check_versions.py /usr/local/bin/check_versions.py
COPY --chown=runner:runner scripts/check_lock_data.py /usr/local/bin/check_lock_data.py

CMD ["bash", "/usr/local/bin/verify.sh"]

# =============================================================================
# Stage: smoke
# =============================================================================
# The analyzers that run on CPU without torch. Of the sixteen configurations of
# plan/v1.yaml, seven pull torch (the five stanza_*, benepar, supar_con) and
# with it CUDA wheels and, for the electra-large rows, a 1.3 GB transformer.
# Those belong in `full` and on a machine with time, not in a CI job.
#
# The remaining nine are rdr_ewt, nltk_pre, nltk_ewt, udpipe_ewt, spacy_sm,
# spacy_ewt, nltk_arc, pcfg_words and pcfg_tags. Five of them load a model this
# project TRAINS (setup.sh: about 3 h 15 min from zero on a CPU), so the image
# does not train them. The CI workflow caches model_cache/ and passes the keys
# it has; with an empty cache only spacy_sm and the two PCFG rows run.
FROM verify AS smoke

USER root
# spaCy builds nothing here (3.8 ships wheels for 3.13), but ufal.udpipe is a
# source distribution and needs a compiler. Installed in this stage only, so the
# verify image stays small.
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*
USER runner

RUN python -m pip install --no-cache-dir -e ".[spacy,udpipe,nltk-extra]"

# Keep the caches inside the image rather than in the user's home by default, so
# a bind mount of model_cache/ is the only thing that needs to persist.
ENV NLTK_DATA=/app/prog/model_cache/nltk_data

CMD ["python", "scripts/smoke_plan.py", "--sentences", "5"]

# =============================================================================
# Stage: full
# =============================================================================
# requirements-lock.txt is the pip freeze of the environment that produced the
# version 1.0 results. It installs torch and transformers, so this image is
# several gigabytes and is not what CI builds - it is what you build when you
# want to re-run the thesis numbers rather than check that the project is intact.
#
# --no-deps after the lock, matching setup.sh's LOCKED=1 path: the lock already
# names every transitive version, and letting pip resolve again would defeat it.
FROM smoke AS full

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/*
USER runner

RUN python -m pip install --no-cache-dir -r requirements-lock.txt \
 && python -m pip install --no-cache-dir -e . --no-deps

CMD ["bash"]
