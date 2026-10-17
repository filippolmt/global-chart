#!/usr/bin/env python3
"""Every triage label docs/agents/triage-labels.md names must exist on GitHub.

The skills apply these labels with `gh issue create --label`, which fails the
whole command on a label the repository does not have: the document and the
tracker drift apart without a word until an issue cannot be filed. The label
strings are the second column of the table ("Label in our tracker").

Needs `gh`, authenticated (GH_TOKEN in CI). Not part of `make check`, which
stays offline.

Usage: lint-labels.py
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DOC = ROOT / "docs" / "agents" / "triage-labels.md"
ROW = re.compile(r"^\|\s*`[^`]+`\s*\|\s*`([^`]+)`\s*\|")


def main():
    wanted = [m.group(1) for line in DOC.read_text().splitlines() if (m := ROW.match(line))]
    if not wanted:
        print(f"    FAIL: {DOC.relative_to(ROOT)} lists no label; the table format changed")
        return 1
    out = subprocess.run(["gh", "label", "list", "--limit", "500", "--json", "name", "--jq", ".[].name"],
                         cwd=ROOT, capture_output=True, text=True, check=True).stdout
    missing = sorted(set(wanted) - set(out.split("\n")))
    if missing:
        for label in missing:
            print(f"    FAIL: label `{label}` is in {DOC.relative_to(ROOT)} but not in the repository: gh label create {label}")
        return 1
    print(f"    OK: the {len(wanted)} triage labels exist in the repository")
    return 0


if __name__ == "__main__":
    sys.exit(main())
