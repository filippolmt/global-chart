#!/usr/bin/env python3
"""Every values node the schema declares as a map or a list, or bounds, is set by
a scenario, and every type a node accepts beside another is used by one.

The checks over scenarios (`make null-sweep`, its type pass, `make e2e-dryrun`)
see only what the TEST_CASES scenarios set: a node no scenario reaches is never
swept, and a form no scenario uses is never rendered. `imagePullSecrets: [name]`,
the string form the schema accepts beside `{name: …}`, was in no scenario, and a
check that rejected it passed every target (issue #235).

The walk. Each scenario is read back as JSON through a scratch chart, as
null-sweep does. values.schema.json is walked from the root through properties,
additionalProperties (`*`), items (`[]`), $ref, oneOf, anyOf and allOf, down every
node it declares. A gap is:
- `<path>: never set`: a node that can be a map or a list, or a node
  bound-sweep.py has candidates for (issue #226), which no scenario sets though
  one sets the node holding it: the bound sweep sees only what a scenario sets;
- `<path>: never <type>`: a node a scenario sets, accepting two types or more (an
  imagePullSecrets item, a map or a string; a targetPort, a number or a name),
  where no scenario uses that one.
Only the topmost gap counts: below a node no scenario sets, nothing is reported.
A new `never set` gap names, after it, the nodes below it that become gaps once
it is set, so a scenario covers the subtree in one pass, not one level a run.
A removed key (declared with no type, ADR 0022) has no type to reach. A
passthrough surface is open: the walk stops where the schema stops declaring.

The ratchet. tests/scenario-coverage-baseline.txt lists the gaps of the day the
check arrived. A gap not in it fails: a new node or form comes with a scenario.
A baseline line that is no longer a gap fails too, so the file only shrinks:
delete the line.

Usage: check-scenario-coverage.py <chart dir> <baseline file> <values file>...
"""
import importlib.util
import json
import pathlib
import re
import sys
import tempfile

HERE = pathlib.Path(__file__).parent
spec = importlib.util.spec_from_file_location("null_sweep", HERE / "bad-values" / "null-sweep.py")
sweep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep)
spec = importlib.util.spec_from_file_location("bound_sweep", HERE / "bad-values" / "bound-sweep.py")
bound = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bound)
spec = importlib.util.spec_from_file_location("schema_navigation", HERE / "bad-values" / "schema_navigation.py")
navigation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(navigation)


def value_type(value):
    if isinstance(value, dict):
        return "map"
    if isinstance(value, list):
        return "list"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, str):
        return "string"
    return "number"


def used(values, keys, path, out):
    """Map each generic path a scenario reaches to the types its values take there.
    keys: the generic paths declared, so a map key the schema names is told from a `*` entry."""
    if values is None:
        return
    out.setdefault(path, set()).add(value_type(values))
    if isinstance(values, dict):
        for key, child in values.items():
            named = f"{path}.{key}" if path else key
            used(child, keys, named if named in keys else (f"{path}.*" if path else "*"), out)
    elif isinstance(values, list):
        for child in values:
            used(child, keys, path + "[]", out)


def parent(path):
    return re.sub(r"(\[\]|\.[^.\[]+|^[^.\[]+)$", "", path)


def bounded(schema, path):
    """Whether bound-sweep.py has candidates for the node at a generic path (a.*.b[].c)."""
    return bound.bounded(navigation.generic_sources(schema, path))


def gaps(schema, schema_paths, reached):
    """The topmost gaps: a node whose parent no scenario reaches is its parent's gap, not its own."""
    out = set()
    for path, types in schema_paths.items():
        if not path or not types or (parent(path) and parent(path) not in reached):
            continue
        seen = reached.get(path, set())
        if not seen and (types & {"map", "list"} or bounded(schema, path)):
            out.add(f"{path}: never set")
        elif seen and len(types) > 1:
            out |= {f"{path}: never {t}" for t in types - seen}
    return out


def below(schema, schema_paths, reached, path):
    """The nodes under a never-set node that become gaps once it is set, relative to it."""
    return sorted(p[len(path):].lstrip(".") for p, types in schema_paths.items()
                  if p.startswith((path + ".", path + "[")) and p not in reached
                  and (types & {"map", "list"} or bounded(schema, p)))


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__.rsplit("Usage: ", 1)[1])
    chart, baseline_file, files = pathlib.Path(argv[0]), pathlib.Path(argv[1]), argv[2:]
    schema = json.loads((chart / "values.schema.json").read_text())
    schema_paths = navigation.declared_paths(schema)
    reached = {}
    with tempfile.TemporaryDirectory() as tmp:
        scratch = pathlib.Path(tmp) / "values-to-json"
        (scratch / "templates").mkdir(parents=True)
        (scratch / "Chart.yaml").write_text("apiVersion: v2\nname: values-to-json\nversion: 0.0.0\n")
        (scratch / "templates" / "values.json").write_text("{{ .Values | toJson }}\n")
        for f in files:
            used(sweep.to_json(f, scratch), schema_paths, "", reached)
    found = gaps(schema, schema_paths, reached)
    baseline = {line for line in baseline_file.read_text().splitlines() if line and not line.startswith("#")}
    problems = []
    for g in sorted(found - baseline):
        path, _, what = g.rpartition(": ")
        under = below(schema, schema_paths, reached, path) if what == "never set" else []
        hint = f" (and below it: {', '.join(under)})" if under else ""
        problems.append(f"    FAIL: {g}: no scenario reaches it; set it in a TEST_CASES scenario{hint}")
    problems += [f"    FAIL: {g}: a scenario reaches it now; delete the line from {baseline_file}"
                 for g in sorted(baseline - found)]
    if problems:
        print("\n".join(problems))
        sys.exit(1)
    print(f"    OK: {len(schema_paths)} schema nodes, {len(found)} known gaps in {baseline_file.name}, none new")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (OSError, json.JSONDecodeError) as e:
        print(f"    FAIL: cannot read the schema, the baseline or a scenario: {e}")
        sys.exit(1)
