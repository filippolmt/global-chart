#!/usr/bin/env python3
"""Scratch-only null-sweep preflight contracts and its orchestration gate (issue #267).

Synthetic metadata and scenarios live only in temporary directories; Helm is
mocked, including its failure modes. A deliberate broken reconciliation must
produce the same clean, line-naming FAIL as a real regression.

Usage: check-null-preflight.py --self-test
"""
from contextlib import ExitStack, contextmanager, redirect_stdout
import copy
import importlib.util
import io
import json
import pathlib
import subprocess
import sys
import tempfile
import traceback
from types import SimpleNamespace
from unittest.mock import patch

HERE = pathlib.Path(__file__).resolve().parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


pre = load("null_preflight", HERE / "null_preflight.py")
sweep = load("null_sweep", HERE / "null-sweep.py")


def schema_for(shape):
    if isinstance(shape, dict):
        return {"type": "object", "properties": {k: schema_for(v) for k, v in shape.items() if k != "*"},
                **({"additionalProperties": schema_for(shape["*"])} if "*" in shape else {})}
    if isinstance(shape, list):
        return {"type": "array", "items": schema_for(shape[0])}
    types = {"map": "object", "list": "array", "number": "number", "string": "string", "boolean": "boolean"}
    return {"type": [types[t] for t in shape.split("|")]}


@contextmanager
def fixture():
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        chart = root / "chart"
        (chart / "templates").mkdir(parents=True)
        (chart / "templates/_helpers.tpl").write_text("{{/* synthetic helpers */}}\n")
        (chart / "Chart.yaml").write_text("apiVersion: v2\nname: test\nversion: 0.0.0\n")
        (chart / "values.yaml").write_text("{}\n")
        shape = {"workloads": {"*": {"volumes": ["map"], "env": ["map"]}}, "items": ["map|string"]}
        schema = schema_for(shape)
        (chart / "values.schema.json").write_text(json.dumps(schema))
        files = [str(root / f"scenario-{n}.yaml") for n in range(2)]
        values = [{"workloads": {"app": {"kind": kind, "volumes": [], "env": []}}, "items": []}
                  for kind in ("Deployment", "StatefulSet")]
        for file, value in zip(files, values):
            pathlib.Path(file).write_text(json.dumps(value))
        state = SimpleNamespace(chart=chart, files=files, values=values, shape=shape, schema=schema,
                                fields={"owner": {"env": ["name"]}}, owners=[[{"path": "workloads.app"}]] * 2,
                                overrides={}, calls=[])

        def helm(command, **kwargs):
            state.calls.append(command)
            scratch = pathlib.Path(command[3])
            assert scratch != chart, "preflight rendered the real chart"
            assert (scratch / "Chart.yaml").is_file()
            assert kwargs == {"capture_output": True, "text": True}, kwargs
            template = pathlib.Path(command[command.index("-s") + 1]).stem
            if template == "values":
                file = command[command.index("-f") + 1]
                result = state.values[state.files.index(file)]
            elif template == "owners":
                value = json.loads(pathlib.Path(command[command.index("-f") + 1]).read_text())
                result = {"owners": state.owners[state.values.index(value)]}
            else:
                result = {"shape": state.shape, "null-items": state.fields}[template]
            override = state.overrides.get(template)
            if isinstance(override, Exception):
                raise override
            return override or subprocess.CompletedProcess(command, 0, "---\n# Source: scratch\n" + json.dumps(result), "")

        # Owner scope applies to jobs as well as workloads.
        state.shape["hooks"] = {"*": {"*": {"volumes": ["map"], "env": ["map"]}}}
        state.schema = schema_for(state.shape)
        (chart / "values.schema.json").write_text(json.dumps(state.schema))
        with patch.object(pre.subprocess, "run", side_effect=helm):
            yield state


