#!/usr/bin/env python3
"""Every closed schema node must have a fixture proving that its closure holds.

A closure nothing tests is indistinguishable from a closure that silently
stopped working — which is the shape of the bug this whole directory exists to
catch. The link is a `# covers: <pointer>` line in the fixture that carries the
typo. This script is the single home of the convention; CLAUDE.md, ADR 0006 and
the README point here.

The walk. Every node is walked, not only the top-level `$defs`: a closure nested
inside one (`additionalProperties: false` on a property, on `items`) breaks just
as silently (issue #177). `$ref` is not followed — its target is a `$defs` of
its own and is walked there. The pointer is the literal JSON pointer relative to
`$defs` (`deployment`, `service/properties/extraPorts/items`); the schema root
is `#`. The five `allOf` branches are exempt at their root only: they must stay
open (ADR 0006). A closed node under `if` or `not` fails outright: it decides a
condition rather than what the values may carry, so no typo fixture can assert
it. `then`/`else` do constrain the values and count like any other node. A
closed `oneOf`/`anyOf` branch belongs in a `$defs` of its own, so its pointer
does not hang on the order of the branches.

The static check. Every closed node has exactly one marker, and every marker
names a closed node.

The mutation check (issue #179). A marker alone does not prove that the typo
hits that node: a fixture rejected by some *other* closure, or by a `required`
its typo broke, passes the static check and leaves the node untested. So for
each marker the closure is removed from a copy of the chart, and the fixture
must then no longer be rejected by the schema.

Usage: check-closure-coverage.py <schema rejection message> [helm lint flags...]
"""
import copy
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
CHART = HERE.parent.parent / "charts" / "global-chart"

BRANCHES = {"jobCommon", "cronJobSpec", "hookJobSpec", "rootJobSpec", "deploymentJobSpec"}

# Keywords whose value is a map of name -> schema, a list of schemas, or one
# schema. Data keywords (enum, const, default, ...) hold no schema and are skipped.
SCHEMA_MAPS = {"properties", "patternProperties", "$defs", "dependentSchemas"}
SCHEMA_LISTS = {"allOf", "anyOf", "oneOf", "prefixItems"}
SCHEMA_ONE = {"items", "additionalProperties", "unevaluatedProperties", "unevaluatedItems",
              "if", "then", "else", "not", "propertyNames", "contains"}
CLOSURES = ("additionalProperties", "unevaluatedProperties")


def is_closed(node):
    return any(node.get(k) is False for k in CLOSURES)


def walk(node, keys=(), conditional=False):
    """Yield (keys, conditional) for every closed node; keys is its full JSON path."""
    if not isinstance(node, dict):
        return
    if is_closed(node):
        yield keys, conditional
    for key, value in node.items():
        if key in SCHEMA_MAPS and isinstance(value, dict):
            for name, sub in value.items():
                yield from walk(sub, keys + (key, name), conditional)
        elif key in SCHEMA_LISTS and isinstance(value, list):
            for i, sub in enumerate(value):
                yield from walk(sub, keys + (key, i), conditional)
        elif key in SCHEMA_ONE:
            yield from walk(value, keys + (key,), conditional or key in ("if", "not"))


def pointer(keys):
    rel = keys[1:] if keys[:1] == ("$defs",) else keys
    return "/".join(map(str, rel)) or "#"


def rejected(schema, fixture, chart, rejection, flags):
    (chart / "values.schema.json").write_text(json.dumps(schema))
    out = subprocess.run(["helm", "lint", *flags, "-f", str(fixture), str(chart)],
                         capture_output=True, text=True)
    return rejection in out.stdout + out.stderr


def main(rejection, flags):
    schema = json.loads((CHART / "values.schema.json").read_text())
    problems, closed = [], {}
    for keys, conditional in walk(schema):
        if conditional:
            problems.append(f"{pointer(keys)} is closed inside an 'if'/'not'; close it outside the condition (ADR 0006)")
        elif not (len(keys) == 2 and keys[0] == "$defs" and keys[1] in BRANCHES):
            closed[pointer(keys)] = keys

    covered = {}
    for fixture in sorted((HERE / "schema").glob("*.yaml")):
        for name in re.findall(r"^# covers: (\S+)$", fixture.read_text(), re.M):
            covered.setdefault(name, []).append(fixture)

    for name in sorted(closed.keys() - covered.keys()):
        problems.append(f"{name} is closed but no fixture covers it")
    for name in sorted(covered.keys() - closed.keys()):
        problems.append(f"'# covers: {name}' names no closed schema node ({', '.join(f.name for f in covered[name])})")
    for name, files in sorted(covered.items()):
        if len(files) > 1:
            problems.append(f"{name} is covered {len(files)} times ({', '.join(f.name for f in files)})")

    with tempfile.TemporaryDirectory() as tmp:
        chart = pathlib.Path(tmp) / CHART.name
        shutil.copytree(CHART, chart)
        for name in sorted(closed.keys() & covered.keys()):
            opened = copy.deepcopy(schema)
            node = opened
            for key in closed[name]:
                node = node[key]
            for k in CLOSURES:
                node.pop(k, None)
            fixture = covered[name][0]
            # The control: with the closure intact the copy must reject the
            # fixture, or a broken run would read as every closure proven.
            if not rejected(schema, fixture, chart, rejection, flags):
                problems.append(f"{fixture.name} is not rejected by the intact schema in the chart copy")
            elif rejected(opened, fixture, chart, rejection, flags):
                problems.append(f"{fixture.name} is still rejected by the schema with {name}'s closure removed:"
                                " its typo does not hit that node alone")

    if problems:
        print("    FAIL: bad-values/schema/ does not match the closed schema nodes:")
        for p in problems:
            print(f"          - {p}")
        sys.exit(1)
    print(f"    OK: all {len(closed)} closed schema nodes are covered by a fixture that fails without them")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__.rsplit("Usage: ", 1)[1])
    main(sys.argv[1], sys.argv[2:])
