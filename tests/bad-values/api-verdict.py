#!/usr/bin/env python3
"""What the API server does with each schema/ fixture, recorded in the fixture (issue #287).

tests/bad-values/schema/ proves the schema rejects a fixture, not what the API
server would do with the rendered manifest. Each fixture is rendered with
--skip-schema-validation and sent to a server-side dry run with strict field
validation; its verdict must match the markers it carries:

- `# API accepts: <category>: <reason>`: the API server accepts the render (an
  empty render included), and the schema rejects it for a reason of its own.
  The category is one of CATEGORIES.
- `# API rejects: "<substring>"`, one line or more: the API server rejects the
  render, and every substring is in its error, so a fixture rejected for an
  unrelated reason does not pass.
- `# naming key: <schema pointer>`: the fixture sets a naming key (GLOSSARY.md),
  which rejects only what could never be applied: the API server must reject it,
  and an `# API accepts:` line on it is a FAIL.

A fixture with no verdict marker fails with the verdict the cluster gave, so the
markers are written from a run. A line that reads as a marker and matches none
(a trailing space, `API Accepts`, a substring without quotes) fails too, or it
would drop out of the check in silence. A fixture that does not render fails too: since
issue #336 validate-bad-values keeps every schema/ fixture renderable, and a
fixture skipped here would shrink the set the API server sees.

The check proves it can fail once per fixture: each verdict is also judged
against the opposite marker (an accepts line where the API rejects, a substring
no error carries where it accepts or rejects), and that judgement must be a FAIL.

Needs a cluster with the CRDs installed (make api-verdict starts kind) and
KUBECONFIG pointing at it.

Usage: api-verdict.py <chart dir> <fixture>... [-- <helm flags>...]
"""
import concurrent.futures
import importlib.util
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys

spec = importlib.util.spec_from_file_location("schema_navigation", pathlib.Path(__file__).parent / "schema_navigation.py")
navigation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(navigation)

CATEGORIES = {
    "dropped": "the key never reaches the manifest",
    "chart-rule": "the rule is the chart's own, not one the API server mirrors",
    "silent-misrender": "the value renders a valid but wrong manifest",
    "stricter": "the chart is deliberately stricter than the API server",
}
ACCEPTS = re.compile(r"^# API accepts: (.*)$", re.M)
REJECTS = re.compile(r'^# API rejects: "(.+)"$', re.M)
NAMING = re.compile(r"^# naming key: (\S+)$", re.M)
MARKER = re.compile(r"^#\s*(?:api\s+(?:accepts|rejects)|naming\s+key)\b.*$", re.M | re.I)  # every line that reads as a marker
ABSENT = "api-verdict self-test: a substring no error carries"


def render(chart, flags, fixture):
    # the release name is in some `# API rejects:` substrings (name-override-invalid.yaml)
    return subprocess.run(["helm", "template", "api-verdict", str(chart), "--skip-schema-validation", *flags,
                           "-f", str(fixture)], capture_output=True, text=True)


def dry_run(manifest):
    """None when the API server accepts manifest, else its error on one line."""
    out = subprocess.run(["kubectl", "apply", "--dry-run=server", "--validate=strict", "-n", "default", "-f", "-"],
                         input=manifest, capture_output=True, text=True)
    return None if out.returncode == 0 else " ".join(l.strip() for l in out.stderr.splitlines() if l.strip()) or "refused"


def markers(text):
    return ACCEPTS.findall(text), REJECTS.findall(text), NAMING.findall(text)


def judge(accepts, rejects, naming, error):
    """The problems of one fixture's markers against the API verdict (error None: accepted)."""
    if not accepts and not rejects:
        return [f"no verdict marker; the API server {'rejects it' if error else 'accepts it'}: add "
                + (f'`# API rejects: "<substring of: {error[:240]}>"`' if error else
                   "`# API accepts: <category>: <reason>`, the category one of: "
                   + "; ".join(f"{c} ({d})" for c, d in CATEGORIES.items()))]
    problems = []
    if accepts and rejects:
        problems.append("both `# API accepts:` and `# API rejects:` lines; keep the one the API server's verdict matches")
    if len(accepts) > 1:
        problems.append("more than one `# API accepts:` line")
    for line in accepts:
        category, _, reason = line.partition(": ")
        if category not in CATEGORIES or not reason.strip():
            problems.append(f"`# API accepts: {line}`: not `<category>: <reason>`, category one of {', '.join(CATEGORIES)}")
    if naming and accepts:
        problems.append("a naming key accepted by the API server: it rejects only what could never be applied "
                        "(GLOSSARY.md, *Naming key*), so either the schema or the marker is wrong")
    if accepts and error:
        problems.append(f"`# API accepts:`, but the API server rejects it: {error[:300]}")
    if rejects and not error:
        problems.append("`# API rejects:`, but the API server accepts it")
    if rejects and error:
        problems += [f'`# API rejects: "{s}"`: not in the error: {error[:300]}' for s in rejects if s not in error]
    return problems


