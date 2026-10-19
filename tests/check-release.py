#!/usr/bin/env python3
"""Chart.yaml's version and the CHANGELOG's top section name the same release.

chart-releaser publishes whatever version Chart.yaml carries on a push to main
(CLAUDE.md, *Releases*), CHANGELOG or not. The check:

- the top section is `## [Unreleased]`: Chart.yaml carries the version of the
  first dated section below it, the last release;
- the top section is `## [x.y.z] — <yyyy-mm-dd>`, a release PR: Chart.yaml
  carries x.y.z, and x.y.z is above the section after it.

--bump x.y.z is the release PR's edit (make release VERSION=x.y.z): it renames
`[Unreleased]` to `[x.y.z] — <today>` and sets Chart.yaml's version. It refuses
a version not above the last release, and a non-major one when the section
carries `### Removed`: a key is removed only in a major (ADR 0022). 1.3.0
removed keys in a minor, before the policy, so the rule binds the bump only,
never the history.

Usage: check-release.py <CHANGELOG.md> <Chart.yaml>
       check-release.py --bump <x.y.z> <CHANGELOG.md> <Chart.yaml>
       check-release.py --self-test
"""
import datetime
import pathlib
import re
import sys

SECTION = re.compile(r"^## \[([^\]]+)\](?: — (\d{4}-\d{2}-\d{2}))?\s*$", re.M)
# [ \t], not \s: \s* before $ would take the newline and the blank line after it
CHART_VERSION = re.compile(r"^version:[ \t]*(\S+)[ \t]*$", re.M)
SEMVER = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


class Failure(Exception):
    pass


def semver(v, where):
    m = SEMVER.match(v)
    if not m:
        raise Failure(f"{where}: {v!r} is not a x.y.z version")
    return tuple(int(x) for x in m.groups())


def sections(changelog):
    """[(name, date, body)] in file order."""
    found = list(SECTION.finditer(changelog))
    if not found:
        raise Failure("CHANGELOG.md: no `## [<version>]` section")
    ends = [m.start() for m in found[1:]] + [len(changelog)]
    return [(m.group(1), m.group(2), changelog[m.end():e]) for m, e in zip(found, ends)]


def chart_version(chart):
    m = CHART_VERSION.search(chart)
    if not m:
        raise Failure("Chart.yaml: no `version:` line")
    return m.group(1)


def problems(changelog, chart):
    secs, version = sections(changelog), chart_version(chart)
    (top, date, _), rest = secs[0], secs[1:]
    if top == "Unreleased":
        last = next((name for name, d, _ in rest if d), None)
        if last is None:
            return ["CHANGELOG.md: no dated section under [Unreleased]"]
        return [] if version == last else [
            f"Chart.yaml: version {version}, but the last release in CHANGELOG.md is {last}; "
            f"a version bump is a release PR: make release VERSION={version}"]
    if not date:
        return [f"CHANGELOG.md: the top section [{top}] carries no `— <yyyy-mm-dd>` date"]
    out = [] if version == top else [f"Chart.yaml: version {version}, but CHANGELOG.md's top section is [{top}]"]
    if rest and semver(top, "CHANGELOG.md") <= semver(rest[0][0], "CHANGELOG.md"):
        out.append(f"CHANGELOG.md: [{top}] is not above the release before it, [{rest[0][0]}]")
    return out


def bump(changelog, chart, version, today):
    new = semver(version, "VERSION")
    secs = sections(changelog)
    top, _, body = secs[0]
    if top != "Unreleased":
        raise Failure(f"CHANGELOG.md: the top section is [{top}], not [Unreleased]: nothing to release")
    last = next((name for name, d, _ in secs[1:] if d), None)
    if last and new <= semver(last, "CHANGELOG.md"):
        raise Failure(f"VERSION: {version} is not above the last release, {last}")
    if last and re.search(r"^### Removed\s*$", body, re.M) and new[0] == semver(last, "CHANGELOG.md")[0]:
        raise Failure(f"VERSION: [Unreleased] carries `### Removed`, and a key is removed only in a major "
                      f"(ADR 0022): {version} keeps the major of {last}")
    changelog = changelog.replace("## [Unreleased]", f"## [{version}] — {today}", 1)
    chart = CHART_VERSION.sub(f"version: {version}", chart, count=1)
    return changelog, chart


def self_test():
    def log(*heads):
        return "# Changelog\n\n" + "".join(f"{h}\n\n### Added\n\n- x\n\n" for h in heads)
    chart = "name: c\nversion: 1.2.0\n\n# a comment\n"
    assert problems(log("## [Unreleased]", "## [1.2.0] — 2026-01-02"), chart) == []
    assert problems(log("## [Unreleased]", "## [1.1.0] — 2026-01-01"), chart), "a bump with no section"
    assert problems(log("## [1.2.0] — 2026-01-02", "## [1.1.0] — 2026-01-01"), chart) == []
    assert problems(log("## [1.3.0] — 2026-01-02", "## [1.2.0] — 2026-01-01"), chart), "a section with no bump"
    assert problems(log("## [1.2.0]", "## [1.1.0] — 2026-01-01"), chart), "no date"
    assert problems(log("## [1.2.0] — 2026-01-02", "## [1.2.0] — 2026-01-01"), chart), "not above"
    c, ch = bump(log("## [Unreleased]", "## [1.2.0] — 2026-01-01"), chart, "1.3.0", "2026-02-03")
    assert "## [1.3.0] — 2026-02-03" in c and problems(c, ch) == []
    assert ch == chart.replace("1.2.0", "1.3.0"), f"bump changed more than the version: {ch!r}"
    removed = "## [Unreleased]\n\n### Removed\n\n- k\n\n## [1.2.0] — 2026-01-01\n"
    for v, why in (("1.2.0", "not above"), ("1.3.0", "removed in a minor"), ("1.2", "not x.y.z")):
        try:
            bump(removed, chart, v, "2026-02-03")
        except Failure:
            continue
        raise AssertionError(f"bump {v} accepted: {why}")
    assert "## [2.0.0]" in bump(removed, chart, "2.0.0", "2026-02-03")[0]
    print("    OK: self-test")


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    if len(argv) == 4 and argv[0] == "--bump":
        version, paths = argv[1], [pathlib.Path(p) for p in argv[2:]]
        changelog, chart = bump(paths[0].read_text(), paths[1].read_text(), version,
                                datetime.date.today().isoformat())
        paths[0].write_text(changelog)
        paths[1].write_text(chart)
        print(f"    OK: [Unreleased] is [{version}], Chart.yaml version {version}")
        return
    if len(argv) != 2:
        sys.exit(__doc__.rsplit("Usage: ", 1)[1])
    found = problems(pathlib.Path(argv[0]).read_text(), pathlib.Path(argv[1]).read_text())
    if found:
        print("    FAIL: Chart.yaml and CHANGELOG.md name different releases:")
        for p in found:
            print(f"          - {p}")
        sys.exit(1)
    print(f"    OK: Chart.yaml and CHANGELOG.md agree on {chart_version(pathlib.Path(argv[1]).read_text())}")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except Failure as e:
        print(f"    FAIL: {e}")
        sys.exit(1)
    except OSError as e:
        print(f"    FAIL: cannot read CHANGELOG.md or Chart.yaml: {e}")
        sys.exit(1)
