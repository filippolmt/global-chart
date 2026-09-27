#!/usr/bin/env python3
"""Every closed schema node must have a fixture asserting that its closure holds.

A closure nothing tests is indistinguishable from a closure that silently
stopped working — which is the shape of the bug this whole directory exists to
catch. The link is a `# covers: <pointer>` line in the fixture that carries the
typo; this script checks the two sides against each other and names every
mismatch, so adding a closure without a fixture fails here rather than at the
next person's typo.

Every node is walked, not only the top-level `$defs`: a closure nested inside
one (`additionalProperties: false` on a property, on `items`, on a `oneOf`
branch) breaks just as silently (issue #177). `$ref` is not followed — the
target is a `$defs` of its own and is walked there. The pointer is the literal
JSON pointer relative to `$defs` (`service/properties/extraPorts/items`,
`image/oneOf/2`); the schema root is `#`.
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

# Keywords whose value is a map of name -> schema, and whose value is a list of
# schemas. Every other dict-valued keyword is a single subschema; data keywords
# (enum, const, default, ...) hold no schema and are skipped.
SCHEMA_MAPS = {"properties", "patternProperties", "$defs", "dependentSchemas"}
SCHEMA_LISTS = {"allOf", "anyOf", "oneOf", "prefixItems"}
SCHEMA_ONE = {"items", "additionalProperties", "unevaluatedProperties", "unevaluatedItems",
              "if", "then", "else", "not", "propertyNames", "contains"}

closed, problems = set(), []


def walk(node, path, conditional):
    if not isinstance(node, dict):
        return
    pointer = "/".join(path) or "#"
    if node.get("additionalProperties") is False or node.get("unevaluatedProperties") is False:
        if conditional:
            # A closure under if/not decides a condition, not what the values may
            # carry: no typo fixture can assert it. See ADR 0006.
            problems.append(f"{pointer} is closed inside an 'if'/'not'; close it outside the condition (ADR 0006)")
        elif not (len(path) == 1 and path[0] in BRANCHES):
            closed.add(pointer)
    for key, value in node.items():
        if key in SCHEMA_MAPS and isinstance(value, dict):
            # $defs sits at the root, so its entries start the pointer.
            prefix = [] if key == "$defs" and not path else path + [key]
            for name, sub in value.items():
                walk(sub, prefix + [name], conditional)
        elif key in SCHEMA_LISTS and isinstance(value, list):
            for i, sub in enumerate(value):
                walk(sub, path + [key, str(i)], conditional)
        elif key in SCHEMA_ONE:
            walk(value, path + [key], conditional or key in ("if", "not"))


walk(json.loads(SCHEMA.read_text()), [], False)

covered = {}
for fixture in sorted((HERE / "schema").glob("*.yaml")):
    for name in re.findall(r"^# covers: (\S+)$", fixture.read_text(), re.M):
        covered.setdefault(name, []).append(fixture.name)

for name in sorted(closed - covered.keys()):
    problems.append(f"{name} is closed but no fixture covers it")
for name in sorted(covered.keys() - closed):
    problems.append(f"'# covers: {name}' names no closed schema node ({', '.join(covered[name])})")
for name, files in sorted(covered.items()):
    if len(files) > 1:
        problems.append(f"{name} is covered {len(files)} times ({', '.join(files)})")

if problems:
    print("    FAIL: bad-values/schema/ does not match the closed schema nodes:")
    for p in problems:
        print(f"          - {p}")
    sys.exit(1)

print(f"    OK: all {len(closed)} closed schema nodes are covered by a fixture")
