"""Compare plan/v1.yaml's digest with the one plan/LOCK.json recorded.

Exit 0 if they match, 1 otherwise. Run from prog/.

Through the project's own Plan.sha256 rather than hashing the file here: the
digest is taken with CRLF read as LF (scripts/lock_plan.py), so hashing the
bytes directly would disagree with the lock on any machine that normalises line
endings - a false alarm about a file nobody edited.

Plan.sha256 is an attribute in the version this was written against; handled as
either, so an upstream change to a property or a method does not turn into a
spurious failure here.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    try:
        from syntactic_analysis.plan import load
    except Exception as exc:  # noqa: BLE001 - reported, not raised
        print(f"        cannot import the plan loader: {exc}")
        return 1

    lock = json.loads(Path("plan/LOCK.json").read_text(encoding="utf-8"))
    recorded = lock.get("plan_sha256")

    plan = load(Path("plan/v1.yaml"))
    computed = getattr(plan, "sha256", None)
    if callable(computed):
        computed = computed()

    if computed is None:
        print("        Plan exposes no sha256; adjust this check to the API.")
        return 1

    print(f"        recorded  {recorded}")
    print(f"        computed  {computed}")
    return 0 if recorded == computed else 1


if __name__ == "__main__":
    sys.exit(main())
