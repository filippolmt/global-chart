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
       lint-checks.py --self-test
"""
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
MISSING = "/nonexistent-lint-checks"
PROBES = {
    "tests/lint-templates.py": [MISSING],
    "tests/check-inheritance.py": [MISSING, MISSING],
    "tests/check-scenario-coverage.py": [MISSING, MISSING, MISSING],
    "tests/check-schema-descriptions.py": [MISSING],
    "tests/check-schema-bounds.py": [MISSING],
    "tests/check-release.py": [MISSING, MISSING],
    "tests/bad-values/null-sweep.py": [MISSING, MISSING],
    "tests/bad-values/bound-sweep.py": [MISSING, MISSING],
    "tests/render-diff.py": ["refs/nonexistent-lint-checks"],
    "tests/tools/schema-describe.py": [MISSING, MISSING],
}
NO_INPUT = {"tests/lint-docs.py", "tests/lint-shell.py", "tests/lint-glossary.py", "tests/lint-labels.py",
            "tests/lint-checks.py", "tests/check-basic-auth.py", "tests/bad-values/check-closure-coverage.py",
            "tests/bad-values/check-schema-navigation.py", "tests/bad-values/check-null-preflight.py"}


def ci_problems(makefile, ci):
    """Every target make all runs, check expanded, that has no `run: make <target>` step in ci.
    shortcut: a prerequisite line continued with `\\` and a second level of
    expansion are not read; read them when all: or check: grows either."""
    prereqs = {m.group(1): m.group(2).split() for m in re.finditer(r"^([\w-]+):([^#\n]*?)(?:##.*)?$", makefile, re.M)}
    if "all" not in prereqs or "check" not in prereqs:
        return ["Makefile: no `all:` and `check:` targets, whose prerequisites CI must run"]
    targets = set(prereqs["check"]) | (set(prereqs["all"]) - {"check"})
    in_ci = set(re.findall(r"run:\s*make\s+([\w-]+)", ci))
    if not in_ci:
        return [".github/workflows/helm-ci.yml: no `run: make <target>` step at all, where make all's targets run"]
    return [f".github/workflows/helm-ci.yml: no `run: make {t}` step, and make all runs {t}" for t in sorted(targets - in_ci)]


def script_problems(makefile, probes, no_input):
    """Every script the Makefile runs that is neither probed nor exempt."""
    run = set(re.findall(r"python3\s+(tests/[\w/.-]+\.py)", makefile))
    if not run:
        return ["Makefile: no `python3 tests/<script>.py` line, where the check scripts are run"]
    return [f"{s}: the Makefile runs it, and lint-checks.py neither probes it (PROBES) nor lists it as "
            "reading no input (NO_INPUT)" for s in sorted(run - set(probes) - no_input)]


def probe(script, args, root=ROOT):
    """None when script, run on args, exits 1 with a FAIL line and no traceback; else what it did."""
    try:
        out = subprocess.run([sys.executable, script, *args], cwd=root, capture_output=True, text=True, timeout=300)
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"{script}: the probe did not finish: {e}"
    text = out.stdout + out.stderr
    if "Traceback" in text or out.returncode != 1 or "FAIL:" not in out.stdout:
        last = " ".join(text.strip().splitlines()[-1:])[:160]
        return (f"{script}: on a missing input it exits {out.returncode}"
                f"{' with a traceback' if 'Traceback' in text else ''}, not 1 with a FAIL line: {last}")
    return None


def self_test():
    makefile = "all: check b ## x\ncheck: a\n\ta:\n\t@python3 tests/x.py\n"
    assert ci_problems(makefile, "run: make a\nrun: make b\n") == []
    assert ci_problems(makefile, "run: make a\n") == [
        ".github/workflows/helm-ci.yml: no `run: make b` step, and make all runs b"]
    assert ci_problems("", "run: make a\n") and ci_problems(makefile, "")
    assert script_problems(makefile, {"tests/x.py": []}, set()) == []
    assert script_problems(makefile, {}, set()) and script_problems("", {}, set())
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        (root / "crash.py").write_text("open('/nonexistent')\n")
        (root / "clean.py").write_text("print('    FAIL: no input')\nraise SystemExit(1)\n")
        assert probe("crash.py", [], root) and probe("clean.py", [], root) is None
    print("    OK: self-test")


def main():
    try:
        makefile = (ROOT / "Makefile").read_text()
        ci = (ROOT / ".github" / "workflows" / "helm-ci.yml").read_text()
    except OSError as e:
        print(f"    FAIL: cannot read the Makefile or the CI workflow, whose checks this holds together: {e}")
        return 1
    problems = ci_problems(makefile, ci) + script_problems(makefile, PROBES, NO_INPUT)
    for script, args in PROBES.items():
        if not (ROOT / script).is_file():
            problems.append(f"{script}: in PROBES, but no such script")
        elif found := probe(script, args):
            problems.append(found)
    if problems:
        print("    FAIL: a check CI does not run, or one that does not fail cleanly on unreadable input:")
        for p in problems:
            print(f"          - {p}")
        return 1
    print(f"    OK: CI runs every make all target; {len(PROBES)} check scripts fail with a FAIL line on a missing input")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        sys.exit(0)
    sys.exit(main())
