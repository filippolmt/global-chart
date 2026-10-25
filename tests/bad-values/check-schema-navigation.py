#!/usr/bin/env python3
"""Dependency-free public-query regression tests. Usage: check-schema-navigation.py --self-test"""
import importlib.util
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


navigation = load("schema_navigation", HERE / "schema_navigation.py")
sweep = load("null_sweep", HERE / "null-sweep.py")
bound = load("bound_sweep", HERE / "bound-sweep.py")
coverage = load("scenario_coverage", HERE.parent / "check-scenario-coverage.py")


def assert_sources(schema, path, pointers, generic=False):
    query = navigation.generic_sources if generic else navigation.sources
    result = query(schema, path)
    assert [p for p, _ in result] == pointers, (path, result)
    # Identity matters: merged copies would lose the source-local bounds contract.
    for pointer, node in result:
        original = schema
        for key in pointer.lstrip("/").split("/") if pointer else []:
            original = original[int(key)] if isinstance(original, list) else original[key]
        assert node is original, pointer
    return result


def declarations_test():
    schema = {"type": "object", "properties": {
        "untyped": {}, "null": {"type": "null"}, "const": {"const": "x"},
        "enum": {"enum": [1, 2]}, "nullable": {"type": ["null", "integer", "number"]},
        "group": {"oneOf": [
            {"allOf": [{"type": "object"}, {"properties": {"x": {"type": "string"}}}]},
            {"type": "array", "items": {"type": "boolean"}}]},
        "both": {"oneOf": [{"type": "boolean"}], "anyOf": [{"type": "string"}, {}]},
        "ref": {"$ref": "#/$defs/base", "type": "array", "items": {"type": "boolean"},
                "properties": {"sibling": {"type": "integer"}}}},
        "$defs": {"base": {"type": "object", "properties": {"x": {"type": "string"}}}}}
    expected = {
        (): ({"map"}, False), ("missing",): None,
        ("untyped",): (set(), True), ("null",): (set(), False),
        ("const",): (set(), True), ("enum",): (set(), True),
        ("nullable",): ({"number"}, False), ("group",): ({"map", "list"}, False),
        ("group", "x"): ({"string"}, False), ("group", "[]"): ({"boolean"}, False),
        ("both",): ({"string"}, True), ("ref",): ({"map"}, False),
        ("ref", "x"): ({"string"}, False), ("ref", "sibling"): None, ("ref", "[]"): None,
    }
    for path, want in expected.items():
        assert navigation.declaration(schema, path) == want, path
    assert_sources(schema, ("ref",), ["/properties/ref", "/$defs/base"])
    assert_sources(schema, ("ref", "sibling"), ["/properties/ref/properties/sibling"])
    assert_sources(schema, ("ref", 0), ["/properties/ref/items"])
    assert_sources(schema, ("both",), ["/properties/both", "/properties/both/oneOf/0",
                                             "/properties/both/anyOf/0", "/properties/both/anyOf/1"])


def nested_test():
    schema = {"allOf": [{"allOf": [{"type": "object", "properties": {
        "named": {"type": "array", "allOf": [{"items": {"type": "integer"}}]}},
        "additionalProperties": {"type": "string"},
        "patternProperties": {"^x": {"type": "boolean"}}}]}]}
    assert navigation.declaration(schema, ()) == ({"map"}, False)
    assert navigation.declaration(schema, ("named",)) == ({"list"}, False)
    assert navigation.declaration(schema, ("named", "[]")) == ({"number"}, False)
    assert navigation.declaration(schema, ("*",)) == ({"string", "boolean"}, False)
    assert navigation.declaration(schema, ("other",)) is None
    assert list(navigation.declared_paths(schema).items()) == [
        ("", {"map"}), ("named", {"list"}), ("named[]", {"number"}), ("*", {"string", "boolean"})]
    assert_sources(schema, ("named", 0), ["/allOf/0/allOf/0/properties/named/allOf/0/items"])
    assert_sources(schema, ("named",), ["/allOf/0/allOf/0/properties/named",
                                               "/allOf/0/allOf/0/properties/named/allOf/0"])
    assert_sources(schema, ("xyz",), ["/allOf/0/allOf/0/additionalProperties"])
    assert_sources({"patternProperties": {".*": {"type": "integer"}}}, ("xyz",), [])


