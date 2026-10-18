#!/usr/bin/env python3
"""Every null a values file can carry must fail naming its values path, or render.

Under --skip-schema-validation (the escape hatch ADR 0017 recommends) the schema
no longer stops a null, and a template that reads through one dies with a raw
Go error (`nil pointer evaluating`, `at <$rule.backendRefs>`) naming a template
line instead of the key the user wrote (issues #191, #194). tests/bad-values/
skip-schema/ covers the nulls someone thought of; this sweep covers the rest.

The sweep. Each lint scenario is read back as JSON through a scratch chart
(`{{ .Values | toJson }}`), so YAML parsing is Helm's own and nothing needs
PyYAML. Then every node under it — each map value and each list item — is set to
null in turn, and the chart is rendered with --skip-schema-validation plus the
CRD API versions. A render that succeeds passes (a null the chart tolerates),
unless a null on a key the templates read through isSet renders otherwise than
the same key removed — a null is unset, so the two must match (a key the
chart's values.yaml defaults is left out: Helm deletes the default on a null,
and restores it on a removal) — or unless its output carries more null-looking
lines — `<nil>`, a `- null` list
item, an empty `name:` — than the scenario's own render: a null that reached
the manifest. A `key: null` is not one: a null map value is unset, for the
chart as for the API server. A render that fails passes only when Helm reports a
template `fail` or `required` (`execution error at (…): <message>`) whose
message names the nulled node — its key, or `<list>[<i>]` for a list item — or
the node holding it (a null filters list leaves its rule without backendRefs,
and the rule is what the message names), and carries no raw template error: a fail about another key is the null reaching a
check it was never meant for. Anything else is a finding: the template path and
the error are printed.

When it arrived the sweep found 166 such nulls (issue #198), all fixed; a
finding now fails CI. The rule it holds is in CODING_STANDARDS.md (fallback
guards and nulls).

The type pass (issue #235). Every map and list node is then given the wrong type
in turn: the number 3, and the opposite container (a map becomes [3], a list
{"x": 3}). The types the templates read are valuesShape in _validate-helpers.tpl,
read back as JSON through a second scratch chart holding the chart's helpers, so
the sweep keeps no copy of it. Each node of valuesShape must read exactly the
types values.schema.json accepts there, null aside: a valid value must never
fail it (an imagePullSecrets item is a map or a string). Each pod-spec owner
podSpecOwners lists in a scenario must have a pod spec in valuesShape. A node
valuesShape names must fail with validateValueTypes' message naming its path;
any other node must render or fail naming its path, as a null must. That last
rule keeps valuesShape whole: a node a template reads and valuesShape misses
ends on a raw error. A wrong type that renders in silence, outside valuesShape,
passes: no sweep can tell it from a passthrough node the API server will
reject, so such a node joins valuesShape by hand, with its fixture.

Usage: null-sweep.py <chart dir> <values file>... [-- <helm flags>...]
"""
import concurrent.futures
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
from typing import NamedTuple

# `%!` is a Go fmt error: a value of the wrong type printed into a message
RAW = re.compile(r"nil pointer|error calling|wrong type for value|can't evaluate|"
                 r"executing \"|invalid value; expected|incompatible types|error converting YAML|%!")
FAIL = re.compile(r"execution error at \([^)]*\): ")
# A `key: null` line toYaml writes for a passthrough value: the API server
# reads it as the key absent, so the comparison with the key removed drops it
NULL_VALUE = re.compile(r"^[ \t]*(?:- )?[^\s:][^:\n]*:[ \t]+null[ \t]*\n", re.M)
# podRecreation stamps the pod template with the render time: two renders a
# second apart differ there and nowhere else
TIMESTAMP = re.compile(r'^\s*timestamp: "\d{14}"\n', re.M)
# The keys the templates read through isSet: a null on one must render as the
# key absent. Read from the templates, so the list cannot drift from them.
IS_SET = re.compile(r'isSet" \(list \S+ "(\w+)"\)')
NULLISH = re.compile(r"<nil>|^\s*-\s+null\s*$|^\s*-?\s*name:\s*(\"\")?\s*$", re.M)


def to_json(values, scratch):
    out = subprocess.run(["helm", "template", "x", str(scratch), "-f", str(values)],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out.split("\n", 2)[2])