def check(chart, flags, schema, fixture):
    """(problems, verdict) of one fixture; verdict "rejected" or the accepts category."""
    text = fixture.read_text()
    accepts, rejects, naming = markers(text)
    problems = [f"`{line}`: reads as a marker but is none of `# API accepts: <category>: <reason>`, "
                '`# API rejects: "<substring>"`, `# naming key: <pointer>`'
                for line in MARKER.findall(text) if not (ACCEPTS.match(line) or REJECTS.match(line) or NAMING.match(line))]
    for pointer in naming:
        try:
            navigation.resolve_pointer(schema, pointer)
        except (KeyError, IndexError, TypeError, ValueError):
            problems.append(f"`# naming key: {pointer}`: no such location in values.schema.json")
    out = render(chart, flags, fixture)
    if out.returncode != 0:
        return problems + ["does not render under --skip-schema-validation; a template fail rejects it, so it "
                           f"belongs in tests/bad-values/skip-schema/: {' '.join(out.stderr.split())[:240]}"], None
    error = dry_run(out.stdout) if re.search(r"^kind: ", out.stdout, re.M) else None
    problems += judge(accepts, rejects, naming, error)
    # the opposite marker must be a FAIL, or the verdict was never compared
    opposite = [(["dropped: self-test"], []), ([], [ABSENT])] if error else [([], [ABSENT])]
    if not all(judge(a, r, [], error) for a, r in opposite):
        problems.append("self-test: judged against the opposite marker, it passes; the verdict is not compared")
    return problems, "rejected" if error else (accepts[0].partition(":")[0] if accepts else "accepted")


def main(argv):
    flags = argv[argv.index("--") + 1:] if "--" in argv else []
    argv = argv[:argv.index("--")] if "--" in argv else argv
    chart, fixtures = pathlib.Path(argv[0]), [pathlib.Path(f) for f in argv[1:]]
    missing = [str(p) for p in [chart / "values.schema.json", *fixtures] if not p.is_file()]
    if missing or not fixtures:
        print(f"    FAIL: no such chart or fixture: {', '.join(missing) or 'no fixture given'}")
        sys.exit(1)
    if not shutil.which("helm"):
        print("    FAIL: helm: not found on PATH")
        sys.exit(1)
    try:
        ready = subprocess.run(["kubectl", "get", "--raw", "/readyz"], capture_output=True, text=True)
    except FileNotFoundError:
        ready = None
    if ready is None or ready.returncode != 0:
        print("    FAIL: kubectl: no API server reachable through KUBECONFIG; make api-verdict starts the kind cluster: "
              + (" ".join(ready.stderr.split())[:200] if ready else "kubectl not found"))
        sys.exit(1)
    schema = json.loads((chart / "values.schema.json").read_text())
    with concurrent.futures.ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
        results = list(pool.map(lambda f: check(chart, flags, schema, f), fixtures))
    findings = [f"{f}: {p}" for f, (problems, _) in zip(fixtures, results) for p in problems]
    verdicts = [v for _, v in results if v]
    if not findings and ("rejected" not in verdicts or len(set(verdicts)) < 2):
        findings.append("every fixture got the same verdict; the dry run may not reach the API server")
    if findings:
        print("    FAIL: a schema/ fixture whose API verdict does not match its markers:")
        for line in sorted(findings):
            print(f"          - {line}")
        sys.exit(1)
    counts = ", ".join(f"{verdicts.count(c)} {c}" for c in ["rejected", *CATEGORIES] if verdicts.count(c))
    print(f"    OK: {len(fixtures)} schema/ fixtures, each API verdict as its markers state: {counts}")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__.rsplit("Usage: ", 1)[1])
    main(sys.argv[1:])
