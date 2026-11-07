"""Report installed package versions against plan/LOCK.json's `versions` block.

Always exits 0: this is a report, not a gate. The verify image installs only the
core packages, so most analyzers are legitimately absent, and failing on that
would make the check useless in the image it runs in.

It exists because a digest match and a format failure are not a contradiction -
they mean the reader changed, not the data - and this is what tells them apart.
The first run of this room installed nltk 3.10.4 under pyproject's range
nltk>=3.9,<4; 3.10.4 no longer accepts the escaped leaf at line 514 of MCTB's
dialogue.cleaned.txt, so the file counted 999 trees where DATASET.md records
1000, with its SHA-256 unchanged.
"""
from __future__ import annotations

import json
import sys
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path


def main() -> int:
    lock = json.loads(Path("plan/LOCK.json").read_text(encoding="utf-8"))
    versions = lock.get("versions", {})
    libraries = versions.get("libraries", {})

    print(f"        lock python    {versions.get('python', '?')}")
    print(f"        lock platform  {versions.get('platform', '?')}")
    print(f"        this python    {sys.version.split()[0]}")
    print()

    drift = absent = 0
    for name, recorded in sorted(libraries.items()):
        try:
            installed = version(name)
        except PackageNotFoundError:
            absent += 1
            continue
        if installed == recorded:
            print(f"          ok  {name:18} {recorded}")
        else:
            drift += 1
            print(f"        DIFF  {name:18} lock {recorded:12} installed {installed}")

    print()
    print(f"        {drift} differ, {absent} not installed in this image, "
          f"{len(libraries) - drift - absent} match")
    if drift:
        print("        A difference here is the first thing to read when a dataset")
        print("        check fails while its digest still matches.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