def paths(node, prefix=()):
    """Yield the path of every map value and list item under node."""
    items = node.items() if isinstance(node, dict) else enumerate(node) if isinstance(node, list) else ()
    for key, value in items:
        yield prefix + (key,)
        yield from paths(value, prefix + (key,))


def removed(values, path):
    copy = json.loads(json.dumps(values))
    node = copy
    for key in path[:-1]:
        node = node[key]
    del node[path[-1]]
    return copy


def set_at(values, path, value):
    copy = json.loads(json.dumps(values))
    node = copy
    for key in path[:-1]:
        node = node[key]
    node[path[-1]] = value
    return copy


def nulled(values, path):
    return set_at(values, path, None)


class Case(NamedTuple):
    """One render of a scenario with one node changed: to null, or to a wrong type."""
    file: str
    path: tuple
    value: object       # what the node became: None, or the wrong type
    values: dict        # the scenario with the node changed
    unset: dict = None  # the scenario with the node removed, for a null read through isSet


def wrong_types(node):
    """The wrong types the type pass gives a map or list node: a number, the other container."""
    if isinstance(node, dict):
        return [3, [3]]
    if isinstance(node, list):
        return [3, {"x": 3}]
    return []


def value_at(values, path):
    for key in path:
        values = values[key]
    return values


def shape_at(shape, path):
    """The shape valuesShape gives the node at path, as validateValueTypes walks it; None outside it."""
    for key in path:
        if isinstance(shape, list) and isinstance(key, int):
            shape = shape[0]
        elif isinstance(shape, dict) and not isinstance(key, int):
            shape = shape.get(key, shape.get("*"))
        else:
            return None
    return shape


SCHEMA_TYPES = {"object": "map", "array": "list", "string": "string", "boolean": "boolean",
                "integer": "number", "number": "number"}


# The schema walk reads type, $ref, oneOf, anyOf, allOf and the child keywords.
# What it skips (if/then/else, not, a $ref's siblings, allOf read as a union)
# can only narrow what a node accepts: the types it computes are then a
# superset, and valuesShape matching them still fails no valid value. The one
# construct that widens is a branch with no type, which accepts any: that is a
# finding, never read as no type.
def untyped_branch(schema, node):
    """Whether node accepts any type: a branch declaring no type whose allOf parts all accept any."""
    return any("type" not in a and all(untyped_branch(schema, n) for n in a.get("allOf", []))
               for a in schema_alternatives(schema, node))


def schema_alternatives(schema, node):
    """The schema nodes a value at node may match: $ref followed, oneOf and anyOf spread."""
    while "$ref" in node:
        target = schema
        for part in node["$ref"].lstrip("#/").split("/"):
            target = target[part]
        node = target
    alternatives = [node]
    for key in ("oneOf", "anyOf"):
        if key in node:
            alternatives = [a for n in node[key] for a in schema_alternatives(schema, n)]
    return alternatives


def schema_types(schema, node):
    types = set()
    for a in schema_alternatives(schema, node):
        t = a.get("type")
        types |= {SCHEMA_TYPES[x] for x in ([t] if isinstance(t, str) else t or []) if x != "null"}
        for n in a.get("allOf", []):
            types |= schema_types(schema, n)
    return types


def schema_parts(schema, node):
    """node and every schema its allOf applies with it, at any depth."""
    return [node] + [p for n in node.get("allOf", []) for a in schema_alternatives(schema, n)
                     for p in schema_parts(schema, a)]


def schema_child(schema, node, key):
    """The schema of node's entry key ("*" for any entry, "[]" for an item); None if undeclared.
    One branch's own declaration and its allOf parts' all apply (allOf); two branches are alternatives (anyOf)."""
    branches = []
    for a in schema_alternatives(schema, node):
        found = []
        for part in schema_parts(schema, a):
            if key == "[]":
                found += [part["items"]] if "items" in part else []
            elif key == "*":
                found += [part["additionalProperties"]] if isinstance(part.get("additionalProperties"), dict) else []
                found += part.get("patternProperties", {}).values()
            elif key in part.get("properties", {}):
                found.append(part["properties"][key])
        if found:
            branches.append({"allOf": found})
    return {"anyOf": branches} if branches else None