def reconciliations_test():
    with fixture() as f:
        assert pre.preflight(f.chart, f.files) == (f.shape, list(zip(f.files, f.values)), [])
        assert len(f.calls) == 6, f.calls  # Shape, fields, decode + owners for both scenarios.
    # Each contract can fail alone, and none suppresses either of the others.
    for mask in range(1, 8):
        with fixture() as f:
            if mask & 1:
                f.schema["properties"]["items"] = {"type": "string"}
                (f.chart / "values.schema.json").write_text(json.dumps(f.schema))
            if mask & 2:
                f.fields["root"] = {"missing": ["name"]}
            if mask & 4:
                f.owners[-1] = [{"path": "workloads.last.hooks.pre-install.run"}]
            shape, scenarios, findings = pre.preflight(f.chart, f.files)
            assert shape == f.shape and scenarios == list(zip(f.files, f.values))
            assert any("schema accepts" in line for line in findings) == bool(mask & 1), findings
            assert any("nullItemFields:" in line for line in findings) == bool(mask & 2), findings
            assert any("pod-spec owner" in line for line in findings) == bool(mask & 4), findings
            if mask & 4:
                assert any(f.files[-1] in line and "workloads.last.hooks.pre-install.run" in line
                           for line in findings), findings
            assert len(f.calls) == 6, f.calls


def shapes_test():
    shape = {"nested": [[{"entries": ["map|string"]}]], "extra": ["map"]}
    assert pre.shape_findings(shape, schema_for(shape)) == []
    assert pre.null_item_findings({"root": ["nested[].entries"]}, shape)
    shape = {"nested": [{"entries": ["map|string"]}], "extra": ["map"], "strings": ["string"]}
    assert pre.null_item_findings({"root": {"nested[].entries": ["name"]}}, shape) == []
    assert pre.null_item_findings({"root": {"bundles[].files": ["name"]}},
                                  {"bundles": [{"files": ["map"]}]}) == []
    assert pre.null_item_findings({"root": ["nested"]}, shape) == []
    assert pre.null_item_findings({}, shape) == []  # The reconciliation is deliberately one-way.
    assert pre.null_item_findings({"root": ["strings"]}, shape)
    assert pre.null_item_findings({"unknown": ["extra"]}, shape)
    assert pre.shape_at(shape, ("nested", 0, "entries", 1)) == "map|string"
    assert pre.shape_findings({"a": "map|string"}, {"type": "object", "properties": {
        "a": {"oneOf": [{"type": "object"}, {"type": "string"}, {"type": "null"}]}}}) == []
    assert pre.shape_findings({"a": "map"}, {"type": "object", "properties": {"a": {}}})
    for kind in ("Deployment", "StatefulSet"):
        owners = [{"path": "workloads.app", "kind": kind}]
        assert pre.owner_findings(owners, {"workloads": {"*": {"volumes": ["map"]}}}) == []
        assert pre.owner_findings(owners, {"workloads": {"*": {"env": ["map"]}}})
        assert pre.owner_findings(owners, {"workloads": {"*": "map"}})
    with fixture() as f:
        f.shape["workloads"]["*"]["hooks"] = {"*": {"*": {"volumes": ["map"]}}}
        f.shape["cronJobs"] = {"*": {"volumes": ["map"]}}
        f.shape["workloads"]["*"]["cronJobs"] = {"*": {"volumes": ["map"]}}
        owners = [{"path": p} for p in ("hooks.pre-install.run", "cronJobs.run",
                  "workloads.app.hooks.pre-upgrade.run", "workloads.app.cronJobs.run")]
        assert pre.owner_findings(owners, f.shape) == []


