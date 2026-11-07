"""Compare the files of exploratory datasets with the digests plan/LOCK.json records.

    python check_lock_data.py ewt_test [KEY ...]
    SYNTACTIC_ANALYSIS_OFFLINE=1 python check_lock_data.py wsj_01

Exit 0 if every file of every named dataset matches the lock, 1 otherwise. Run
from prog/. A dataset read through NLTK (wsj_01) is looked up where NLTK finds
it; with the project's offline switch on, a missing package is a failure and
never a download.

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
        if isinstance(recorded, dict) and getattr(dataset, "nltk_sections", None) is None:
            for name, digest in sorted(recorded.items()):
                path = root / name
                computed = seal.sha256_of(path) if path.is_file() else "(missing)"
                print(f"        {key}  {name}")
                print(f"          recorded  {digest}")
                print(f"          computed  {computed}")
        elif isinstance(recorded, dict):
            show_through_nltk(seal, key, dataset, recorded, root)
        for problem in problems:
            print(f"        PROBLEM  {problem}")
        failed += bool(problems)
    return 1 if failed else 0


def show_through_nltk(seal, key: str, dataset, recorded: dict, root: Path) -> None:
    """A dataset read through NLTK: where NLTK finds it, and how many of its files match.

    Its files are named relative to the entry of nltk.data.path that holds them,
    not to prog/, and there are a hundred of them, so they are summed up rather
    than listed. seal.dataset_files finds them the way the verdict above does;
    the verdict itself is still seal's.
    """
    try:
        files = seal.dataset_files(dataset, root)
    except LookupError:
        print(f"        {key}  NLTK does not find it")
        return
    names = sorted(recorded)
    entries = sorted({
        str(path)[: -len(name)].rstrip("/")
        for name, path in files.items()
        if str(path).endswith(name)
    })
    matching = sum(
        1
        for name, path in files.items()
        if name in recorded and path.is_file() and seal.sha256_of(path) == recorded[name]
    )
    print(f"        {key}  nltk_data/{names[0]} ... {Path(names[-1]).name}")
    print(f"          found in  {', '.join(entries) or '(nowhere)'}")
    print(f"          recorded  {len(recorded)} files")
    print(f"          matching  {matching}")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
