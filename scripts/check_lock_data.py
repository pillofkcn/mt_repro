"""Compare the files of exploratory datasets with the digests plan/LOCK.json records.

    python check_lock_data.py ewt_test [KEY ...]

Exit 0 if every file of every named dataset matches the lock, 1 otherwise. Run
from prog/.

scripts/fetch_data.py covers only the datasets the plan gives a `source` (the
two confirmatory sets), so the lock's `data` key also holds datasets it never
looks at. This checks those against the lock through the project's own
seal._exploratory_data_problems, the function the confirmatory run uses, rather
than hashing here: it also checks that the lock records exactly the plan's
files, not only that the ones on disk match.

seal._exploratory_data_problems is private in the version this was written
against (since 25 Oct 2026). If it is renamed or removed, this check fails and
says so rather than passing over a dataset it did not check.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path


def main(keys: list[str]) -> int:
    if not keys:
        print("        usage: check_lock_data.py KEY [KEY ...]")
        return 1
    try:
        from syntactic_analysis import seal
        from syntactic_analysis.plan import load
    except Exception as exc:  # noqa: BLE001 - reported, not raised
        print(f"        cannot import the project: {exc}")
        return 1

    problems_of = getattr(seal, "_exploratory_data_problems", None)
    if problems_of is None:
        print("        seal has no _exploratory_data_problems; adjust this check to the API.")
        return 1

    plan = load(Path("plan/v1.yaml"))
    data = json.loads(Path("plan/LOCK.json").read_text(encoding="utf-8")).get("data", {})
    root = Path.cwd()

    failed = 0
    for key in keys:
        dataset = plan.datasets.get(key)
        if dataset is None:
            print(f"        {key}: not a dataset of plan/v1.yaml")
            failed += 1
            continue
        recorded = data.get(key)
        problems = problems_of(key, dataset, recorded, root)
        # Digests are shown for a dataset with a local copy only: the files of one
        # read through NLTK are named relative to nltk_data, not to prog/.
        if isinstance(recorded, dict) and getattr(dataset, "nltk_sections", None) is None:
            for name, digest in sorted(recorded.items()):
                path = root / name
                computed = seal.sha256_of(path) if path.is_file() else "(missing)"
                print(f"        {key}  {name}")
                print(f"          recorded  {digest}")
                print(f"          computed  {computed}")
        for problem in problems:
            print(f"        PROBLEM  {problem}")
        failed += bool(problems)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
