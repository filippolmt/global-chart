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
unless its output carries `<nil>`. A render that fails passes only when Helm
reports a template `fail` or `required` (`execution error at (…): <message>`)
whose message does not itself carry a raw template error. Anything else is a
finding: the template path and the error are printed.

The baseline. The findings the chart had when the sweep arrived (issue #198)
are listed, one `<scenario>: <path>` per line, in null-sweep-baseline.txt. A
finding outside it fails, and so does a line it holds that no longer
reproduces: the list is a ratchet, it only shrinks. Fix a null, delete its line.
`--write-baseline` rewrites the file from the current findings; use it only to
drop fixed lines, never to admit new ones.

Usage: null-sweep.py [--write-baseline] <chart dir> <values file>... [-- <helm flags>...]
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


def verdict(out):
    if out.returncode == 0:
        return "renders <nil>" if "<nil>" in out.stdout else None
    err = " ".join(out.stderr.split())
    m = FAIL.search(err)
    if m and not RAW.search(err[m.end():]):
        return None
    return err.replace("Use --debug flag to render out invalid YAML", "").strip()[:240]


BASELINE = pathlib.Path(__file__).resolve().parent / "null-sweep-baseline.txt"


def main(argv):
    write = "--write-baseline" in argv
    argv = [a for a in argv if a != "--write-baseline"]
    flags = argv[argv.index("--") + 1:] if "--" in argv else []
    argv = argv[:argv.index("--")] if "--" in argv else argv
    chart, files = pathlib.Path(argv[0]), argv[1:]
    findings = {}
    with tempfile.TemporaryDirectory() as tmp:
        scratch = pathlib.Path(tmp) / "values-to-json"
        (scratch / "templates").mkdir(parents=True)
        (scratch / "Chart.yaml").write_text("apiVersion: v2\nname: values-to-json\nversion: 0.0.0\n")
        (scratch / "templates" / "values.json").write_text("{{ .Values | toJson }}\n")
        jobs = []
        for f in files:
            values = to_json(f, scratch)
            jobs += [(f, p, nulled(values, p)) for p in paths(values)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
            results = pool.map(lambda j: (j[0], j[1], verdict(render(chart, flags, j[2], tmp))), jobs)
            for f, p, v in results:
                if v:
                    findings[f"{f}: {'.'.join(map(str, p))}"] = v
    if write:
        BASELINE.write_text("# Nulls that end in a raw template error today (issue #198). A ratchet:\n"
                            "# fix one, delete its line. Read by null-sweep.py, whose docstring has the rules.\n"
                            + "".join(f"{k}\n" for k in sorted(findings)))
        print(f"    wrote {len(findings)} findings to {BASELINE.name}")
        return
    known = {l for l in BASELINE.read_text().splitlines() if l and not l.startswith("#")} if BASELINE.exists() else set()
    new = sorted(findings.keys() - known)
    fixed = sorted(known - findings.keys())
    if new:
        print("    FAIL: a null under --skip-schema-validation does not fail naming its values path:")
        for k in new:
            print(f"          - {k} = null → {findings[k]}")
    if fixed:
        print(f"    FAIL: {BASELINE.name} lists nulls that now fail cleanly; delete their lines:")
        for k in fixed:
            print(f"          - {k}")
    if new or fixed:
        sys.exit(1)
    print(f"    OK: {len(jobs)} nulls across {len(files)} scenarios render or fail naming their path"
          f" ({len(known)} known in {BASELINE.name})")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__.rsplit("Usage: ", 1)[1])
    main(sys.argv[1:])
