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
CRD API versions.

A null map value is unset (CODING_STANDARDS.md, *A null means one thing per
kind of node*), so it is rendered beside the same key removed and the two must
match: both fail, whatever the message (the path of a `fail` is the suites'),
or both render the same manifests, a `key: null` line included — the API
server reads it as `""` or `"0"`, not as the key absent (issue #294). The
comparison is textual, after stable_render: a difference of YAML style alone
would show as a finding, never hide one. A map the removal empties stays `{}`
(see removed()). This holds for a list item's optional fields too. A key
values.yaml defaults is left out: Helm deletes the default on a null and
restores it on a removal (a key under a list item is not, since Helm replaces
a list whole and the example lists of values.yaml default nothing).
EXCEPTIONS lists the paths whose null is not their removal, each under the
class CODING_STANDARDS.md names (a number printScalar renders, a required
item field, ConfigMap and Secret data, a reference to an empty entry). Where
such a null differs from its removal it must fail naming its path, except a
null inside a structured ConfigMap or Secret value, which renders as written.
A row no finding needs fails the sweep, so no row outlives its reason; that
holds for a run over every TEST_CASES scenario, as make null-sweep does, and a
run over fewer reports the rows those scenarios do not reach.
shortcut: the sweep sees only the nodes the scenarios set; when a regression
turns up on a leaf none sets, add it to a scenario.

Every null that renders — a map value as its removal does, a list item, a
defaulted key, an excepted path — must also render with no more null-looking lines (`<nil>`, a `- null` list item, an
empty `name:`) than the scenario's own render, or fail with a template `fail`
or `required` (`execution error at (…): <message>`) whose message names the
nulled node — its key, or `<list>[<i>]` for a list item — or the node holding
it, and carries no raw template error: a fail about another key is the null
reaching a check it was never meant for. Anything else is a finding: the
template path and the error are printed.

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
# podRecreation stamps the pod template with the render time: two renders a
# second apart differ there and nowhere else
TIMESTAMP = re.compile(r'^\s*timestamp: "\d{14}"\n', re.M)
# The surfaces a job inherits, read through isSetPassthrough on the job: a map
# of nulls there is the map left out (removed). Read from the templates; the
# jobs are JOBS, the two scopes of hooks and cronjobs (GLOSSARY.md, *Root
# scope / workload scope*).
JOBS = [("hooks", "*", "*"), ("cronJobs", "*"), ("workloads", "*", "hooks", "*", "*"), ("workloads", "*", "cronJobs", "*")]
SURFACES = re.compile(r'isSetPassthrough" \(list \S+ "(\w+)"\)')


def surface_keys(chart):
    """The keys the templates read through isSetPassthrough."""
    return {k for t in (chart / "templates").rglob("*") if t.is_file() for k in SURFACES.findall(t.read_text())}


def surface_keys_self_test():
    assert SURFACES.findall('isSetPassthrough" (list $job "affinity")') == ["affinity"]


# The map values whose null is not their removal, each in a class
# CODING_STANDARDS.md (*A null means one thing per kind of node*) names: the
# class text must occur there, so rewording a class there rewords it here. "*" is one path segment (a key or a list index),
# "**" the rest of the path. A pattern no finding matches fails the sweep.
# Markdown emphasis is ignored in the comparison.
NUMBER = "Numbers are the exception"                # printScalar
REQUIRED = "a null in a required field"             # rejectNullItems
DATA = "ConfigMap and Secret data"                  # rejectNullDataValue
VERBATIM = "a null inside a structured value"       # renders as written: the one class that may render
REFERENCE = "a reference to an empty entry"         # an entry left out is outside the chart


class Row(NamedTuple):
    pattern: tuple
    cls: str


EXCEPTIONS = [
    Row(('workloads', '*', 'replicaCount'), NUMBER),
    Row(('workloads', '*', 'progressDeadlineSeconds'), NUMBER),
    Row(('workloads', '*', 'revisionHistoryLimit'), NUMBER),
    Row(('workloads', '*', 'updateStrategy', 'rollingUpdate', 'partition'), NUMBER),
    Row(('workloads', '*', 'keda', 'minReplicaCount'), NUMBER),
    Row(('workloads', '*', 'keda', 'maxReplicaCount'), NUMBER),
    Row(('workloads', '*', 'keda', 'cooldownPeriod'), NUMBER),
    Row(('workloads', '*', 'keda', 'pollingInterval'), NUMBER),
    Row(('cronJobs', '*', 'successfulJobsHistoryLimit'), NUMBER),
    Row(('cronJobs', '*', 'failedJobsHistoryLimit'), NUMBER),
    Row(('workloads', '*', 'cronJobs', '*', 'successfulJobsHistoryLimit'), NUMBER),
    Row(('workloads', '*', 'cronJobs', '*', 'failedJobsHistoryLimit'), NUMBER),
    Row(('workloads', '*', 'hooks', '*', '*', 'activeDeadlineSeconds'), NUMBER),
    Row(('workloads', '*', 'hooks', '*', '*', 'backoffLimit'), NUMBER),
    Row(('httpRoute', 'rules', '*', 'backendRefs', '*', 'weight'), NUMBER),
    Row(('httpRoutes', '*', 'rules', '*', 'backendRefs', '*', 'weight'), NUMBER),
    Row(('tcpRoutes', '*', 'rules', '*', 'backendRefs', '*', 'weight'), NUMBER),
    Row(('udpRoutes', '*', 'rules', '*', 'backendRefs', '*', 'weight'), NUMBER),
    Row(('externalSecrets', '*', 'data', '*', 'remote', 'version'), NUMBER),
    Row(('workloads', '*', 'volumeMounts', '*', 'name'), REQUIRED),
    Row(('workloads', '*', 'volumeMounts', '*', 'mountPath'), REQUIRED),
    Row(('workloads', '*', 'volumeClaimTemplates', '*', 'name'), REQUIRED),
    Row(('workloads', '*', 'volumeClaimTemplates', '*', 'size'), REQUIRED),
    Row(('workloads', '*', 'mountedConfigFiles', 'files', '*', 'name'), REQUIRED),
    Row(('workloads', '*', 'mountedConfigFiles', 'bundles', '*', 'files', '*', 'name'), REQUIRED),
    Row(('workloads', '*', 'dnsConfig', 'options', '*', 'name'), REQUIRED),
    Row(('workloads', '*', 'imagePullSecrets', '*', 'name'), REQUIRED),
    Row(('global', 'imagePullSecrets', '*', 'name'), REQUIRED),
    Row(('workloads', '*', 'externalSecrets', '*', 'name'), REQUIRED),
    Row(('workloads', '*', 'cronJobs', '*', 'externalSecrets', '*', 'name'), REQUIRED),
    Row(('hooks', '*', '*', 'externalSecrets', '*', 'name'), REQUIRED),
    Row(('rbacs', 'roles', '*', 'name'), REQUIRED),
    Row(('httpRoute', 'rules', '*', 'filters', '*', 'type'), REQUIRED),
    Row(('httpRoute', 'jwt', 'providers', '*', 'name'), REQUIRED),
    Row(('httpRoutes', '*', 'jwt', 'providers', '*', 'name'), REQUIRED),
    Row(('workloads', '*', 'configMap', '*'), DATA),
    Row(('workloads', '*', 'secret', '*'), DATA),
    Row(('workloads', '*', 'configMap', '*', '**'), VERBATIM),
    Row(('workloads', '*', 'secret', '*', '**'), VERBATIM),
    Row(('kedaTriggerAuthentications', '*'), REFERENCE),
]


def matches(pattern, path):
    """pattern, a tuple of keys, "*" and a trailing "**" (one segment or more), matches path."""
    if pattern and pattern[-1] == "**":
        return len(path) >= len(pattern) and matches(pattern[:-1], path[:len(pattern) - 1])
    return len(pattern) == len(path) and all(p in ("*", k) for p, k in zip(pattern, path))


def matches_self_test():
    assert matches(("workloads", "*", "replicaCount"), ("workloads", "app", "replicaCount"))
    assert not matches(("workloads", "*", "replicaCount"), ("workloads", "app", "keda", "replicaCount"))
    assert matches(("a", "*", "name"), ("a", 0, "name"))
    assert matches(("a", "**"), ("a", "b", "c")) and matches(("a", "**"), ("a", "b"))
    assert not matches(("a", "**"), ("a",)), "the map itself is not its content"
    assert not matches(("a", "**"), ("b", "c"))


def exception_for(path):
    return next((e for e in EXCEPTIONS if matches(e.pattern, path)), None)


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


def removed(values, path, surfaces=frozenset()):
    """values without the key at path. A map the removal empties stays, as
    `{}`, as the templates read it (dropNullsInPlace): in Kubernetes `{}` is not
    absent. One exception, the surface a template reads through
    isSetPassthrough (surfaces) on a job (JOBS): there a map of nulls is the
    map left out, so a cronjob's `nodeSelector: {zone: null}` inherits the
    workload's (issue #294)."""
    copy = json.loads(json.dumps(values))
    chain = [copy]
    for key in path[:-1]:
        chain.append(chain[-1][key])
    del chain[-1][path[-1]]
    if (len(path) > 2 and not chain[-1] and path[-2] in surfaces
            and any(matches(job, path[:-2]) for job in JOBS)):
        del chain[-2][path[-2]]
    return copy


def removed_self_test():
    assert removed({"a": {"b": None, "c": 1}}, ("a", "b")) == {"a": {"c": 1}}
    assert removed({"a": {"b": {"c": None}}}, ("a", "b", "c")) == {"a": {"b": {}}}
    job = {"cronJobs": {"c": {"nodeSelector": {"z": None}}}}
    assert removed(job, ("cronJobs", "c", "nodeSelector", "z"), {"nodeSelector"}) == {"cronJobs": {"c": {}}}
    workload = {"workloads": {"w": {"nodeSelector": {"z": None}}}}
    assert removed(workload, ("workloads", "w", "nodeSelector", "z"), {"nodeSelector"}) == {"workloads": {"w": {"nodeSelector": {}}}}
    assert removed({"l": [{"resources": {"k": None}}]}, ("l", 0, "resources", "k"), {"resources"}) == {"l": [{"resources": {}}]}


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
    unset: dict = None  # the scenario with the node removed, for a null map value


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


def unset_verdict(out, unset):
    """A null map value against the key removed: both fail, or both render the same."""
    if out.returncode and unset.returncode:
        return None
    if not out.returncode and not unset.returncode:
        a, b = stable_render(out.stdout), stable_render(unset.stdout)
        return None if a == b else "renders otherwise than with the key removed" + first_difference(a, b)
    err = " ".join((out if out.returncode else unset).stderr.split())[:200]
    return ("fails, and renders with the key removed: " if out.returncode else "renders, and fails with the key removed: ") + err


def excepted_verdict(out, base, path, cls):
    """A null on an EXCEPTIONS path: its class fails on null, but VERBATIM content renders."""
    if out.returncode == 0 and cls != VERBATIM:
        return f"renders, where {cls!r} fails on null"
    return verdict(out, base, path)


def stale_exceptions(exceptions, used, standards):
    """The EXCEPTIONS rows no finding needed, or whose class CODING_STANDARDS.md does not name."""
    standards = " ".join(standards.replace("*", "").split())
    return [f"EXCEPTIONS: {dotted(e.pattern)}: no null map value of a scenario needs it; drop it, or run every TEST_CASES scenario" for e in exceptions if e not in used] + \
        [f"EXCEPTIONS: {dotted(e.pattern)}: its class {e.cls!r} is not in CODING_STANDARDS.md" for e in exceptions if e.cls not in standards]


def verdict(out, base, path):
    if out.returncode == 0:
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


# verdict is bound here: check-null-preflight.py patches it while running main
def verdict_self_test(verdict=verdict):
    def run(code, out="", err=""):
        return subprocess.CompletedProcess([], code, out, err)
    failed = run(1, err="Error: execution error at (t:1:1): route.portName: resolves to a TCP port")
    assert unset_verdict(failed, run(1, err="Error: execution error at (t:1:1): other")) is None
    assert unset_verdict(failed, run(0, "x: 1\n")).startswith("fails, and renders with the key removed")
    assert unset_verdict(run(0, "x: 1\n"), failed).startswith("renders, and fails with the key removed")
    assert unset_verdict(run(0, "x: 1\n"), run(0, "x: 1\n")) is None
    assert unset_verdict(run(0, "x: 1\ny: null\n"), run(0, "x: 1\n")) == \
        "renders otherwise than with the key removed: renders y: null"
    assert verdict(failed, "", ("svc", "protocol")).startswith("fails without naming protocol")
    assert verdict(failed, "", ("route", "portName")) is None
    assert excepted_verdict(run(0, "replicas: null\n"), "", ("w", "replicaCount"), NUMBER).startswith("renders, where")
    assert excepted_verdict(run(0, "max: null\n"), "", ("w", "configMap", "p", "max"), VERBATIM) is None
    assert excepted_verdict(run(0, "FOO: null\n"), "", ("w", "configMap", "FOO"), DATA).startswith("renders, where")
    assert excepted_verdict(failed, "", ("route", "portName"), NUMBER) is None
    rows = [Row(("a", "*"), "a null in a required field"), Row(("b",), "no such class")]
    stale = stale_exceptions(rows, {rows[0]}, "x\na null in a **required\n  field**")
    assert stale == ["EXCEPTIONS: b: no null map value of a scenario needs it; drop it, or run every TEST_CASES scenario",
                     "EXCEPTIONS: b: its class 'no such class' is not in CODING_STANDARDS.md"], stale


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
        surfaces = surface_keys(chart)
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
                unset = removed(unset, p, surfaces)
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
    surface_keys_self_test()
    matches_self_test()
    defaulted_self_test()
    null_keys_self_test()
    verdict_self_test()
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
        removed_self_test()
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
    # after the preflight gate, which runs before anything that mutates values
    removed_self_test()
    findings = []
    with tempfile.TemporaryDirectory() as tmp:
        scratch = values_to_json_chart(tmp)
        jobs, bases = [], {}
        defaults = set(paths(to_json(chart / "values.yaml", scratch)))
        surfaces = surface_keys(chart)
        wrongs = []
        for f, values in scenarios:
            bases[f] = render(chart, flags, values, tmp).stdout
            jobs += [Case(f, p, None, nulled(values, p),
                          removed(values, p, surfaces) if not isinstance(p[-1], int) and not defaulted(p, defaults) else None)
                     for p in paths(values)]
            wrongs += [Case(f, p, wrong, set_at(values, p, wrong))
                       for p in paths(values) for wrong in wrong_types(value_at(values, p))]
        used = set()

        def null_job(c):
            out = render(chart, flags, c.values, tmp)
            if c.unset is None:
                return verdict(out, bases[c.file], c.path)
            as_removed = unset_verdict(out, render(chart, flags, c.unset, tmp))
            exception = exception_for(c.path)
            if as_removed is None:
                # both failing is equal; a render is still held to the null-looking lines
                return verdict(out, bases[c.file], c.path) if out.returncode == 0 else None
            if exception is None:
                return as_removed
            used.add(exception)
            return excepted_verdict(out, bases[c.file], c.path, exception.cls)

        def type_job(c):
            out = render(chart, flags, c.values, tmp)
            return type_verdict(out, c.path) if shape_at(shape, c.path) is not None else verdict(out, bases[c.file], c.path)

        with concurrent.futures.ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
            # map submits every job at once: both passes share the pool
            nulls, typed = pool.map(null_job, jobs), pool.map(type_job, wrongs)
            findings += [f"{c.file}: {dotted(c.path)} = {json.dumps(c.value)} → {v}"
                         for c, v in zip(jobs + wrongs, list(nulls) + list(typed)) if v]
    standards = pathlib.Path(__file__).parent.parent.parent / "CODING_STANDARDS.md"
    try:
        findings += stale_exceptions(EXCEPTIONS, used, standards.read_text())
    except OSError as e:
        findings.append(f"EXCEPTIONS: cannot read {standards.name}, which names each row's class: {e}")
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
