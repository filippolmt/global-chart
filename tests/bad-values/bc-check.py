#!/usr/bin/env python3
"""Every bad-values fixture that installed with the last release says so (a *BC break*).

A fixture is values the chart rejects now. Choosing 5.0.0 over 4.3.0 took a
check by hand: a volume whose only source was null (issue #300) installed with
4.2.1 as an empty directory and fails now. A Breaking entry alone does not tell
a change that breaks a working install from one that refuses what the API
server already rejected, and only the first takes a major.

Each tests/bad-values/ fixture is rendered with the chart at the last
release's tag (`<chart name>-<version>`, read through git), schema on, under
validate-bad-values' release name, and sent to a server-side dry run:

- it installed then: it carries `# BC break: <last release>`, and
  `make release` refuses a non-major (tests/check-release.py);
- it did not: a `# BC break: <last release>` line on it is stale, a FAIL.

A line naming an earlier release is history and is not checked. A break with
no fixture, a deploy flow such as `helm template | kubectl apply -n` (issue
#323), says `BC break` in its [Unreleased] entry instead.

The last release is the first dated section of CHANGELOG.md below the top one:
on a release PR that is the release before it, as for check-release.py.

Needs a cluster with the CRDs installed (make bc-check starts kind) and
KUBECONFIG pointing at it, and the release tags (git fetch --tags).

Usage: bc-check.py <chart dir> <CHANGELOG.md> <fixture>... [-- <helm flags>...]
"""
import concurrent.futures
import importlib.util
import os
import pathlib
import re
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


api_server = load("api_server", HERE / "api_server.py")
release = load("check_release", HERE.parent / "check-release.py")

MARKER = re.compile(r"^# BC break: (\S+)$", re.M)
RELEASE_NAME = "global-chart-bad-values"  # validate-bad-values': a name's length decides some fails


def old_chart(chart, version, tmp):
    """The chart directory at the tag of version, extracted under tmp; None and why when it cannot be read."""
    name = release.CHART_NAME.search((chart / "Chart.yaml").read_text())
    tag = f"{name.group(1) if name else chart.name}-{version}"
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=chart, capture_output=True, text=True)
    prefix = subprocess.run(["git", "rev-parse", "--show-prefix"], cwd=chart, capture_output=True, text=True)
    if top.returncode or prefix.returncode:
        return None, f"{chart} is not in a git clone"
    archive = subprocess.run(["git", "archive", "--format=tar", tag, prefix.stdout.strip()],
                             cwd=top.stdout.strip(), capture_output=True)
    if archive.returncode:
        return None, (f"git: cannot read {tag}, the last release ({archive.stderr.decode().strip()[:160]}): "
                      "fetch the tags (git fetch --tags; in CI, checkout with fetch-depth: 0)")
    subprocess.run(["tar", "-x", "-C", tmp], input=archive.stdout, check=True)
    return pathlib.Path(tmp) / prefix.stdout.strip(), None


def installed(chart, flags, fixture):
    """Whether the chart renders fixture, schema on, into objects the API server accepts."""
    out = subprocess.run(["helm", "template", RELEASE_NAME, str(chart), "--namespace", "default", *flags,
                          "-f", str(fixture)], capture_output=True, text=True)
    return out.returncode == 0 and bool(re.search(r"^kind: ", out.stdout, re.M)) \
        and api_server.dry_run(out.stdout) is None


def problems(fixture, last, was_installed):
    marked = last in MARKER.findall(fixture.read_text())
    if was_installed and not marked:
        return [f"{fixture}: installed with {last} and is rejected now: add `# BC break: {last}` and say it in "
                "its Breaking entry; the release takes a major"]
    if marked and not was_installed:
        return [f"{fixture}: `# BC break: {last}`, but it did not install with {last}: drop the line"]
    return []


def main(argv):
    argv, flags = api_server.split_args(argv)
    if len(argv) < 3:
        sys.exit(__doc__.rsplit("Usage: ", 1)[1])
    chart, changelog, fixtures = pathlib.Path(argv[0]), pathlib.Path(argv[1]), [pathlib.Path(f) for f in argv[2:]]
    missing = [str(p) for p in [chart / "Chart.yaml", changelog, *fixtures] if not p.is_file()]
    if missing:
        print(f"    FAIL: no such chart, CHANGELOG or fixture: {', '.join(missing)}")
        sys.exit(1)
    try:
        secs = release.sections(changelog.read_text())
    except release.Failure as e:
        print(f"    FAIL: {e}")
        sys.exit(1)
    if len(secs) < 2:
        print(f"    FAIL: {changelog}: no release below the top section to compare with")
        sys.exit(1)
    last = secs[1][0]
    api_server.require_api_server("bc-check")
    with tempfile.TemporaryDirectory() as tmp:
        old, why = old_chart(chart, last, tmp)
        if not old:
            print(f"    FAIL: {why}")
            sys.exit(1)
        with concurrent.futures.ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
            verdicts = list(pool.map(lambda f: installed(old, flags, f), fixtures))
    findings = [p for f, v in zip(fixtures, verdicts) for p in problems(f, last, v)]
    if findings:
        print(f"    FAIL: a fixture whose BC break against {last} is not stated as it is:")
        for line in sorted(findings):
            print(f"          - {line}")
        sys.exit(1)
    print(f"    OK: {len(fixtures)} fixtures against {last}: {sum(verdicts)} installed then, each marked `# BC break: {last}`")


if __name__ == "__main__":
    main(sys.argv[1:])