def discovery_test():
    assert list(navigation.declared_paths({"properties": {
        "untyped": {}, "null": {"type": "null"}, "enum": {"enum": [1]}}}).items()) == [
        ("", set()), ("untyped", set()), ("null", set()), ("enum", set())]
    schema = {"type": "object", "properties": {"first": {"type": "string"}},
              "allOf": [{"properties": {"first": {"type": "number"}, "second": {"type": "array",
                         "items": {"type": "boolean"}}}}],
              "additionalProperties": {"type": "string"},
              "patternProperties": {"x": {"type": "integer"}, "y": {"type": "boolean"}}}
    assert list(navigation.declared_paths(schema).items()) == [
        ("", {"map"}), ("first", {"string", "number"}), ("*", {"string", "number", "boolean"}),
        ("second", {"list"}), ("second[]", {"boolean"})]
    chain = {"type": "string"}
    for _ in range(22):
        chain = {"type": "object", "properties": {"x": chain}}
    assert list(navigation.declared_paths(chain).items()) == [
        (".".join(["x"] * depth), {"map"}) for depth in range(21)]
    assert navigation.declaration(chain, ("x",) * 22) == ({"string"}, False)
    assert list(navigation.declared_paths({"type": "array", "items": {"type": "string"}}).items()) == [
        ("", {"list"}), ("[]", {"string"})]


def sources_test():
    schema = {"$ref": "#/$defs/base", "$defs": {"base": {"allOf": [{"properties": {
        "x": {"$ref": "#/$defs/leaf", "maximum": 9}}}]}, "leaf": {"type": "integer", "minimum": 2}},
        "allOf": [{"$ref": "#/$defs/base"}],
        "oneOf": [{"properties": {"x": {"type": "string"}}}],
        "anyOf": [{"properties": {"x": {"type": "boolean"}}}]}
    assert_sources(schema, (), ["", "/$defs/base", "/$defs/base/allOf/0", "/allOf/0",
                               "/$defs/base", "/$defs/base/allOf/0", "/oneOf/0", "/anyOf/0"])
    nodes = assert_sources(schema, ("x",), [
        "/$defs/base/allOf/0/properties/x", "/$defs/leaf",
        "/$defs/base/allOf/0/properties/x", "/$defs/leaf",
        "/oneOf/0/properties/x", "/anyOf/0/properties/x"])
    assert nodes[0][1] is nodes[2][1]
    assert nodes[1][1] is nodes[3][1]
    assert_sources(schema, ("missing",), [])
    assert_sources(schema, "", [], generic=True)
    arrays = {"properties": {"b": {"type": "array", "items": {"type": "array", "items": {
        "type": "integer", "minimum": 7, "maximum": 8}}}}}
    assert_sources(arrays, "b[]", ["/properties/b"], generic=True)
    assert_sources(arrays, "b[][]", ["/properties/b/items"], generic=True)
    assert_sources(arrays, "b[][][]", ["/properties/b/items/items"], generic=True)
    assert_sources(arrays, ("b", 0, 0), ["/properties/b/items/items"])


def candidates_test():
    schema = {"$defs": {"integer": {"type": "integer", "minimum": 3}}, "properties": {
        "n": {"$ref": "#/$defs/integer", "maximum": 4,
              "allOf": [{"type": "integer", "minimum": 8, "maximum": 9},
                        {"type": "integer", "minimum": 3}]}}}
    nodes = assert_sources(schema, ("n",), ["/properties/n", "/$defs/integer",
                                          "/properties/n/allOf/0", "/properties/n/allOf/1"])
    assert bound.candidates(nodes) == [3, 2147483647, 2147483648, 8, 9]
    assert bound.bounded(nodes)
    assert bound.candidates([("", {"type": ["null", "integer"], "minimum": 0, "maximum": 1})]) == [0, 1]
    assert bound.candidates([("", {"maximum": 1}), ("", {"type": "number", "minimum": 2})]) == []
    nodes = [("/$defs/ianaSvcName/allOf/1", {"pattern": "[a-z]"}),
             ("/$defs/ianaSvcName/allOf/0", {"pattern": "shape"}),
             ("/$defs/ianaSvcName", {"maxLength": 15}),
             ("/$defs/ianaSvcName/allOf/0", {"pattern": "shape"})]
    assert bound.candidates(nodes) == ["0a", "a-0", "on", "a" * 15]
    assert not bound.bounded(nodes[:1])
    assert bound.candidates([("/$defs/ianaSvcName/allOf/1", {
        "type": "integer", "minimum": 6, "pattern": "ignored"})]) == [6, 2147483647, 2147483648]
    assert not bound.bounded([])
    schema = {"$defs": {"untyped": {"minimum": 12, "maximum": 13}}, "properties": {
        "n": {"$ref": "#/$defs/untyped", "type": "integer", "minimum": 5}}}
    assert navigation.declaration(schema, ("n",)) == (set(), True)
    nodes = assert_sources(schema, ("n",), ["/properties/n", "/$defs/untyped"])
    assert bound.candidates(nodes) == [5, 2147483647, 2147483648]