def shape_findings(shape, schema, node, path=""):
    """Every node where valuesShape reads other types than the schema accepts."""
    want = {"map"} if isinstance(shape, dict) else {"list"} if isinstance(shape, list) else set(shape.split("|"))
    if node is None:
        return [f"valuesShape: {path}: the schema declares no such node"]
    if untyped_branch(schema, node):
        return [f"valuesShape: {path}: the schema accepts any type there through a branch with no type; "
                "give the branch one, or teach schema_types what it means"]
    got = schema_types(schema, node)
    out = [] if got == want else [f"valuesShape: {path}: reads {'|'.join(sorted(want))}, "
                                  f"the schema accepts {'|'.join(sorted(got)) or 'any type'}"]
    if isinstance(shape, dict):
        for key, child in shape.items():
            out += shape_findings(child, schema, schema_child(schema, node, key), f"{path}.{key}" if path else key)
    elif isinstance(shape, list):
        out += shape_findings(shape[0], schema, schema_child(schema, node, "[]"), path + "[]")
    return out


def values_shape(chart, tmp):
    scratch = pathlib.Path(tmp) / "values-shape"
    (scratch / "templates").mkdir(parents=True)
    (scratch / "Chart.yaml").write_text("apiVersion: v2\nname: values-shape\nversion: 0.0.0\n")
    for helper in (chart / "templates").glob("_*.tpl"):
        (scratch / "templates" / helper.name).write_text(helper.read_text())
    (scratch / "templates" / "shape.json").write_text('{{ include "global-chart.valuesShape" . | fromYaml | toJson }}\n')
    # Wrapped in an object: helm template fails a template whose output is a
    # top-level JSON array ("cannot unmarshal array"), even one -s leaves out
    (scratch / "templates" / "owners.json").write_text('{"owners": {{ include "global-chart.podSpecOwners" . }}}\n')
    out = subprocess.run(["helm", "template", "x", str(scratch), "-s", "templates/shape.json"],
                         capture_output=True, text=True)
    try:
        return json.loads(out.stdout.split("\n", 2)[2])
    except (IndexError, ValueError):
        print("    FAIL: valuesShape in _validate-helpers.tpl does not render as a JSON object behind a `# Source:` "
              "header: " + (" ".join(out.stderr.split())[:240] or out.stdout[:240]))
        sys.exit(1)


def owner_findings(values, tmp, shape):
    """Every pod-spec owner podSpecOwners finds in values that valuesShape gives no pod spec."""
    fd, name = tempfile.mkstemp(suffix=".json", dir=tmp)
    with os.fdopen(fd, "w") as f:
        json.dump(values, f)
    out = subprocess.run(["helm", "template", "x", str(pathlib.Path(tmp) / "values-shape"),
                          "-s", "templates/owners.json", "-f", name], capture_output=True, text=True)
    os.unlink(name)
    try:
        owners = json.loads(out.stdout.split("\n", 2)[2])["owners"]
    except (IndexError, KeyError, ValueError):
        return ["podSpecOwners does not render as a JSON list behind a `# Source:` header: "
                + (" ".join(out.stderr.split())[:240] or out.stdout[:240])]
    # Workload, hook and job names are DNS labels: a dot only joins keys
    specs = {o["path"]: shape_at(shape, tuple(o["path"].split("."))) for o in owners}
    return [f"valuesShape: {path}: a pod-spec owner podSpecOwners lists, with no pod spec in valuesShape"
            for path, spec in specs.items() if not (isinstance(spec, dict) and "volumes" in spec)]


def type_verdict(out, path):
    """A node valuesShape names: the render fails with validateValueTypes' message naming it."""
    err = " ".join(out.stderr.split())
    m = FAIL.search(err)
    if m and err[m.end():].startswith(f"{dotted(path)}: a ") and "where the chart reads" in err:
        return None
    return "not rejected by validateValueTypes naming it: " + \
        (err.replace("Use --debug flag to render out invalid YAML", "").strip()[:240] or "renders")


def render(chart, flags, values, tmp):
    fd, name = tempfile.mkstemp(suffix=".json", dir=tmp)
    with os.fdopen(fd, "w") as f:
        json.dump(values, f)
    out = subprocess.run(["helm", "template", "null-sweep", str(chart), "--skip-schema-validation",
                          *flags, "-f", name], capture_output=True, text=True)
    os.unlink(name)
    return out


def dotted(path):
    """A values path as the chart's messages print it: a.b[0].c."""
    out = ""
    for k in path:
        out += f"[{k}]" if isinstance(k, int) else (f".{k}" if out else str(k))
    return out


