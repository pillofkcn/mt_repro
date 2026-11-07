# mt-repro

[![verify](https://github.com/pillofkcn/mt_repro/actions/workflows/ci.yml/badge.svg)](https://github.com/pillofkcn/mt_repro/actions/workflows/ci.yml)

A clean room for [`pillofkcn/mt_public`](https://github.com/pillofkcn/mt_public), the
syntactic-analysis benchmark behind my master's thesis.

## Why this exists

The benchmark already checks itself, and fairly hard. `plan/v1.yaml` declares the
experiment before it runs; `plan/LOCK.json` pins the plan's digest, the commit it was
computed from, the SHA-256 of every dataset file and the digests of the five models the
project trains; `scripts/fetch_data.py` re-verifies the corpora against those digests
without touching the network; every run writes its own frozen evidence under
`results/evidence/`, so each number in the thesis traces back to the measurement that
produced it.

What none of that establishes is that any of it passes **anywhere other than the machine
it was written on** — one Windows laptop, one virtualenv, one `pip freeze`. "Reproducible"
was a property the repository asserted about itself, checked only where it had always been
checked.

This repository runs those same checks in a container built from a pinned base image, on a
commit named by its full hash, on every push and once a week. The claim becomes something
CI either passes or fails.

The lock says as much itself. Its `versions` block records
`platform = Windows-11-10.0.26300-SP0`: the environment that produced every number in the
thesis was one Windows machine, and the lock documents that in its own data. Linux in a
container is not a nicety here — it is the dimension nothing had varied along.

The weekly run is the part I would defend hardest. The two confirmatory datasets are
pinned to GitHub repositories at a ref — and a ref can be force-pushed, a repository
renamed or made private. Neither repository would notice. A scheduled fetch notices within
a week.

## What it found on the first run

A reproducibility defect in the project it checks.

`pyproject.toml` declares `nltk>=3.9,<4`. That range resolves to 3.10.4 today, and 3.10.4
changed how `Tree.fromstring` handles an escaped leaf. Line 514 of MCTB's
`dialogue.cleaned.txt` contains a lone `\` as a token:

```
(TOP (S (NN \) (NP (PRP it)) (VP (VP (VBD started) ...
```

| nltk | `dialogue.cleaned.txt` | `data/DATASET.md` records |
|---|---|---|
| 3.9.3 — what the lock pins | 1000 trees, 0 unparsable | 1000 |
| 3.10.4 — what the range resolves to | 999 trees, 1 unparsable | — |

So `scripts/fetch_data.py` exits 1 on a sealed dataset **whose SHA-256 still matches its
recorded digest**. The bytes never moved; the reader did.

The thesis numbers are unaffected — they were produced on 3.9.3, which the lock pins and
which `setup.sh LOCKED=1` installs. What is affected is anyone who installs the project
the default way today. The lock was right and the range was too wide, and nothing would
have reported that until someone installed from scratch on a machine that had never seen
the project.

That is the whole argument for this repository in one bug, so the `verify` image now pins
its core packages from `plan/LOCK.json` rather than resolving the ranges, and check 3b
reports version drift precisely so that a digest match with a format failure reads as
"the reader changed" instead of "the data moved".

## What it checks

| | Check | Where |
|---|---|---|
| 1 | The package imports at all | `verify` |
| 2 | `plan/v1.yaml` still has the digest `plan/LOCK.json` recorded | `verify` |
| 3 | The pinned refs still serve the recorded bytes | `verify` |
| 4 | The local copy of the data matches its digests, with no network | `verify` |
| 5 | The EWT test split, fetched from release r2.17 at build time, matches the lock | `verify` |
| 6 | Every reachable configuration builds, loads and scores against gold | `smoke` |

Check 2 goes through the project's own `Plan.sha256` rather than `sha256sum`, because the
digest is taken with CRLF read as LF. A checkout on a machine that normalises line endings
would otherwise disagree with the lock about a file nobody edited — exactly the false
alarm a clean room exists to rule out, so it must not be the clean room raising it.

## What it deliberately does not check

**The `models` key of the lock.** It is the digest of five models the project trains, and
training them from zero takes about 3 h 15 min on a CPU. A CI job that did it on every
push would take three hours and nobody would read it. `scripts/verify.sh` reports this as
`SKIP` with the reason, rather than printing green over a run that covered less than the
lock does.

**WSJ section 01, the `wsj_01` entry of the lock's `data` key.** It is NLTK's Penn
Treebank sample, which `nltk.download` serves from the nltk_data index rather than from a
pinned ref, and the `verify` image does not download NLTK data. `verify.sh` reports it as
`SKIP` with that reason.

**Seven of the sixteen configurations.** The five `stanza_*` rows, `benepar` and
`supar_con` pull in torch, and the `electra-large` rows additionally load a 1.3 GB
transformer. Those belong in the `full` image and on a machine with time. The `smoke`
image carries the nine that run on CPU without torch.

Of those nine, five load a model the project trains, so they are only as available as the
GitHub Actions cache. On a cache miss the job runs the rows that need no trained model and
says which it skipped — a short green run instead of nine red ones.

## Running it

```bash
make verify     # the cheap checks: plan digest, pinned datasets
make smoke      # build and run every configuration the image can reach
make shell      # a shell in the full image, for re-running the thesis numbers
make dev        # check a local working copy instead of a clone
```

Override the commit under test:

```bash
make verify MT_REF=<full 40-char hash>
```

## Design notes

**The project is not vendored here.** It is cloned inside the image at the commit named in
`MT_COMMIT`, so this repository holds no copy that could drift from the original, and the
image records what it was built from. The build *refuses to start* without an explicit
`MT_REF`: an image built from `main` would be a different image next week under the same
tag, which is the failure this repository exists to catch.

**Three targets, cheapest first.** `verify` installs the core dependencies only — enough
to load the plan and hash the data, and not enough to run a single analyzer. That is the
point: if `verify` fails, the problem is the project or the data, not an analyzer. `smoke`
adds the torch-free analyzers; `full` installs `requirements-lock.txt`, the exact
environment that produced the version 1.0 results.

**The base image is pinned to Python 3.13, not `3` or `latest`.** The lock was taken on
3.13.0 and `pyproject.toml` declares `>=3.10,<3.14`, because spaCy fails on 3.14 through
pydantic v1. A floating base would eventually move there and fail on a commit that changed
nothing. The tag is in turn pinned to its digest: a tag is rebuilt for security patches,
so it was the last thing in the chain that could still move between runs.

**`MT_COMMIT` is a file, not a workflow variable,** so bumping the commit under test is a
one-line diff with a reason in the message, and the `Makefile` and the workflow cannot
drift over which commit is current.

**`make dev` is deliberately not what CI does.** It bind-mounts a working copy so you can
check something before committing it. A bind mount can be dirty, and a dirty tree is
exactly what `lock_plan.py` refuses to lock against — so `dev` is for while you are fixing
something, and CI is for the committed state.

**The `commit` key of the lock is not recomputed either.** `mt_public` is a squashed
publication of the project, so it has a history of its own and the hash the lock names is
not reachable in it. Recomputing that key here would fail every time and mean nothing, so
`verify.sh` reports it as `SKIP` with the reason rather than quietly dropping it.

## Status

The checks are written against the project's own entry points (`fetch_data.py`,
`smoke_plan.py`, `Plan.sha256`) rather than reimplementing them.

Checks 1, 2, 3 and 3b have been run against `mt_public` and behave as described —
`Plan.sha256` is an attribute, the digest matches the lock, and the version report is what
surfaced the nltk finding above. The `smoke` job's mapping from `model_cache/` directory
names to plan configuration keys is inferred from the directory listing rather than from
the training scripts; expect to adjust it on the first cached run.

First end-to-end container run, 7 November 2026 — lock taken on Windows, checks run on
Linux, plan digest identical:

```text
============================================================
 Environment
============================================================
  python    3.13.0
  commit    55b5a9028e5ac0e16b6550f1e9a989c47b49e996
  tree      clean
  platform  Linux-6.18.33.2-microsoft-standard-WSL2-x86_64-with-glibc2.36
  lock made on Windows-11-10.0.26300-SP0

============================================================
 2. Plan digest vs plan/LOCK.json
============================================================
        recorded  34f81ee577ed14f1b5a975a05bcbc4dd3fb5f655b4644f14f48e1e964d210268
        computed  34f81ee577ed14f1b5a975a05bcbc4dd3fb5f655b4644f14f48e1e964d210268
  PASS  plan/v1.yaml digest matches the lock

============================================================
 3b. Installed versions vs the lock
============================================================
        lock python    3.13.0
        lock platform  Windows-11-10.0.26300-SP0
        this python    3.13.0

          ok  nltk               3.9.3
          ok  numpy              2.4.3
          ok  pyyaml             6.0.3

        0 differ, 17 not installed in this image, 3 match
  PASS  version report written (drift is reported, not failed)
```

## Licence

MIT, matching the project it checks.