def malformed_test():
    for template, bads in {
        "shape": [None, [], {"Error": "bad"}, {"x": []}, {"x": ["map", "string"]}, {"x": 3}],
        "null-items": [None, [], {"Error": "bad"}, {"root": "env"}, {"root": [3]}, {"root": ["env"]}],
        "owners": [None, [], {}, {"owners": {}}, {"owners": [{}]}, {"owners": [{"path": 3}]}],
        "values": [None, [], "bad", {"Error": "bad"}],
    }.items():
        for bad in bads:
            with fixture() as f:
                f.overrides[template] = subprocess.CompletedProcess([], 0, "---\n# Source: scratch\n" + json.dumps(bad), "")
                _, _, findings = pre.preflight(f.chart, f.files)
                assert findings, (template, bad)
                assert any("malformed" in line or "expected" in line or "null" in line.lower() for line in findings), findings
    for template in ("shape", "null-items", "owners", "values"):
        for stdout in ("", "---\n# Source: scratch\nnot JSON"):
            with fixture() as f:
                f.overrides[template] = subprocess.CompletedProcess([], 0, stdout, "")
                assert pre.preflight(f.chart, f.files)[2], (template, stdout)
        with fixture() as f:
            # Valid-looking output must never rescue a failed Helm invocation.
            f.overrides[template] = subprocess.CompletedProcess([], 7, '---\n# Source: scratch\n{}', "deliberate helm failure")
            findings = pre.preflight(f.chart, f.files)[2]
            assert any("Helm exited 7" in line and "deliberate helm failure" in line for line in findings), findings
    with fixture() as f, patch.object(pre.subprocess, "run", side_effect=FileNotFoundError("helm missing")):
        findings = pre.preflight(f.chart, f.files)[2]
        assert any("helm missing" in line for line in findings), findings


def files_test():
    for bad in ("not JSON", "[]", "null"):
        with fixture() as f:
            (f.chart / "values.schema.json").write_text(bad)
            shape, scenarios, findings = pre.preflight(f.chart, f.files)
            assert shape == f.shape and len(scenarios) == 2
            assert any("values.schema.json" in line for line in findings), findings
    for target in ("Chart.yaml", "values.yaml", "values.schema.json", "templates/_helpers.tpl", "scenario"):
        with fixture() as f:
            path = pathlib.Path(f.files[-1]) if target == "scenario" else f.chart / target
            path.unlink()
            _, scenarios, findings = pre.preflight(f.chart, f.files)
            assert findings and any(str(path) in line or "no helper files" in line for line in findings), findings
            assert len(scenarios) == (1 if target == "scenario" else 2)
    for target in ("templates/_helpers.tpl", "scenario"):
        with fixture() as f:
            path = pathlib.Path(f.files[-1]) if target == "scenario" else f.chart / target
            read_text = pathlib.Path.read_text

            def unreadable(p, *args, **kwargs):
                if p == path:
                    raise PermissionError("deliberately unreadable")
                return read_text(p, *args, **kwargs)

            with patch.object(pathlib.Path, "read_text", unreadable):
                findings = pre.preflight(f.chart, f.files)[2]
            assert any(str(path) in line and "deliberately unreadable" in line for line in findings), findings
    with fixture() as f:
        before = {p.relative_to(f.chart): p.read_bytes() for p in f.chart.rglob("*") if p.is_file()}
        pre.preflight(f.chart, f.files)
        assert before == {p.relative_to(f.chart): p.read_bytes() for p in f.chart.rglob("*") if p.is_file()}
        assert all(not pathlib.Path(command[3]).exists() for command in f.calls), "scratch leaked"


def invoke(argv):
    output = io.StringIO()
    with redirect_stdout(output):
        try:
            result = sweep.main(argv)
        except SystemExit as error:
            result = error.code
    return result or 0, output.getvalue()