def needle(path):
    """What a message must contain to name the node at path."""
    last = path[-1]
    if isinstance(last, int):
        parent = next((k for k in reversed(path[:-1]) if not isinstance(k, int)), "")
        return f"{parent}[{last}]" if not isinstance(path[-2], int) else f"[{last}]"
    return str(last)


def verdict(out, base, path, unset=None):
    if out.returncode == 0:
        if unset is not None and unset.returncode == 0 and \
                TIMESTAMP.sub("", NULL_VALUE.sub("", out.stdout)) != TIMESTAMP.sub("", unset.stdout):
            return "renders otherwise than with the key removed: a null map value is not read as unset"
        if len(NULLISH.findall(out.stdout)) > len(NULLISH.findall(base)):
            new = [l.strip() for l in out.stdout.splitlines() if NULLISH.search(l) and l not in base.splitlines()]
            return f"renders a null: {new[0] if new else '(a null-looking line)'}"
        return None
    err = " ".join(out.stderr.split())
    m = FAIL.search(err)
    if m and not RAW.search(err[m.end():]):
        message = err[m.end():]
        if needle(path) in message or (len(path) > 1 and dotted(path[:-1]) in message):
            return None
        return f"fails without naming {needle(path)}: " + err[m.end():][:200]
    return err.replace("Use --debug flag to render out invalid YAML", "").strip()[:240]


def main(argv):
    flags = argv[argv.index("--") + 1:] if "--" in argv else []
    argv = argv[:argv.index("--")] if "--" in argv else argv
    chart, files = pathlib.Path(argv[0]), argv[1:]
    findings = []
    with tempfile.TemporaryDirectory() as tmp:
        scratch = pathlib.Path(tmp) / "values-to-json"
        (scratch / "templates").mkdir(parents=True)
        (scratch / "Chart.yaml").write_text("apiVersion: v2\nname: values-to-json\nversion: 0.0.0\n")
        (scratch / "templates" / "values.json").write_text("{{ .Values | toJson }}\n")
        jobs, bases = [], {}
        # "name" is left out: isSet reads it for one default (an ExternalSecret's
        # target), and the key names every other required field of the chart
        is_set = {k for t in (chart / "templates").rglob("*") if t.is_file()
                  for k in IS_SET.findall(t.read_text())} - {"name"}
        defaults = set(paths(to_json(chart / "values.yaml", scratch)))
        shape = values_shape(chart, tmp)
        schema = json.loads((chart / "values.schema.json").read_text())
        findings += shape_findings(shape, schema, schema)
        wrongs = []
        for f in files:
            values = to_json(f, scratch)
            findings += [f"{f}: {line}" for line in owner_findings(values, tmp, shape)]
            bases[f] = render(chart, flags, values, tmp).stdout
            jobs += [Case(f, p, None, nulled(values, p),
                          removed(values, p) if p[-1] in is_set and p not in defaults else None)
                     for p in paths(values)]
            wrongs += [Case(f, p, wrong, set_at(values, p, wrong))
                       for p in paths(values) for wrong in wrong_types(value_at(values, p))]

        def null_job(c):
            return verdict(render(chart, flags, c.values, tmp), bases[c.file], c.path,
                           render(chart, flags, c.unset, tmp) if c.unset is not None else None)

        def type_job(c):
            out = render(chart, flags, c.values, tmp)
            return type_verdict(out, c.path) if shape_at(shape, c.path) is not None else verdict(out, bases[c.file], c.path)

        with concurrent.futures.ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
            # map submits every job at once: both passes share the pool
            nulls, typed = pool.map(null_job, jobs), pool.map(type_job, wrongs)
            findings += [f"{c.file}: {'.'.join(map(str, c.path))} = {json.dumps(c.value)} → {v}"
                         for c, v in zip(jobs + wrongs, list(nulls) + list(typed)) if v]
    if findings:
        print("    FAIL: a null or a wrong type under --skip-schema-validation does not fail naming its values path:")
        for line in sorted(findings):
            print(f"          - {line}")
        sys.exit(1)
    print(f"    OK: {len(jobs)} nulls and {len(wrongs)} wrong types across {len(files)} scenarios render or fail naming their path")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__.rsplit("Usage: ", 1)[1])
    main(sys.argv[1:])
