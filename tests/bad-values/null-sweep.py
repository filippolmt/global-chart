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

RAW = re.compile(r"nil pointer|error calling|wrong type for value|can't evaluate|"
                 r"executing \"|invalid value; expected|incompatible types|error converting YAML")
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


def nulled(values, path):
    copy = json.loads(json.dumps(values))
    node = copy
    for key in path[:-1]:
        node = node[key]
    node[path[-1]] = None
    return copy


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
        for f in files:
            values = to_json(f, scratch)
            bases[f] = render(chart, flags, values, tmp).stdout
            jobs += [(f, p, nulled(values, p),
                      removed(values, p) if p[-1] in is_set and p not in defaults else None)
                     for p in paths(values)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
            results = pool.map(lambda j: (j[0], j[1], verdict(render(chart, flags, j[2], tmp), bases[j[0]], j[1],
                                                              render(chart, flags, j[3], tmp) if j[3] is not None else None)), jobs)
            for f, p, v in results:
                if v:
                    findings.append(f"{f}: {'.'.join(map(str, p))} = null → {v}")
    if findings:
        print("    FAIL: a null under --skip-schema-validation does not fail naming its values path:")
        for line in sorted(findings):
            print(f"          - {line}")
        sys.exit(1)
    print(f"    OK: {len(jobs)} nulls across {len(files)} scenarios render or fail naming their path")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__.rsplit("Usage: ", 1)[1])
    main(sys.argv[1:])
