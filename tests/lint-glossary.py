#!/usr/bin/env python3
"""The phrases GLOSSARY.md lists under _Avoid_ with one reading only stay out.

Most _Avoid_ entries depend on context ("deployment (for a workload of any
kind)" is right for the helper `deploymentFullname`), so they are the review's
call (CODING_STANDARDS.md, *Judgement rules*). The phrases in AVOID below have
no right reading anywhere: each names the GLOSSARY entry that replaces it.
"deployment-level" sat in some 150 places until issue #217 replaced it by hand.

Checked: every tracked text file except the ADRs and the CHANGELOG, which
describe the repository as it was when they were written, GLOSSARY.md, which
names the phrases to avoid them, and this file.

Usage: lint-glossary.py
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
AVOID = {
    re.compile(r"\bdeployment[- ]level\b", re.I): "workload scope / workload-scope (GLOSSARY *Root scope / workload scope*)",
    re.compile(r"\bdeployment[- ]scope\b", re.I): "workload scope / workload-scope (GLOSSARY *Root scope / workload scope*)",
}
SKIP = ("docs/adr/", "CHANGELOG.md", "GLOSSARY.md", "tests/lint-glossary.py")
SUFFIXES = {".md", ".yaml", ".yml", ".tpl", ".txt", ".json", ".py", ""}


def main():
    files = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
    files = [f for f in files if not f.startswith(SKIP) and pathlib.Path(f).suffix in SUFFIXES]
    problems = []
    for rel in files:
        path = ROOT / rel
        if not path.is_file():
            continue
        for n, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            for pattern, use in AVOID.items():
                for m in pattern.finditer(line):
                    problems.append(f"{rel}:{n}: \"{m.group(0)}\" is on GLOSSARY's _Avoid_ list; use {use}")
    if problems:
        print("\n".join(f"    FAIL: {p}" for p in problems))
        return 1
    print(f"    OK: no _Avoid_ phrase of GLOSSARY.md in {len(files)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