def repository_test():
    schema = json.loads((HERE.parents[1] / "charts/global-chart/values.schema.json").read_text())
    account = ("workloads", "web", "serviceAccount", "name")
    assert navigation.declaration(schema, ("workloads", "*", "serviceAccount", "name")) == ({"string"}, True)
    nodes = assert_sources(schema, account, ["/$defs/serviceAccount/properties/name",
        "/$defs/serviceAccount/properties/name/anyOf/0", "/$defs/serviceAccount/properties/name/anyOf/1",
        "/$defs/dns1123Subdomain"])
    assert nodes[2][1]["maxLength"] == 253
    assert bound.candidates(nodes) == [bound.SUBDOMAIN_253, "0", "1e3", "true", "0a", "a.b-0"]
    assert navigation.declaration(schema, ("workloads", "*", "priorityClassName")) == ({"string"}, True)
    nodes = assert_sources(schema, ("workloads", "web", "priorityClassName"), [
        "/$defs/deployment/properties/priorityClassName", "/$defs/optionalObjectName",
        "/$defs/optionalObjectName/anyOf/0", "/$defs/optionalObjectName/anyOf/1",
        "/$defs/optionalObjectName/anyOf/2", "/$defs/dns1123Subdomain"])
    assert nodes[4][1]["maxLength"] == 253
    assert bound.candidates(nodes) == [bound.SUBDOMAIN_253, "0", "1e3", "true", "0a", "a.b-0"]
    for probe in ("livenessProbe", "startupProbe", "readinessProbe"):
        assert navigation.declaration(schema, ("workloads", "*", probe, "successThreshold")) == ({"number"}, False)
        pointers = ([f"/$defs/deployment/properties/{probe}/properties/successThreshold"]
                    if probe != "readinessProbe" else []) + ["/$defs/probe/properties/successThreshold"]
        nodes = assert_sources(schema, ("workloads", "web", probe, "successThreshold"), pointers)
        assert bound.candidates(nodes) == [2147483647]
        if probe != "readinessProbe":
            assert nodes[0][1]["const"] == 1
    jobs = [
        (("hooks", "pre-install", "run"), ("hooks", "*", "*"), "hookJob", "hookJobSpec", "rootJobSpec"),
        (("cronJobs", "run"), ("cronJobs", "*"), "cronJob", "cronJobSpec", "rootJobSpec"),
        (("workloads", "web", "hooks", "pre-install", "run"), ("workloads", "*", "hooks", "*", "*"),
         "deploymentHookJob", "hookJobSpec", "deploymentJobSpec"),
        (("workloads", "web", "cronJobs", "run"), ("workloads", "*", "cronJobs", "*"),
         "deploymentCronJob", "cronJobSpec", "deploymentJobSpec")]
    prefixes = {
        "hookJob": ["/properties/hooks/additionalProperties/additionalProperties",
                    "/properties/hooks/additionalProperties/additionalProperties/oneOf/0",
                    "/properties/hooks/additionalProperties/additionalProperties/oneOf/1"],
        "cronJob": ["/properties/cronJobs/additionalProperties"],
        "deploymentHookJob": ["/$defs/deployment/properties/hooks/additionalProperties/additionalProperties"],
        "deploymentCronJob": ["/$defs/deployment/properties/cronJobs/additionalProperties"],
    }
    for concrete, generic, composite, spec, scope in jobs:
        assert_sources(schema, concrete, prefixes[composite] + [
            f"/$defs/{composite}", f"/$defs/{composite}/allOf/0", "/$defs/jobCommon",
            f"/$defs/{composite}/allOf/1", f"/$defs/{spec}",
            f"/$defs/{composite}/allOf/2", f"/$defs/{scope}"])
        assert navigation.declaration(schema, generic) == ({"map"}, False)
        assert navigation.declaration(schema, generic + ("restartPolicy",)) == ({"string"}, False)
        assert_sources(schema, concrete + ("restartPolicy",), ["/$defs/jobCommon/properties/restartPolicy"])
        assert_sources(schema, concrete + ("serviceAccountName",), [
            "/$defs/jobCommon/properties/serviceAccountName", "/$defs/optionalObjectName",
            "/$defs/optionalObjectName/anyOf/0", "/$defs/optionalObjectName/anyOf/1",
            "/$defs/optionalObjectName/anyOf/2", "/$defs/dns1123Subdomain"])
        if spec == "hookJobSpec":
            assert navigation.declaration(schema, generic + ("weight",)) == ({"number", "string"}, False)
            assert_sources(schema, concrete + ("weight",), ["/$defs/hookJobSpec/properties/weight"])
        else:
            assert navigation.declaration(schema, generic + ("schedule",)) == ({"string"}, False)
            assert_sources(schema, concrete + ("schedule",), ["/$defs/cronJobSpec/properties/schedule"])
        key = "fromWorkload" if scope == "rootJobSpec" else "inheritWorkloadConfigMap"
        assert navigation.declaration(schema, generic + (key,)) == ({"string"} if scope == "rootJobSpec" else {"boolean"}, False)
        assert_sources(schema, concrete + (key,), [f"/$defs/{scope}/properties/{key}"])
        removed = "fromDeployment" if scope == "rootJobSpec" else "inheritDeploymentConfigMap"
        assert navigation.declaration(schema, generic + (removed,)) == (set(), True)
        assert_sources(schema, concrete + (removed,), [f"/$defs/{scope}/properties/{removed}"])
    assert navigation.declaration(schema, ("deployments",)) == (set(), True)
    assert navigation.declaration(schema, ("workloads", "*", "service", "portName")) == ({"string"}, True)
    nodes = assert_sources(schema, ("workloads", "web", "service", "portName"), [
        "/$defs/service/properties/portName", "/$defs/service/properties/portName/anyOf/0",
        "/$defs/service/properties/portName/anyOf/1", "/$defs/ianaSvcName",
        "/$defs/ianaSvcName/allOf/0", "/$defs/ianaSvcName/allOf/1"])
    assert bound.candidates(nodes) == ["on", "a" * 15, "0a", "a-0"]
    assert bound.table_findings(schema) == []


