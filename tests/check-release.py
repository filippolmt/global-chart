#!/usr/bin/env python3
"""Chart.yaml's version and the CHANGELOG's top section name the same release.

chart-releaser publishes whatever version Chart.yaml carries on a push to main
(CLAUDE.md, *Releases*), CHANGELOG or not. The check:

- the top section is `## [Unreleased]`: Chart.yaml carries the version of the
  first dated section below it, the last release;
- the top section is `## [x.y.z] — <yyyy-mm-dd>`, a release PR: Chart.yaml
  carries x.y.z, and x.y.z is above the section after it.

Every `## [` heading is `## [x.y.z] — yyyy-mm-dd`, or `## [Unreleased]` on
top; one in any other form fails, rather than drop out of the release order.

--bump x.y.z is the release PR's edit (make release VERSION=x.y.z): it renames
`[Unreleased]` to `[x.y.z] — <today>` and sets Chart.yaml's version. It refuses
when the two files already disagree, when `[Unreleased]` holds no entry, a
version not above the last release, and a non-major one when the section
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

HEADING = re.compile(r"^## \[.*$", re.M)
RELEASE = re.compile(r"^## \[(\d+\.\d+\.\d+)\] — (\d{4}-\d{2}-\d{2})$")
UNRELEASED = "## [Unreleased]"
# [ \t], not \s: \s* before $ would take the newline and the blank line after it
CHART_VERSION = re.compile(r'^version:[ \t]*"?([^"\s#]+)"?[ \t]*(?:#.*)?$', re.M)
SEMVER = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


class Failure(Exception):
    pass


def semver(v, where):
    m = SEMVER.match(v)
    if not m:
        raise Failure(f"{where}: {v!r} is not a x.y.z version")
    return tuple(int(x) for x in m.groups())


def sections(changelog):
    """[(name, body, heading match)] in file order. Every `## [` heading is
    `## [x.y.z] — yyyy-mm-dd`, or `## [Unreleased]` on top: a heading in any
    other form (a hyphen for the em dash, no date) would drop out of the
    release order unseen, so it fails."""
    found = list(HEADING.finditer(changelog))
    if not found:
        raise Failure("CHANGELOG.md: no `## [<version>]` section")
    out = []
    for i, m in enumerate(found):
        line = m.group(0).rstrip()
        rel = RELEASE.match(line)
        if not rel and not (i == 0 and line == UNRELEASED):
            raise Failure(f"CHANGELOG.md:{changelog.count(chr(10), 0, m.start()) + 1}: {line!r} is neither "
                          f"`## [x.y.z] — yyyy-mm-dd` nor a top `{UNRELEASED}`")
        end = found[i + 1].start() if i + 1 < len(found) else len(changelog)
        out.append((rel.group(1) if rel else "Unreleased", changelog[m.end():end], m))
    return out


def chart_version(chart):
    m = CHART_VERSION.search(chart)
    if not m:
        raise Failure("Chart.yaml: no `version:` line")
    return m


def problems(changelog, chart):
    secs, version = sections(changelog), chart_version(chart).group(1)
    top, rest = secs[0][0], secs[1:]
    if top == "Unreleased":
        if not rest:
            return ["CHANGELOG.md: no release under [Unreleased]"]
        return [] if version == rest[0][0] else [
            f"Chart.yaml: version {version}, but the last release in CHANGELOG.md is {rest[0][0]}; "
            f"a version bump is a release PR: make release VERSION={version}"]
    out = [] if version == top else [f"Chart.yaml: version {version}, but CHANGELOG.md's top section is [{top}]"]
    if rest and semver(top, "CHANGELOG.md") <= semver(rest[0][0], "CHANGELOG.md"):
        out.append(f"CHANGELOG.md: [{top}] is not above the release before it, [{rest[0][0]}]")
    return out


def bump(changelog, chart, version, today):
    new = semver(version, "VERSION")
    drift = problems(changelog, chart)
    if drift:
        raise Failure(f"Chart.yaml and CHANGELOG.md disagree before the bump: {drift[0]}")
    secs = sections(changelog)
    (top, body, heading), last = secs[0], secs[1][0]
    if top != "Unreleased":
        raise Failure(f"CHANGELOG.md: the top section is [{top}], not [Unreleased]: nothing to release")
    if not re.search(r"^- ", body, re.M):
        raise Failure("CHANGELOG.md: [Unreleased] holds no entry: nothing to release")
    if new <= semver(last, "CHANGELOG.md"):
        raise Failure(f"VERSION: {version} is not above the last release, {last}")
    if re.search(r"^### Removed\b", body, re.M) and new[0] == semver(last, "CHANGELOG.md")[0]:
        raise Failure(f"VERSION: [Unreleased] carries `### Removed`, and a key is removed only in a major "
                      f"(ADR 0022): {version} keeps the major of {last}")
    changelog = f"{changelog[:heading.start()]}## [{version}] — {today}{changelog[heading.end():]}"
    v = chart_version(chart)
    chart = f"{chart[:v.start(1)]}{version}{chart[v.end(1):]}"
    return changelog, chart


def self_test():
    def log(*heads):
        return "# Changelog\n\n" + "".join(f"{h}\n\n### Added\n\n- x\n\n" for h in heads)

    def fails(fn, *args):
        try:
            fn(*args)
        except Failure:
            return True
        return False
    chart = "name: c\nversion: 1.2.0\n\n# a comment\n"
    unreleased, r120, r110 = "## [Unreleased]", "## [1.2.0] — 2026-01-02", "## [1.1.0] — 2026-01-01"
    assert problems(log(unreleased, r120, r110), chart) == []
    assert problems(log(unreleased, r110), chart), "a bump with no section"
    assert problems(log(r120, r110), chart) == []
    assert problems(log("## [1.3.0] — 2026-01-03", r120), chart), "a section with no bump"
    assert problems(log("## [1.2.0] — 2026-01-03", r120), chart), "not above"
    assert problems(log(unreleased, r120), 'version: "1.2.0" # pinned\n') == [], "a quoted version"
    for heads, why in (((unreleased, "## [1.2.0]"), "no date"), ((unreleased, "## [1.2.0] - 2026-01-02"), "a hyphen"),
                       ((r120, unreleased, r110), "[Unreleased] not on top")):
        assert fails(problems, log(*heads), chart), f"accepted: {why}"
    c, ch = bump(log(unreleased, r120), chart, "1.3.0", "2026-02-03")
    assert c.startswith("# Changelog\n\n## [1.3.0] — 2026-02-03\n") and problems(c, ch) == []
    assert ch == chart.replace("1.2.0", "1.3.0"), f"bump changed more than the version: {ch!r}"
    assert fails(bump, c, ch, "1.4.0", "2026-02-04"), "bumped twice"
    removed = f"{unreleased}\n\n### Removed (breaking)\n\n- k\n\n{r120}\n"
    for v, why in (("1.2.0", "not above"), ("1.3.0", "removed in a minor"), ("1.2", "not x.y.z")):
        assert fails(bump, removed, chart, v, "2026-02-03"), f"bump {v} accepted: {why}"
    assert "## [2.0.0]" in bump(removed, chart, "2.0.0", "2026-02-03")[0]
    assert fails(bump, f"{unreleased}\n\n{r120}\n", chart, "1.3.0", "2026-02-03"), "an empty [Unreleased]"
    assert fails(bump, log(unreleased, r120), "version: 1.1.0\n", "1.3.0", "2026-02-03"), "a drift"
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
    chart = pathlib.Path(argv[1]).read_text()
    mismatches = problems(pathlib.Path(argv[0]).read_text(), chart)
    if mismatches:
        print("    FAIL: Chart.yaml and CHANGELOG.md name different releases:")
        for p in mismatches:
            print(f"          - {p}")
        sys.exit(1)
    print(f"    OK: Chart.yaml and CHANGELOG.md agree on {chart_version(chart).group(1)}")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except Failure as e:
        print(f"    FAIL: {e}")
        sys.exit(1)
    except OSError as e:
        print(f"    FAIL: cannot read CHANGELOG.md or Chart.yaml: {e}")
        sys.exit(1)
