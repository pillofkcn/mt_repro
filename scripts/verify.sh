#!/usr/bin/env bash
# =============================================================================
# What a clean room can check about the benchmark, cheapest check first.
#
# plan/LOCK.json holds seven keys (scripts/lock_plan.py): plan_sha256, commit,
# data, models, downloaded_models, versions and locked_at. Some of them can be
# rechecked on a machine that has nothing but the repository and a network
# connection. Others cannot: `models` is the digest of five models this project
# TRAINS, and training them takes about 3 h 15 min on a CPU (setup.sh). So this
# script checks what it can reach and says plainly what it skipped, rather than
# reporting a green run that silently covered less than the lock does.
#
# Exit status is the number of checks that failed, so a caller can tell "the
# data moved" from "the plan moved" without parsing the output.
# =============================================================================
set -uo pipefail

cd /app/prog

FAILED=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=$((FAILED + 1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }

echo "============================================================"
echo " Environment"
echo "============================================================"
echo "  python    $(python -V 2>&1 | cut -d' ' -f2)"
echo "  commit    $(git rev-parse HEAD 2>/dev/null || echo '(no git)')"
echo "  tree      $(test -z "$(git status --porcelain -- . 2>/dev/null)" && echo clean || echo DIRTY)"
echo "  platform  $(python -c 'import platform;print(platform.platform())')"
echo "  lock made on $(python -c "import json;print(json.load(open('plan/LOCK.json'))['versions']['platform'])" 2>/dev/null || echo '?')"
echo

# -----------------------------------------------------------------------------
# 1. The project imports at all.
# -----------------------------------------------------------------------------
# First because every later check imports it, and an import error here is a
# packaging problem, not a reproducibility one. Worth separating: "pip install -e .
# produced something that cannot be imported" is a different bug report from
# "the data moved".
echo "============================================================"
echo " 1. Package imports"
echo "============================================================"
if python -c 'import syntactic_analysis' 2>/tmp/import.err; then
    pass "import syntactic_analysis"
else
    fail "import syntactic_analysis"
    sed 's/^/        /' /tmp/import.err
fi
echo

# -----------------------------------------------------------------------------
# 2. The plan still has the digest the lock recorded.
# -----------------------------------------------------------------------------
# Through the project's own Plan.sha256 and not sha256sum, because the digest is
# taken with CRLF read as LF (lock_plan.py): a checkout on a machine that
# normalises line endings would otherwise disagree with the lock over a file
# nobody edited. That is precisely the class of false alarm a clean room exists
# to rule out, so it must not be the clean room that raises it.
echo "============================================================"
echo " 2. Plan digest vs plan/LOCK.json"
echo "============================================================"
python /usr/local/bin/check_plan_digest.py
if [ $? -eq 0 ]; then pass "plan/v1.yaml digest matches the lock"
else fail "plan/v1.yaml digest does not match the lock"; fi
echo

# -----------------------------------------------------------------------------
# 3. The pinned datasets are byte-for-byte the ones the lock names.
# -----------------------------------------------------------------------------
# fetch_data.py takes each dataset the plan pins to a GitHub repository at a ref
# and records its digest; --verify-only re-reads the local copy with no network
# at all. Both are run: the first proves the pinned ref still serves those bytes,
# the second proves the copy on this disk is them. Running only the first would
# check the network, not the data.
#
# Note what this does NOT separate on its own: fetch_data.py also counts the
# format, and exits 1 if a line fails to parse. A digest can match while the
# count fails - that is not a contradiction, it means the reader changed, not
# the data. Check 3b is what tells those two apart.
echo "============================================================"
echo " 3. Pinned datasets"
echo "============================================================"
if python scripts/fetch_data.py > /tmp/fetch.log 2>&1; then
    pass "fetch_data.py (pinned refs serve the recorded bytes; format counts agree)"
else
    fail "fetch_data.py"
    grep -E "PROBLEM|does not match|FAILED" /tmp/fetch.log | sed 's/^/        /' | head -10
    echo "        (full log: /tmp/fetch.log)"
fi

if python scripts/fetch_data.py --verify-only > /tmp/verify.log 2>&1; then
    pass "fetch_data.py --verify-only (local copy matches its digests)"
else
    fail "fetch_data.py --verify-only"
    grep -E "PROBLEM|does not match|FAILED" /tmp/verify.log | sed 's/^/        /' | head -10
fi

# EWT is not among them: the plan gives it no `source`, so fetch_data.py leaves
# it alone, yet the lock's `data` key records it (ewt_test). The image downloads
# it at build time and checks it against data/en_ewt-ud-test.conllu.sha256
# (Dockerfile); this re-hashes the file on disk against the lock's own record,
# through the project's seal, so check 3 covers ewt_test as it covers the two
# confirmatory sets.
python /usr/local/bin/check_lock_data.py ewt_test
if [ $? -eq 0 ]; then pass "ewt_test (EWT r2.17 test split, fetched at build) matches the lock"
else fail "ewt_test does not match the lock"; fi

# WSJ section 01 (wsj_01), the other exploratory set: NLTK's treebank sample,
# read through NLTK rather than from data/, so its files are looked up where
# NLTK finds them. The image downloads it at build time and checks it there
# too (Dockerfile); NLTK's index pins no ref, so these 100 digests are what
# would show that it changed. The offline switch makes a missing sample a
# failure here rather than a download.
SYNTACTIC_ANALYSIS_OFFLINE=1 python /usr/local/bin/check_lock_data.py wsj_01
if [ $? -eq 0 ]; then pass "wsj_01 (NLTK treebank sample, WSJ section 01, fetched at build) matches the lock"
else fail "wsj_01 does not match the lock"; fi
echo

# -----------------------------------------------------------------------------
# 3b. The installed versions are the ones the lock recorded.
# -----------------------------------------------------------------------------
# plan/LOCK.json carries a `versions` block - python, platform and a libraries
# map - so the lock itself says which environment produced the numbers. This is
# the check that explains a failure in 3 rather than just reporting it.
#
# It earned its place on the first run of this room: pyproject's range
# nltk>=3.9,<4 resolved to 3.10.4, where Tree.fromstring no longer accepts the
# escaped leaf at line 514 of MCTB's dialogue file. 999 trees where DATASET.md
# records 1000 - a sealed dataset failing its own format check while its digest
# still matched. The lock pins 3.9.3, where it parses.
#
# Reported, not failed: the verify image installs only the core packages, so
# every analyzer is legitimately absent here.
echo "============================================================"
echo " 3b. Installed versions vs the lock"
echo "============================================================"
python /usr/local/bin/check_versions.py
pass "version report written (drift is reported, not failed)"
echo

# -----------------------------------------------------------------------------
# 4. The parts of the lock this room cannot reach.
# -----------------------------------------------------------------------------
echo "============================================================"
echo " 4. Not checked here"
echo "============================================================"
skip "lock key 'models' - the five trained models are not in the image"
echo "        scripts/lock_plan.py recomputes every key and needs them on disk."
echo "        Build the 'full' target and run setup.sh to get them, or use the"
echo "        smoke job, which runs whatever model_cache/ holds."
skip "lock key 'commit' - mt_public is a squashed publication of the project"
echo "        The lock names the commit it was computed from, in the original"
echo "        repository. mt_public has a history of its own, so that hash is"
echo "        not reachable here and recomputing the key would always differ."
skip "lock key 'downloaded_models' - the published files each configuration loads"
echo "        Per configuration, the digest of every file its load reads that the"
echo "        project does not train: spaCy's en_core_web_sm, NLTK's tagger and"
echo "        WSJ section 00, Stanza's resources. The project checks them with"
echo "        seal.verify_model right before each load of a confirmatory run;"
echo "        smoke_plan.py does not call it, and nothing here does yet."
echo

echo "============================================================"
if [ "$FAILED" -eq 0 ]; then
    printf ' \033[32mAll reachable checks passed.\033[0m\n'
else
    printf ' \033[31m%s check(s) failed.\033[0m\n' "$FAILED"
fi
echo "============================================================"
exit "$FAILED"
