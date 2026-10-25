#!/usr/bin/env python3
"""Every bound value the schema accepts, the API server accepts too.

The schema can be looser than the API server on a field it mirrors from a core
kind or a CRD, and nothing else catches it: `pdb.minAvailable` accepted any
`"<digits>%"`, `"150%"` rendered, and the API server refused it at apply
(issue #226, found in the review of #225). The scenarios carry ordinary values,
so make e2e-dryrun never sends a bound.

The sweep runs from the API side. A bound value has no "extreme the schema
accepts" for a pattern (`^[0-9]+%$` has none), so each bounded node gets
candidates the API server is likely to refuse, and every one the schema accepts
must pass the server-side dry run:
- an integer node: its minimum and maximum, plus 2^31-1 and 2^31 when no
  maximum is declared (most such fields are int32 on the API side);
- a string node with a pattern or a maxLength: the candidates CANDIDATES lists
  for that schema location. Every pattern and maxLength of the schema has an
  entry, None for a bound the API server does not mirror (an image reference,
  a naming key the chart builds a name from): a new pattern comes with its
  candidates or with the reason it has none.

Each lint scenario is read back as JSON, as null-sweep does. Every scalar node a
scenario sets is given each candidate of its schema node in turn, and rendered
with the schema on: a candidate the schema or a template refuses is dropped.
What renders is diffed against the scenario's own render, and only the documents
that changed go to `kubectl apply --dry-run=server`. A refusal is a finding. A
bounded node no scenario sets is never swept: check-scenario-coverage.py reports
it, reading bounded() from here.
A bound a template `fail` shadows in every scenario is never swept either:
pdb.minAvailable at 2^31 always failed validatePdbEvictions first, and its
missing int32 maximum went unseen (PR #254). Such a bound is checked by
reading the schema, not by the sweep.

The self-test. Before the sweep, the PDB percentage pattern is put back to its
pre-#225 form `^[0-9]+%$` in a scratch copy of the chart, and the sweep of the
PDB nodes must find "150%". It fails otherwise: the sweep has gone blind (no
scenario sets a PDB bound, or the dry run no longer runs).

Needs a cluster with the CRDs installed (make bound-sweep starts kind) and
KUBECONFIG pointing at it.

Usage: bound-sweep.py <chart dir> <values file>... [-- <helm flags>...]
"""
import concurrent.futures
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location("null_sweep", pathlib.Path(__file__).parent / "null-sweep.py")
sweep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep)
spec = importlib.util.spec_from_file_location("schema_navigation", pathlib.Path(__file__).parent / "schema_navigation.py")
navigation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(navigation)

INT32_MAX = 2**31 - 1
IMAGE = None  # the API server does not parse an image reference: the kubelet does, at pull
NAMING_KEY = None  # a map key the chart builds names from: never a value the sweep sets
PERCENT = ["0%", "100%", "101%", "150%"]
SUBDOMAIN_253 = ".".join(["a" * 63, "b" * 63, "c" * 63, "d" * 61])

