#!/usr/bin/env python3
"""Every closed $defs must have a fixture asserting that its closure holds.

A closure nothing tests is indistinguishable from a closure that silently
stopped working — which is the shape of the bug this whole directory exists to
catch. The link is a `# covers: <defsName>` line in the fixture that carries the
typo; this script checks the two sides against each other and names both
mismatches, so adding a closure without a fixture fails here rather than at the
next person's typo.
"""
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
SCHEMA = HERE.parent.parent / "charts" / "global-chart" / "values.schema.json"

# Branches of an allOf: they must stay open (a branch validates the whole object
# on its own), so they can never be covered. See ADR 0006.
BRANCHES = {"jobCommon", "cronJobSpec", "hookJobSpec", "rootJobSpec", "deploymentJobSpec"}

defs = json.loads(SCHEMA.read_text())["$defs"]
closed = {
    name
    for name, body in defs.items()
    if name not in BRANCHES
    and isinstance(body, dict)
    and (body.get("additionalProperties") is False or body.get("unevaluatedProperties") is False)
}

covered = {}
for fixture in sorted((HERE / "schema").glob("*.yaml")):
    for name in re.findall(r"^# covers: (\S+)$", fixture.read_text(), re.M):
        covered.setdefault(name, []).append(fixture.name)

problems = []
for name in sorted(closed - covered.keys()):
    problems.append(f"$defs/{name} is closed but no fixture covers it")
for name in sorted(covered.keys() - closed):
    problems.append(f"'# covers: {name}' names no closed $defs ({', '.join(covered[name])})")
for name, files in sorted(covered.items()):
    if len(files) > 1:
        problems.append(f"$defs/{name} is covered {len(files)} times ({', '.join(files)})")

if problems:
    print("    FAIL: bad-values/schema/ does not match the closed $defs:")
    for p in problems:
        print(f"          - {p}")
    sys.exit(1)

print(f"    OK: all {len(closed)} closed $defs are covered by a fixture")
