#!/usr/bin/env python3
"""The phrases GLOSSARY.md lists under _Avoid_ with one reading only stay out.

Most _Avoid_ entries depend on context, so they are the review's call
(CODING_STANDARDS.md, *Judgement rules*). The phrases in AVOID below have no
right reading anywhere: each names the GLOSSARY entry that replaces it.
"deployment-level" sat in some 150 places until issue #217 replaced it by hand.

"deployment" in lower case, for a workload of any kind, joined them when issue
#221 removed the values key `deployments`: three review rounds of that PR found
more of it. The Kubernetes kind is written Deployment. A lower-case word stays
right in three places, which DEPLOYMENT_OK lets through: a line that calls
kubectl (`kubectl get deployment`), a list item that is the bare word (a
Chart.yaml keyword, a command's argument), and a `# covers:` marker, which
names the `$defs` called deployment. A key, a quoted string, a path, a file
name or an identifier never matches: the word must stand alone.

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
DEPLOYMENT = re.compile(r"(?<![\w.\"'`$/-])deployments?(?:'s)?(?![\w/\"'`:-]|\.\w)")
AVOID = {
    re.compile(r"\bdeployment[- ]level\b", re.I): "workload scope / workload-scope (GLOSSARY *Root scope / workload scope*)",
    re.compile(r"\bdeployment[- ]scope\b", re.I): "workload scope / workload-scope (GLOSSARY *Root scope / workload scope*)",
    DEPLOYMENT: "workload (GLOSSARY *Workload*), or Deployment for the kind",
}
DEPLOYMENT_OK = re.compile(r"\bkubectl\b|^\s*-\s*deployments?\s*$|^\s*# covers:")
# The lines DEPLOYMENT must flag (True) and let through (False): a self-check,
# run first, so a widened lookaround cannot silently stop catching the word
DEPLOYMENT_CASES = {
    "the deployment's hooks": True, "per deployment, so": True, "a deployment.": True,
    "deployments.web.image": False, "`deployment`": False, '"deployments/scale"': False,
    "deploymentFullname": False, "deployment.yaml": False, "kind: Deployment": False,
    "deployment: web": False, "kubectl scale deployment x": False, "  - deployment": False,
    "# covers: deployment": False,
}
SKIP = ("docs/adr/", "CHANGELOG.md", "GLOSSARY.md", "tests/lint-glossary.py")
SUFFIXES = {".md", ".yaml", ".yml", ".tpl", ".txt", ".json", ".py", ""}


def main():
    for line, flagged in DEPLOYMENT_CASES.items():
        assert bool(DEPLOYMENT.search(line) and not DEPLOYMENT_OK.search(line)) == flagged, line
    files = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
    files = [f for f in files if not f.startswith(SKIP) and pathlib.Path(f).suffix in SUFFIXES]
    problems = []
    for rel in files:
        path = ROOT / rel
        if not path.is_file():
            continue
        for n, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            for pattern, use in AVOID.items():
                if pattern is DEPLOYMENT and DEPLOYMENT_OK.search(line):
                    continue
                for m in pattern.finditer(line):
                    problems.append(f"{rel}:{n}: \"{m.group(0)}\" is on GLOSSARY's _Avoid_ list; use {use}")
    if problems:
        print("\n".join(f"    FAIL: {p}" for p in problems))
        return 1
    print(f"    OK: no _Avoid_ phrase of GLOSSARY.md in {len(files)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