# Candidates per schema location (a JSON pointer) carrying a pattern or a maxLength
CANDIDATES = {
    "/$defs/httpRouteBasicAuth/properties/username": None,  # htpasswd input, not an API server constraint
    "/$defs/global/properties/imageRegistry": IMAGE,
    "/$defs/image/oneOf/1": IMAGE,
    "/$defs/imageMap/properties/repository": IMAGE,
    "/$defs/imageMap/properties/tag": IMAGE,
    "/$defs/imageMap/properties/digest": IMAGE,
    "/$defs/imageMap/if/properties/tag": None,  # the condition of if/then, not a bound
    "/$defs/imageMap/then/properties/digest": None,
    "/$defs/hpaTargetPercent": [str(INT32_MAX), str(INT32_MAX + 1)],
    "/$defs/pdb/properties/minAvailable/oneOf/1": PERCENT,
    "/$defs/pdb/properties/maxUnavailable/oneOf/1": PERCENT,
    # "0", "1e3", "true", "on": names YAML reads as a number or a boolean, unless the template quotes them (issue #251)
    "/$defs/dns1123Label": ["0", "1e3", "true", "0a", "a-0"],
    "/$defs/dns1123Subdomain": ["0", "1e3", "true", "0a", "a.b-0", SUBDOMAIN_253],
    "/$defs/ianaSvcName": ["on", "a" * 15],
    "/$defs/ianaSvcName/allOf/0": ["0a", "a-0"],
    "/$defs/ianaSvcName/allOf/1": None,  # "has a letter": a narrowing, nothing to push
    "/$defs/volumeClaimTemplate/properties/size": ["1", "0.5", "1.5Gi", "999999Ei"],
    "/$defs/volumeClaimTemplate/properties/name": ["a" * 63],
    "/$defs/hookJobSpec/properties/weight": None,  # an annotation Helm reads, not the API server
    "/$defs/serviceAccount/properties/name/anyOf/1": [SUBDOMAIN_253],
    "/$defs/optionalObjectName/anyOf/2": [SUBDOMAIN_253],
    "/$defs/l4RouteRule/properties/name": [SUBDOMAIN_253],
    "/$defs/rbacs/properties/roles/items/properties/name": [SUBDOMAIN_253],
    "/$defs/mountedConfigFileName": None,  # the chart's own bound, tighter than the API's
    "/$defs/deploymentName": NAMING_KEY,
    "/$defs/jobName": NAMING_KEY,
    "/properties/httpRoutes/propertyNames": NAMING_KEY,
    "/properties/tcpRoutes/propertyNames": NAMING_KEY,
    "/properties/udpRoutes/propertyNames": NAMING_KEY,
}
PDB_PATTERNS = ["/$defs/pdb/properties/minAvailable/oneOf/1", "/$defs/pdb/properties/maxUnavailable/oneOf/1"]


def candidates(nodes):
    """Ordered values to try from terminal sources; bounds stay local to each source."""
    out = []
    for p, n in nodes:
        types = n.get("type", [])
        types = [types] if isinstance(types, str) else types
        if "integer" in types:
            out += [n[k] for k in ("minimum", "maximum") if k in n]
            out += [] if "maximum" in n else [INT32_MAX, INT32_MAX + 1]
        if "pattern" in n or "maxLength" in n:
            out += CANDIDATES.get(p) or []
    return list(dict.fromkeys(out))


def bounded(nodes):
    return bool(candidates(nodes))


def table_findings(schema):
    """Every pattern or maxLength of the schema with no CANDIDATES entry, and every entry with no bound."""
    found = set()

    def walk(node, pointer):
        if isinstance(node, dict):
            if "pattern" in node or "maxLength" in node:
                found.add(pointer)
            for k, v in node.items():
                walk(v, f"{pointer}/{k}")
        elif isinstance(node, list):
            for i, v in enumerate(node):
                walk(v, f"{pointer}/{i}")
    walk(schema, "")
    return [f"{p}: a pattern or maxLength with no CANDIDATES entry; list the values the API server "
            "may refuse there, or None with the reason it mirrors no API bound" for p in sorted(found - set(CANDIDATES))] + \
           [f"{p}: a CANDIDATES entry where the schema has no pattern or maxLength; delete it"
            for p in sorted(set(CANDIDATES) - found)]


def render(chart, flags, values, tmp):
    fd, name = tempfile.mkstemp(suffix=".json", dir=tmp)
    with os.fdopen(fd, "w") as f:
        json.dump(values, f)
    out = subprocess.run(["helm", "template", "bound-sweep", str(chart), *flags, "-f", name],
                         capture_output=True, text=True)
    os.unlink(name)
    return out


def documents(manifest):
    return {d.strip() for d in sweep.TIMESTAMP.sub("", manifest).split("\n---") if "\nkind: " in "\n" + d}


def dry_run(docs):
    out = subprocess.run(["kubectl", "apply", "--dry-run=server", "-n", "default", "-f", "-"],
                         input="\n---\n".join(docs), capture_output=True, text=True)
    return None if out.returncode == 0 else \
        " ".join(l for l in out.stderr.splitlines() if l.strip())[:300] or "refused"