def orchestration_test():
    for standalone, failed in ((True, False), (True, True), (False, True)):
        with fixture() as f, ExitStack() as stack:
            findings = [f"{f.files[-1]}: deliberate preflight finding"] if failed else []
            gate = stack.enter_context(patch.object(sweep, "preflight", return_value=(f.shape, list(zip(f.files, f.values)), findings)))
            spies = [stack.enter_context(patch.object(sweep, name, side_effect=AssertionError(f"{name} before gate")))
                     for name in ("render", "Case", "nulled", "set_at", "removed", "paths", "wrong_types", "to_json")]
            executor = stack.enter_context(patch.object(sweep.concurrent.futures, "ThreadPoolExecutor",
                                                       side_effect=AssertionError("executor before gate")))
            args = (["--preflight-only"] if standalone else []) + [str(f.chart), *f.files]
            code, output = invoke(args)
            assert code == int(failed), output
            gate.assert_called_once_with(f.chart, f.files)
            assert all(not spy.called for spy in [*spies, executor])
            if failed:
                assert "FAIL:" in output and findings[0] in output, output
            else:
                assert "OK:" in output, output
    with fixture() as f:
        flags = ["--api-versions", "example/v1", "--set", "example=true"]
        renders, passes = [], []

        def render(chart, forwarded, values, tmp):
            gate.assert_called_once_with(f.chart, f.files)
            assert chart == f.chart and forwarded == flags, (chart, forwarded)
            renders.append(copy.deepcopy(values))
            return subprocess.CompletedProcess([], 0, "", "")

        class Pool:
            def __init__(self, **kwargs):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def map(self, fn, cases):
                cases = list(cases)
                passes.append(cases)
                return list(map(fn, cases))

        with patch.object(sweep, "preflight", return_value=(f.shape, list(zip(f.files, f.values)), [])) as gate, \
                patch.object(sweep, "render", side_effect=render), \
                patch.object(sweep, "to_json", return_value={}), \
                patch.object(sweep, "verdict", return_value=None), \
                patch.object(sweep, "type_verdict", return_value=None), \
                patch.object(sweep.concurrent.futures, "ThreadPoolExecutor", Pool):
            code, output = invoke([str(f.chart), *f.files, "--", *flags])
            assert code == 0 and "OK:" in output, output
            # The standalone spelling after -- is only a forwarded Helm flag.
            gate.reset_mock()
            renders.clear()
            passes.clear()
            flags.append("--preflight-only")
            code, output = invoke([str(f.chart), *f.files, "--", *flags])
        assert code == 0 and "OK:" in output and "no baselines" not in output, output
        gate.assert_called_once_with(f.chart, f.files)
        assert len(passes) == 2 and all(passes), passes
        assert len(passes[0]) == sum(len(list(sweep.paths(v))) for v in f.values)
        assert len(passes[1]) == sum(len(sweep.wrong_types(sweep.value_at(v, p)))
                                     for v in f.values for p in sweep.paths(v))
        assert all(c.value is None for c in passes[0])
        assert all(c.value is not None for c in passes[1])
        assert renders[:2] == f.values and len(renders) > 2, renders


def red_probe_test():
    output = io.StringIO()
    with patch.object(pre, "shape_findings", return_value=[]), redirect_stdout(output):
        assert run([reconciliations_test]) == 1
    text = output.getvalue()
    assert text.startswith(f"    FAIL: {pathlib.Path(__file__).name}:"), text
    assert "reconciliations_test" in text and "Traceback" not in text, text


TESTS = [reconciliations_test, shapes_test, malformed_test, files_test, orchestration_test, red_probe_test]


def run(tests):
    try:
        for test in tests:
            test()
    except Exception as error:
        frames = traceback.extract_tb(error.__traceback__)
        frame = next((f for f in reversed(frames) if f.name.endswith("_test")), frames[-1])
        print(f"    FAIL: {pathlib.Path(frame.filename).name}:{frame.lineno}: {frame.name}: "
              f"{frame.line}{f' ({error})' if str(error) else ''}")
        return 1
    return 0


def main(argv):
    if argv != ["--self-test"]:
        sys.exit(__doc__.rsplit("Usage: ", 1)[1])
    if run(TESTS):
        return 1
    print("    OK: null preflight self-test")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
