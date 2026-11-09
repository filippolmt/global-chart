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
and restores it on a removal; a key under a list item is not, since Helm
replaces a list whole and the example lists of values.yaml default nothing) —
or unless its output carries more null-looking lines — `<nil>`, a `- null`
list item, an empty `name:` — than the scenario's own render: a null that reached
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

Before any baseline or mutation work, null_preflight.py verifies the scratch
helper metadata/schema contracts and every scenario's reached pod-spec owners.
--preflight-only stops there: it checks no real-chart baselines or mutations.

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
reject, so such a node joins valuesShape by hand, with its fixture. Each list
nullItemFields names, whose required fields validateNullItems checks, must be a
list of maps in valuesShape (issue #238): the two helpers walk the same nodes.

Comparisons ignore generated Basic Auth password/hash values only (the source
and Secret kind identify them), like the pod recreation timestamp. Username,
keys and other Secret data remain comparable. check-basic-auth.py separately
verifies the random password and its htpasswd hash against the standard format.

--render-as-unset (issue #292) checks hand-written files instead of sweeping
scenarios: tests/bad-values/skip-schema-render/, shapes the schema rejects, so
no scenario carries them and no sweep reaches them (a probe with exec set and
httpGet null). Each file must carry a null map value, none on a map key
values.yaml defaults (Helm deletes the default on a null and restores it on a
removal; a key under a list item is exempt, since Helm replaces a list whole).
helm lint must reject each null by its own pointer (`at '/a/b': got null`),
so a file the schema rejects for another reason does not pass. Each file must
then render exactly as the same file with every null map value removed.

Usage: null-sweep.py [--preflight-only | --render-as-unset] <chart dir> <values file>... [-- <helm flags>...]
"""
import concurrent.futures
import importlib.util
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
from typing import NamedTuple

spec = importlib.util.spec_from_file_location("null_preflight", pathlib.Path(__file__).parent / "null_preflight.py")
contracts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contracts)
# Compatibility bindings: bound-sweep and scenario coverage import this module.
to_json = contracts.to_json
shape_at = contracts.shape_at
shape_findings = contracts.shape_findings
preflight = contracts.preflight

# `%!` is a Go fmt error: a value of the wrong type printed into a message
RAW = re.compile(r"nil pointer|error calling|wrong type for value|can't evaluate|"
                 r"executing \"|invalid value; expected|incompatible types|error converting YAML|%!")
FAIL = re.compile(r"execution error at \([^)]*\): ")
# A `key: null` line toYaml writes for a passthrough value: the API server
# reads it as the key absent, so the comparison with the key removed drops it.
# On a list item's first line the dash moves to the next key, or the item is
# left `- {}`, as toYaml writes it without the key.
NULL_VALUE = re.compile(r"^[ \t]*[^\s:-][^:\n]*:[ \t]+null[ \t]*\n", re.M)
NULL_ITEM_HEAD = re.compile(r"^([ \t]*)- [^\s:][^:\n]*:[ \t]+null[ \t]*\n(?:\1  (?=\S))?", re.M)


def drop_nulls(text):
    """text as toYaml writes it with every `key: null` of a map removed."""
    while True:
        dropped = NULL_ITEM_HEAD.sub(lambda m: m[1] + ("- " if m[0].endswith("  ") else "- {}\n"), text)
        if dropped == text:
            return NULL_VALUE.sub("", text)
        text = dropped


def drop_nulls_self_test():
    assert drop_nulls("a:\n  b: null\n  c: 1\n") == "a:\n  c: 1\n"
    assert drop_nulls("ports:\n  - port: null\n    protocol: TCP\n") == "ports:\n  - protocol: TCP\n"
    assert drop_nulls("x:\n- a: null\n  b: null\n  c: 1\n") == "x:\n- c: 1\n"
    assert drop_nulls("x:\n  - a: null\n  - b: 2\n") == "x:\n  - {}\n  - b: 2\n"
    assert drop_nulls("x:\n  - null\n") == "x:\n  - null\n"
# podRecreation stamps the pod template with the render time: two renders a
# second apart differ there and nowhere else
TIMESTAMP = re.compile(r'^\s*timestamp: "\d{14}"\n', re.M)
# The keys the templates read through isSet: a null on one must render as the
# key absent. Read from the templates, so the list cannot drift from them.
IS_SET = re.compile(r'isSet" \(list \S+ "(\w+)"\)')
# validateProbeHandler reads its handlers through isSet off a literal list
# (issue #288), parsed by lint-templates' probe_handler_list: one parser of it.
# shortcut: this one helper by name, and only literal isSet keys besides;
# issue #294 replaces both with a removal case for every null map value.
_lint = importlib.util.spec_from_file_location("lint_templates", pathlib.Path(__file__).parent.parent / "lint-templates.py")
lint_templates = importlib.util.module_from_spec(_lint)
_lint.loader.exec_module(lint_templates)


def is_set_keys(text):
    """The keys a template reads through isSet."""
    return set(IS_SET.findall(text)) | set(lint_templates.probe_handler_list(text) or ())


def is_set_keys_self_test():
    assert is_set_keys('isSet" (list $deploy "enabled")') == {"enabled"}
    helper = '{{- define "global-chart.validateProbeHandler" -}}\n{{- $handlers := list "exec" "httpGet" -}}'
    assert is_set_keys(helper) == {"exec", "httpGet"}
NULLISH = re.compile(r"<nil>|^\s*-\s+null\s*$|^\s*-?\s*name:\s*(\"\")?\s*$", re.M)


def paths(node, prefix=()):
    """Yield the path of every map value and list item under node."""
    items = node.items() if isinstance(node, dict) else enumerate(node) if isinstance(node, list) else ()
    for key, value in items:
        yield prefix + (key,)
        yield from paths(value, prefix + (key,))


def defaulted(path, defaults):
    """values.yaml defaults the key at path: Helm merges maps, and replaces a list whole."""
    return path in defaults and not any(isinstance(k, int) for k in path)


def defaulted_self_test():
    assert defaulted(("ingress", "enabled"), {("ingress", "enabled")})
    assert not defaulted(("ingress", "hosts", 0, "service"), {("ingress", "hosts", 0, "service")})


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


def stable_render(text):
    """Ignore only volatile password/hash values of chart-generated Basic Auth Secrets.

    Keep username, keys and all other Secret data comparable; the independent
    credential check verifies password/hash consistency on actual renders.
    """
    docs = text.split("\n---")
    for i, doc in enumerate(docs):
        if "# Source: global-chart/templates/securitypolicy.yaml\n" in doc and "\nkind: Secret\n" in doc:
            docs[i] = re.sub(r'^(  (?:password|\.htpasswd): )"[A-Za-z0-9+/=]+"[ \t]*$',
                             r'\1"<random>"', doc, flags=re.M)
    return TIMESTAMP.sub("", "\n---".join(docs))


def stable_render_self_test():
    doc = '# Source: global-chart/templates/securitypolicy.yaml\nkind: Secret\ndata:\n  username: "dXNlcg=="\n  password: "YQ=="\n  .htpasswd: "Yg=="\n'
    changed = doc.replace('"YQ=="', '"Yw=="').replace('"Yg=="', '"ZA=="')
    assert stable_render(doc) == stable_render(changed)
    assert stable_render(doc) != stable_render(doc.replace('"dXNlcg=="', '"YWRtaW4="'))
    assert stable_render(doc) != stable_render(doc.replace('  password: "YQ=="\n', ''))
    other = doc.replace("securitypolicy.yaml", "secret.yaml")
    assert stable_render(other) != stable_render(other.replace('"YQ=="', '"Yw=="'))


def verdict(out, base, path, unset=None):
    if out.returncode == 0:
        if unset is not None and unset.returncode == 0 and \
                stable_render(drop_nulls(out.stdout)) != stable_render(unset.stdout):
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


def values_to_json_chart(tmp):
    """A scratch chart printing its values as JSON, for to_json."""
    scratch = pathlib.Path(tmp) / "values-to-json"
    (scratch / "templates").mkdir(parents=True)
    (scratch / "Chart.yaml").write_text("apiVersion: v2\nname: values-to-json\nversion: 0.0.0\n")
    (scratch / "templates" / "values.json").write_text("{{ .Values | toJson }}\n")
    return scratch


def null_keys(node, prefix=()):
    """The path of every null map value under node."""
    if isinstance(node, dict):
        for key, value in node.items():
            if value is None:
                yield prefix + (key,)
            yield from null_keys(value, prefix + (key,))
    elif isinstance(node, list):
        for i, item in enumerate(node):
            yield from null_keys(item, prefix + (i,))


def null_keys_self_test():
    assert list(null_keys({"a": None, "b": [{"c": None}, None], "d": {"e": 1}})) == [("a",), ("b", 0, "c")]
    assert pointer(("a", 0, "c")) == "/a/0/c"
    assert pointer(("a", "checksum/config", "x~y")) == "/a/checksum~1config/x~0y"
    assert first_difference("x\ny: 1\n", "x\n") == ": renders y: 1"
    assert first_difference("x\n", "x\ny: 1\n") == ": lacks y: 1"


def pointer(path):
    """A values path as a JSON pointer, as the schema errors of helm lint print it:
    RFC 6901 escapes, so checksum/config is checksum~1config."""
    return "/" + "/".join(str(k).replace("~", "~0").replace("/", "~1") for k in path)


def first_difference(out, ref):
    """The first line one render has and the other lacks, for a finding's message."""
    a, b = out.splitlines(), ref.splitlines()
    sa, sb = set(a), set(b)
    lines = [f"renders {l.strip()}" for l in a if l not in sb] + [f"lacks {l.strip()}" for l in b if l not in sa]
    return f": {lines[0]}" if lines else ""


def render_as_unset(chart, files, flags):
    """Each file renders as itself with its null map values removed."""
    findings = []
    with tempfile.TemporaryDirectory() as tmp:
        scratch = values_to_json_chart(tmp)
        defaults = set(paths(to_json(chart / "values.yaml", scratch)))
        for f in files:
            values = to_json(f, scratch)
            nulls = list(null_keys(values))
            if not nulls:
                findings.append(f"{f}: carries no null map value; green here would be vacuous")
                continue
            if with_default := [dotted(p) for p in nulls if defaulted(p, defaults)]:
                findings.append(f"{f}: {', '.join(with_default)} has a default in values.yaml, so its null is not its removal")
                continue
            lint = subprocess.run(["helm", "lint", "--strict", "-f", f, str(chart)], capture_output=True, text=True)
            if unrejected := [dotted(p) for p in nulls if f"at '{pointer(p)}': got null" not in lint.stdout + lint.stderr]:
                findings.append(f"{f}: the schema does not reject the null at {', '.join(unrejected)}"
                                " (if every file fails here, check whether Helm reworded `at '<pointer>': got null`)")
                continue
            unset = values
            for p in nulls:
                unset = removed(unset, p)
            out, ref = render(chart, flags, values, tmp), render(chart, flags, unset, tmp)
            if out.returncode or ref.returncode:
                findings.append(f"{f}: does not render: " + " ".join((out.stderr or ref.stderr).split())[:240])
            elif (a := stable_render(out.stdout)) != (b := stable_render(ref.stdout)):
                findings.append(f"{f}: renders otherwise than with {', '.join(map(dotted, nulls))} removed"
                                + first_difference(a, b))
    if findings:
        print("    FAIL: a skip-schema-render file is not rejected by the schema at its nulls, or does not render as their removal:")
        for line in findings:
            print(f"          - {line}")
        sys.exit(1)
    print(f"    OK: {len(files)} skip-schema-render files render as their nulls removed")


def main(argv):
    stable_render_self_test()
    drop_nulls_self_test()
    is_set_keys_self_test()
    defaulted_self_test()
    null_keys_self_test()
    flags = argv[argv.index("--") + 1:] if "--" in argv else []
    argv = argv[:argv.index("--")] if "--" in argv else argv
    standalone = "--preflight-only" in argv
    argv = [arg for arg in argv if arg != "--preflight-only"]
    as_unset = "--render-as-unset" in argv
    argv = [arg for arg in argv if arg != "--render-as-unset"]
    if len(argv) < 2:
        sys.exit(__doc__.rsplit("Usage: ", 1)[1])
    chart, files = pathlib.Path(argv[0]), argv[1:]
    if as_unset:
        return render_as_unset(chart, files, flags)
    shape, scenarios, findings = preflight(chart, files)
    if findings:
        print("    FAIL: null-sweep preflight contracts:")
        for line in findings:
            print(f"          - {line}")
        sys.exit(1)
    if standalone:
        print(f"    OK: preflight metadata/schema contracts and reached owners across {len(scenarios)} scenarios (no baselines or mutations checked)")
        return
    findings = []
    with tempfile.TemporaryDirectory() as tmp:
        scratch = values_to_json_chart(tmp)
        jobs, bases = [], {}
        # "name" is left out: isSet reads it for one default (an ExternalSecret's
        # target), and the key names every other required field of the chart
        is_set = {k for t in (chart / "templates").rglob("*") if t.is_file()
                  for k in is_set_keys(t.read_text())} - {"name"}
        defaults = set(paths(to_json(chart / "values.yaml", scratch)))
        wrongs = []
        for f, values in scenarios:
            bases[f] = render(chart, flags, values, tmp).stdout
            jobs += [Case(f, p, None, nulled(values, p),
                          removed(values, p) if p[-1] in is_set and not defaulted(p, defaults) else None)
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
