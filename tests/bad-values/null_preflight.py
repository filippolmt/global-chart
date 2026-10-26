"""Scratch-only metadata/schema contracts, independent of mutation renders."""
import importlib.util
import json
import pathlib
import subprocess
import tempfile

spec = importlib.util.spec_from_file_location("schema_navigation", pathlib.Path(__file__).parent / "schema_navigation.py")
navigation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(navigation)


def to_json(values, scratch):
    out = subprocess.run(["helm", "template", "x", str(scratch), "-f", str(values)],
                         capture_output=True, text=True, check=True)
    return json.loads(out.stdout.split("\n", 2)[2])


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


def shape_findings(shape, schema, schema_path=(), path=""):
    """Every node where valuesShape reads other types than the schema accepts."""
    want = {"map"} if isinstance(shape, dict) else {"list"} if isinstance(shape, list) else set(shape.split("|"))
    declared = navigation.declaration(schema, schema_path)
    if declared is None:
        return [f"valuesShape: {path}: the schema declares no such node"]
    if declared.untyped:
        return [f"valuesShape: {path}: the schema accepts any type there through a branch with no type; "
                "give the branch one, or teach schema_navigation.py what it means"]
    got = declared.types
    out = [] if got == want else [f"valuesShape: {path}: reads {'|'.join(sorted(want))}, "
                                  f"the schema accepts {'|'.join(sorted(got)) or 'any type'}"]
    if isinstance(shape, dict):
        for key, child in shape.items():
            out += shape_findings(child, schema, schema_path + (key,), f"{path}.{key}" if path else key)
    elif isinstance(shape, list):
        out += shape_findings(shape[0], schema, schema_path + ("[]",), path + "[]")
    return out


def null_item_findings(fields, shape):
    """One-way reconciliation: only nullItemFields entries must be map lists."""
    # Where each scope's paths start in valuesShape. An owner is a workload or a
    # job; every job of every scope shares the *job anchor of valuesShape, so
    # hooks.*.* stands for all of them (owner_findings holds each owner to it)
    bases = {"root": [()], "owner": [("workloads", "*"), ("hooks", "*", "*")], "workload": [("workloads", "*")]}
    findings = []
    for scope, paths in fields.items():
        for dotted_path in paths:
            # x[] steps into the items of list x, as shape_at does on an index
            keys = tuple(k for part in dotted_path.split(".")
                         for k in ((part[:-2], 0) if part.endswith("[]") else (part,)))
            for base in bases.get(scope, [None]):
                node = shape_at(shape, base + keys) if base is not None else None
                item = node[0] if isinstance(node, list) else None
                if not (isinstance(item, dict) or (isinstance(item, str) and "map" in item.split("|"))):
                    where = ".".join(base) + "." if base else ""
                    findings.append(f"nullItemFields: {scope}: {dotted_path}: not a list of maps in valuesShape at "
                                    f"{where}{dotted_path}")
    return findings


def owner_findings(owners, shape):
    """Owners are scenario-reached and recognized by their volumes shape field."""
    specs = {o["path"]: shape_at(shape, tuple(o["path"].split("."))) for o in owners}
    return [f"valuesShape: {path}: a pod-spec owner podSpecOwners lists, with no pod spec in valuesShape"
            for path, spec in specs.items() if not (isinstance(spec, dict) and "volumes" in spec)]


def valid_shape(node):
    if isinstance(node, dict):
        return "Error" not in node and all(isinstance(k, str) and valid_shape(v) for k, v in node.items())
    if isinstance(node, list):
        return len(node) == 1 and valid_shape(node[0])
    return isinstance(node, str)


