#!/usr/bin/env python3
"""The phrases GLOSSARY.md lists under _Avoid_ with one reading only stay out.

Most _Avoid_ entries depend on context, so they are the review's call
(CODING_STANDARDS.md, *Judgement rules*). The phrases in AVOID below have one
reading in the files they are checked in: each names the GLOSSARY entry that
replaces it. "deployment-level" sat in some 150 places until issue #217
replaced it by hand.

"deployment" in lower case, for a workload of any kind, joined them when issue
#221 removed the values key `deployments`: three review rounds of that PR found
more of it. The Kubernetes kind is written Deployment. The word is checked in
the chart, the test scenarios, the Makefile and docs/values-authors/ only: in
the README a "zero-downtime deployment" is a release, an English reading the
chart's own files do not use. There it stays right in three places, which
deployment_ok lets through: after `kubectl` on the line (`kubectl get deployment`), as a list
item that is the bare word (a Chart.yaml keyword, a command's argument), and
in a `# covers:` marker, which names the `$defs` called deployment. A key
(`deployment:`, the removed backend key its fixtures carry), a quoted string,
a path, a file name or an identifier never matches.

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
SCOPE = "workload scope / workload-scope (GLOSSARY *Root scope / workload scope*)"


def deployment_ok(line, m):
    return (re.search(r"\bkubectl\b", line[:m.start()]) or re.match(r"\s*-\s*deployments?\s*$", line)
            or re.match(r"\s*# covers:", line))


# pattern: (replacement, the path prefixes it is checked in or None for all,
# the matches it lets through or None)
AVOID = {
    re.compile(r"\bdeployment[- ]level\b", re.I): (SCOPE, None, None),
    re.compile(r"\bdeployment[- ]scope\b", re.I): (SCOPE, None, None),
    re.compile(r"(?<![\w.\"'`$/-])deployments?(?:'s)?(?![\w/\"'`:]|\.\w)"): (
        "workload (GLOSSARY *Workload*), or Deployment for the kind",
        ("charts/global-chart/", "tests/", "Makefile", "docs/values-authors/"), deployment_ok),
}
# What the lower-case rule flags (True) and lets through (False), run first:
# a widened lookaround or exemption would otherwise stop catching the word
# without a sound
DEPLOYMENT_CASES = {
    "the deployment's hooks": True, "per deployment, so": True, "a deployment.": True,
    "deployment-specific name": True, "a deployment beside kubectl": True,
    "deployments.web.image": False, "`deployment`": False, '"deployments/scale"': False,
    "deploymentFullname": False, "deployment.yaml": False, "kind: Deployment": False,
    "deployment: web": False, "kubectl scale deployment x": False, "  - deployment": False,
    "# covers: deployment": False, "multi-deployment": False, "redeployment": False,
}
SKIP = ("docs/adr/", "CHANGELOG.md", "GLOSSARY.md", "tests/lint-glossary.py")
SUFFIXES = {".md", ".yaml", ".yml", ".tpl", ".txt", ".json", ".py", ""}


def matches(line, rel="tests/x.yaml"):
    """(pattern match, replacement) for every _Avoid_ phrase in line."""
    out = []
    for pattern, (use, only, ok) in AVOID.items():
        if only and not rel.startswith(only):
            continue
        out += [(m, use) for m in pattern.finditer(line) if not (ok and ok(line, m))]
    return out


def main():
    wrong = [line for line, flagged in DEPLOYMENT_CASES.items() if bool(matches(line)) != flagged]
    if wrong:
        print("\n".join(f"    FAIL: self-check: the lower-case deployment rule misreads {line!r}" for line in wrong))
        return 1
    files = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
    files = [f for f in files if not f.startswith(SKIP) and pathlib.Path(f).suffix in SUFFIXES]
    problems = []
    for rel in files:
        path = ROOT / rel
        if not path.is_file():
            continue
        for n, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            for m, use in matches(line, rel):
                problems.append(f"{rel}:{n}: \"{m.group(0)}\" is on GLOSSARY's _Avoid_ list; use {use}")
    if problems:
        print("\n".join(f"    FAIL: {p}" for p in problems))
        return 1
    print(f"    OK: no _Avoid_ phrase of GLOSSARY.md in {len(files)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
