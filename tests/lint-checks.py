#!/usr/bin/env python3
"""The check scripts meet their own rule (CODING_STANDARDS.md, *Check scripts*):
input a check cannot read is a FAIL naming what it expected, never a traceback.

Each script the Makefile runs with an input is run here once on inputs that do
not exist, and must exit 1 with a `FAIL:` line and no Python traceback. PROBES
below holds those inputs; NO_INPUT the scripts whose input is the repository
itself, or a message, or GitHub. A script the Makefile runs that is in neither
fails: a new check is probed from the day it lands (issue #248).

It also holds CI to the Makefile: every target `make all` runs, `check`
expanded, has a `run: make <target>` step in .github/workflows/helm-ci.yml,
which runs them one step each so a failure names its check. A target added to
`check` and not to CI fails here.

Usage: lint-checks.py
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MISSING = "/nonexistent-lint-checks"
PROBES = {
    "tests/lint-templates.py": [MISSING],
    "tests/check-inheritance.py": [MISSING, MISSING],
    "tests/check-scenario-coverage.py": [MISSING, MISSING, MISSING],
    "tests/check-schema-descriptions.py": [MISSING],
    "tests/bad-values/null-sweep.py": [MISSING, MISSING],
    "tests/render-diff.py": ["refs/nonexistent-lint-checks"],
}
NO_INPUT = {"tests/lint-docs.py", "tests/lint-shell.py", "tests/lint-glossary.py", "tests/lint-labels.py",
            "tests/lint-checks.py", "tests/bad-values/check-closure-coverage.py"}


def main():
    try:
        makefile = (ROOT / "Makefile").read_text()
    except OSError as e:
        print(f"    FAIL: cannot read the Makefile, where the check scripts are run: {e}")
        return 1
    try:
        ci = (ROOT / ".github" / "workflows" / "helm-ci.yml").read_text()
    except OSError as e:
        print(f"    FAIL: cannot read the CI workflow, where every make all target needs a step: {e}")
        return 1
    prereqs = {m.group(1): m.group(2).split() for m in re.finditer(r"^([\w-]+):([^#\n]*?)(?:##.*)?$", makefile, re.M)}
    if "all" not in prereqs or "check" not in prereqs:
        print("    FAIL: no `all:` and `check:` targets in the Makefile, whose prerequisites CI must run")
        return 1
    targets = set(prereqs["check"]) | set(prereqs["all"]) - {"check"}
    in_ci = set(re.findall(r"run:\s*make\s+([\w-]+)", ci))
    problems = [f".github/workflows/helm-ci.yml: no `run: make {t}` step, and make all runs {t}"
                for t in sorted(targets - in_ci)]
    run = set(re.findall(r"python3\s+(tests/[\w/.-]+\.py)", makefile))
    problems += [f"{s}: the Makefile runs it, and lint-checks.py neither probes it (PROBES) nor lists it as "
                "reading no input (NO_INPUT)" for s in sorted(run - set(PROBES) - NO_INPUT)]
    for script, args in PROBES.items():
        if not (ROOT / script).is_file():
            problems.append(f"{script}: in PROBES, but no such script")
            continue
        out = subprocess.run([sys.executable, script, *args], cwd=ROOT, capture_output=True, text=True, timeout=300)
        text = out.stdout + out.stderr
        if "Traceback" in text or out.returncode != 1 or "FAIL:" not in out.stdout:
            last = " ".join(text.strip().splitlines()[-1:])[:160]
            problems.append(f"{script}: on a missing input it exits {out.returncode}"
                            f"{' with a traceback' if 'Traceback' in text else ''}, not 1 with a FAIL line: {last}")
    if problems:
        print("    FAIL: a check CI does not run, or one that does not fail cleanly on unreadable input:")
        for p in problems:
            print(f"          - {p}")
        return 1
    print(f"    OK: CI runs every make all target; {len(PROBES)} check scripts fail with a FAIL line on a missing input")
    return 0


if __name__ == "__main__":
    sys.exit(main())