def run(chart, files, flags, tmp, only=None):
    """(findings, cases sent) for every bounded scalar node the scenarios set; only: the schema pointers to sweep."""
    schema = json.loads((chart / "values.schema.json").read_text())
    scratch = pathlib.Path(tmp) / "values-to-json"
    if not scratch.exists():
        (scratch / "templates").mkdir(parents=True)
        (scratch / "Chart.yaml").write_text("apiVersion: v2\nname: values-to-json\nversion: 0.0.0\n")
        (scratch / "templates" / "values.json").write_text("{{ .Values | toJson }}\n")
    cases, bases = [], {}
    for f in files:
        values = sweep.to_json(f, scratch)
        base = render(chart, flags, values, tmp)
        if base.returncode != 0:
            return [f"{f}: the scenario itself does not render: {' '.join(base.stderr.split())[:240]}"], 0
        bases[f] = documents(base.stdout)
        for path in sweep.paths(values):
            current = sweep.value_at(values, path)
            if isinstance(current, (dict, list, bool)) or current is None:
                continue
            nodes = navigation.sources(schema, path)
            if only and not any(p in only for p, _ in nodes):
                continue
            cases += [(f, path, c, sweep.set_at(values, path, c)) for c in candidates(nodes) if c != current]

    def job(case):
        f, path, value, values = case
        out = render(chart, flags, values, tmp)
        changed = documents(out.stdout) - bases[f] if out.returncode == 0 else set()
        return dry_run(changed) if changed else None, bool(changed)

    with concurrent.futures.ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
        results = list(pool.map(job, cases))
    findings = [f"{f}: {sweep.dotted(path)} = {json.dumps(value)} → {v}"
                for (f, path, value, _), (v, _) in zip(cases, results) if v]
    return findings, sum(sent for _, sent in results)


def self_test(chart, files, flags, tmp):
    """None when the sweep finds "150%" under the pre-#225 PDB pattern, else why not."""
    copy = pathlib.Path(tmp) / "pre-225" / chart.name
    shutil.copytree(chart, copy)
    schema = json.loads((copy / "values.schema.json").read_text())
    for pointer in PDB_PATTERNS:
        navigation.resolve_pointer(schema, pointer)["pattern"] = "^[0-9]+%$"
    (copy / "values.schema.json").write_text(json.dumps(schema))
    findings, sent = run(copy, files, flags, tmp, only=set(PDB_PATTERNS))
    if any('= "150%"' in f for f in findings):
        return None
    return (f"under the pre-#225 PDB pattern ^[0-9]+%$ the sweep sent {sent} case(s) and found no \"150%\": "
            "no scenario sets a PDB bound, or the dry run does not reach the API server")


def main(argv):
    flags = argv[argv.index("--") + 1:] if "--" in argv else []
    argv = argv[:argv.index("--")] if "--" in argv else argv
    chart, files = pathlib.Path(argv[0]), argv[1:]
    missing = [str(p) for p in [chart / "values.schema.json", *map(pathlib.Path, files)] if not p.is_file()]
    if missing:
        print(f"    FAIL: no such chart or scenario: {', '.join(missing)}")
        sys.exit(1)
    try:
        ready = subprocess.run(["kubectl", "get", "--raw", "/readyz"], capture_output=True, text=True)
    except FileNotFoundError:
        ready = None
    if ready is None or ready.returncode != 0:
        print("    FAIL: kubectl: no API server reachable through KUBECONFIG; make bound-sweep starts the kind cluster: "
              + (" ".join(ready.stderr.split())[:200] if ready else "kubectl not found"))
        sys.exit(1)
    findings = table_findings(json.loads((chart / "values.schema.json").read_text()))
    with tempfile.TemporaryDirectory() as tmp:
        if not findings:
            blind = self_test(chart, files, flags, tmp)
            findings += [f"self-test: {blind}"] if blind else []
        if not findings:
            found, sent = run(chart, files, flags, tmp)
            findings += found
    if findings:
        print("    FAIL: a bound the schema accepts and the API server refuses (or the sweep cannot run):")
        for line in sorted(findings):
            print(f"          - {line}")
        sys.exit(1)
    print(f"    OK: {sent} bound values across {len(files)} scenarios accepted by the schema and the API server")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__.rsplit("Usage: ", 1)[1])
    main(sys.argv[1:])