def callers_test():
    schema = {"type": "object", "properties": {
        "missingType": {}, "n": {"type": "integer"}, "nil": {"type": "null"},
        "a": {"type": "object", "properties": {"x": {"type": "array", "items": {"type": "string"}}}},
        "b": {"type": ["string", "integer"]}, "c": {"type": "integer", "minimum": 1, "maximum": 2}}}
    assert sweep.shape_findings({"absent": "string", "missingType": "string", "n": "string", "nil": "string"}, schema) == [
        "valuesShape: absent: the schema declares no such node",
        "valuesShape: missingType: the schema accepts any type there through a branch with no type; give the branch one, or teach schema_types what it means",
        "valuesShape: n: reads string, the schema accepts number",
        "valuesShape: nil: reads string, the schema accepts any type"]
    assert sweep.shape_findings({"absent": {"nested": "string"}, "missingType": ["map"]}, schema) == [
        "valuesShape: absent: the schema declares no such node",
        "valuesShape: missingType: the schema accepts any type there through a branch with no type; give the branch one, or teach schema_types what it means"]
    assert sweep.shape_findings({"a": {"x": ["string"]}, "b": "number|string", "c": "number"}, schema) == []
    paths = navigation.declared_paths(schema)
    assert coverage.gaps(schema, paths, {"": {"map"}, "b": {"number"}}) == {
        "a: never set", "b: never string", "c: never set", "n: never set"}
    assert coverage.below(schema, paths, {"": {"map"}}, "a") == ["x"]
    assert coverage.gaps(schema, paths, {"": {"map"}, "a": {"map"}, "b": {"number", "string"}, "c": {"number"}}) == {"a.x: never set", "n: never set"}
    assert coverage.below(schema, paths, {"a.x": {"list"}}, "a") == []
    arrays = {"properties": {"b": {"type": "array", "items": {"type": "array", "items": {
        "type": "integer", "minimum": 1, "maximum": 2}}}}}
    assert not coverage.bounded(arrays, "b[]")
    assert not coverage.bounded(arrays, "b[][]")
    assert coverage.bounded(arrays, "b[][][]")
    pattern = {"type": "object", "patternProperties": {".*": {
        "type": "integer", "minimum": 1, "maximum": 2}}}
    assert navigation.declared_paths(pattern) == {"": {"map"}, "*": {"number"}}
    assert not coverage.bounded(pattern, "*")
    assert coverage.gaps(pattern, navigation.declared_paths(pattern), {"": {"map"}}) == set()


def self_test():
    declarations_test()
    nested_test()
    discovery_test()
    sources_test()
    candidates_test()
    repository_test()
    callers_test()
    print("    OK: schema navigation self-test")


if __name__ == "__main__":
    if sys.argv[1:] != ["--self-test"]:
        sys.exit(__doc__)
    self_test()