def preflight(chart, files):
    """Return (shape, ordered decoded scenarios, findings); own all scratch state."""
    chart = pathlib.Path(chart)
    shape, scenarios, findings = None, [], []

    def failed(label, error):
        findings.append(f"{label}: {' '.join(str(error).split())[:240]}")

    def read_json(path):
        try:
            value = json.loads(path.read_text())
            if value is None:
                raise ValueError("expected a schema object, got null")
            return value
        except (OSError, ValueError) as error:
            failed(path, error)
            return None

    def extract(label, command):
        try:
            out = subprocess.run(command, capture_output=True, text=True)
            if out.returncode:
                failed(label, f"Helm exited {out.returncode}: {out.stderr or out.stdout}")
                return None
            value = json.loads(out.stdout.split("\n", 2)[2])
            if value is None:
                raise ValueError("expected an object, got null")
            return value
        except (OSError, ValueError, IndexError) as error:
            failed(label, error)
            return None

    def metadata(label, scratch, template, flags=()):
        return extract(label, ["helm", "template", "x", str(scratch), "-s", f"templates/{template}.json", *flags])

    # Check required chart inputs without reading mutation-only defaults.
    for path in (chart / "Chart.yaml", chart / "values.yaml"):
        if not path.is_file():
            failed(path, "no such chart input file")
    schema = read_json(chart / "values.schema.json")
    if schema is not None and not isinstance(schema, dict):
        failed(chart / "values.schema.json", "expected a schema object")
        schema = None
    with tempfile.TemporaryDirectory() as tmp:
        scratch = pathlib.Path(tmp)
        templates = scratch / "templates"
        templates.mkdir()
        (scratch / "Chart.yaml").write_text("apiVersion: v2\nname: null-preflight\nversion: 0.0.0\n")
        helpers = list((chart / "templates").glob("_*.tpl"))
        helpers_ok = bool(helpers)
        if not helpers:
            failed(chart / "templates", "no helper files found")
        for helper in helpers:
            try:
                (templates / helper.name).write_text(helper.read_text())
            except (OSError, UnicodeError) as error:
                failed(helper, error)
                helpers_ok = False
        (templates / "shape.json").write_text('{{ include "global-chart.valuesShape" . | fromYaml | toJson }}\n')
        (templates / "null-items.json").write_text('{{ include "global-chart.nullItemFields" . | fromYaml | toJson }}\n')
        (templates / "owners.json").write_text('{"owners": {{ include "global-chart.podSpecOwners" . }}}\n')
        # Decode scenarios independently of broken helper extraction.
        decoder = scratch / "decoder"
        (decoder / "templates").mkdir(parents=True)
        (decoder / "Chart.yaml").write_text((scratch / "Chart.yaml").read_text())
        (decoder / "templates" / "values.json").write_text("{{ .Values | toJson }}\n")
        if helpers_ok:
            shape = metadata("valuesShape (_validate-helpers.tpl)", scratch, "shape")
            if shape is not None and not (isinstance(shape, dict) and valid_shape(shape)):
                failed("valuesShape (_validate-helpers.tpl)", "malformed shape (expected dictionaries, string leaves or single-item lists)")
                shape = None
            fields = metadata("nullItemFields (_validate-helpers.tpl)", scratch, "null-items")
            if fields is not None and not (isinstance(fields, dict) and "Error" not in fields and all(
                    isinstance(scope, str) and isinstance(items, dict) and all(isinstance(p, str) for p in items)
                    for scope, items in fields.items())):
                failed("nullItemFields (_validate-helpers.tpl)", "malformed scope/path containers")
                fields = None
            if shape is not None:
                if schema is not None:
                    findings.extend(shape_findings(shape, schema))
                if fields is not None:
                    findings.extend(null_item_findings(fields, shape))
        for file in files:
            try:
                pathlib.Path(file).read_text()
            except (OSError, UnicodeError) as error:
                failed(file, error)
                continue
            values = metadata(f"{file}: scenario decode", decoder, "values", ["-f", str(file)])
            if values is None:
                continue
            if not isinstance(values, dict) or "Error" in values:
                failed(file, "scenario decode: expected a values object")
                continue
            scenarios.append((file, values))
            if not helpers_ok:
                continue
            name = scratch / "scenario.json"
            name.write_text(json.dumps(values))
            data = metadata(f"{file}: podSpecOwners", scratch, "owners", ["-f", str(name)])
            if data is None:
                continue
            if not (isinstance(data, dict) and isinstance(data.get("owners"), list) and all(
                    isinstance(owner, dict) and isinstance(owner.get("path"), str) for owner in data["owners"])):
                failed(f"{file}: podSpecOwners", "malformed owner list (expected string path fields)")
                continue
            if shape is not None:
                findings.extend(f"{file}: {line}" for line in owner_findings(data["owners"], shape))
    return shape, scenarios, findings
