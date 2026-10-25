#!/usr/bin/env python3
"""Chart.yaml's version and the CHANGELOG's top section name the same release.

chart-releaser publishes whatever version Chart.yaml carries on a push to main
(CLAUDE.md, *Releases*), CHANGELOG or not. The check:

- the top section is `## [Unreleased]`: Chart.yaml carries the version of the
  first dated section below it, the last release;
- the top section is `## [x.y.z] — <yyyy-mm-dd>`, a release PR: Chart.yaml
  carries x.y.z, and x.y.z is above the section after it.

A new template `fail` is Breaking (CODING_STANDARDS.md, the deprecation rule):
while the top section is `[Unreleased]`, templates that call `fail` more often
than at the last release's tag (`<chart name>-<version>`, chart-releaser's)
need a `- **Breaking: …**` entry there, and a Breaking entry needs its
`### Migration guide from <last release>` (CLAUDE.md, *Releases*). The fail
calls are counted with lint-templates.py's patterns, comments left out.
shortcut: the count is net, so a change that adds one fail and drops another
passes, as does a reworded message; compare the messages themselves if a
Breaking change ships unmarked that way.

Every `## [` heading is `## [x.y.z] — yyyy-mm-dd`, or `## [Unreleased]` on
top; one in any other form fails, rather than drop out of the release order.

--bump x.y.z is the release PR's edit (make release VERSION=x.y.z): it renames
`[Unreleased]` to `[x.y.z] — <today>` and sets Chart.yaml's version. It refuses
when the two files already disagree, when `[Unreleased]` holds no entry, a
version not above the last release, and a non-major one when the section
carries `### Removed`: a key is removed only in a major (ADR 0022).

shortcut: a pre-release (x.y.z-rc.1) is refused, as a VERSION and as a
heading: the chart has never published one; accept SemVer's pre-release form
in SEMVER and RELEASE, ordered below its release, the day one is wanted. 1.3.0
removed keys in a minor, before the policy, so the rule binds the bump only,
never the history.

Usage: check-release.py <CHANGELOG.md> <Chart.yaml>
       check-release.py --bump <x.y.z> <CHANGELOG.md> <Chart.yaml>
       check-release.py --self-test
"""
import datetime
import importlib.util
import os
import pathlib
import re
import subprocess
import sys

spec = importlib.util.spec_from_file_location("lint_templates", pathlib.Path(__file__).parent / "lint-templates.py")
lint_templates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lint_templates)

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


def fail_count(texts):
    """The fail calls of the template texts, comments left out."""
    texts = [lint_templates.blank_comments(t) for t in texts]
    return sum(len(lint_templates.FAIL.findall(t)) + len(lint_templates.FAIL_ANY.findall(t)) for t in texts)


def breaking_problems(changelog, then, now):
    """then/now: the fail counts at the last release and in the working tree."""
    secs = sections(changelog)
    if secs[0][0] != "Unreleased" or len(secs) < 2:
        return []
    body, last = secs[0][1], secs[1][0]
    breaking = re.search(r"^- \*\*Breaking\b", body, re.M)
    out = []
    if now > then and not breaking:
        out.append(f"CHANGELOG.md: the templates call fail {now - then} more time(s) than at {last}, and "
                   f"[Unreleased] has no `- **Breaking: …**` entry: a new fail is Breaking "
                   f"(CODING_STANDARDS.md, the deprecation rule)")
    if breaking and not re.search(rf"^### Migration guide from {re.escape(last)}[ \t]*$", body, re.M):
        out.append(f"CHANGELOG.md: [Unreleased] has a Breaking entry and no `### Migration guide from {last}`")
    return out


def release_templates(chart_file, version):
    """The template texts at the release tag of version, read through git."""
    name = re.search(r'^name:[ \t]*"?([^"\s#]+)', chart_file.read_text(), re.M)
    if not name:
        raise Failure("Chart.yaml: no `name:` line")
    tag, templates = f"{name.group(1)}-{version}", chart_file.parent / "templates"

    def git(*args):
        out = subprocess.run(["git", "-C", str(templates), *args], capture_output=True, text=True)
        if out.returncode:
            raise Failure(f"git: cannot read the tag {tag}, the last release ({out.stderr.strip()}): "
                          f"fetch the tags (git fetch --tags; in CI, checkout with fetch-depth: 0)")
        return out.stdout
    # run inside templates/: ls-tree lists paths relative to it, and <tag>:./<path> reads them
    return [git("show", f"{tag}:./{p}") for p in git("ls-tree", "-r", "--name-only", tag, ".").splitlines()]


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
    assert fails(bump, log(unreleased, r120), chart, "1.3.0-rc.1", "2026-02-03"), "a pre-release"
    breaking = f"{unreleased}\n\n### Changed\n\n- **Breaking: x** y\n\n### Migration guide from 1.2.0\n\n- z\n\n{r120}\n"
    assert breaking_problems(log(unreleased, r120), 2, 2) == []
    assert breaking_problems(log(unreleased, r120), 2, 3), "a new fail with no Breaking entry"
    assert breaking_problems(breaking, 2, 3) == []
    assert breaking_problems(breaking.replace("from 1.2.0", "from 1.1.0"), 2, 3), "a guide from another release"
    assert breaking_problems(log(r120, r110), 2, 3) == [], "a release PR is not checked"
    assert fail_count(['{{- fail "a: b" }}{{/* fail "c" */}}', '{{ fail (printf "%s: d" $x) }} {{ fail $m }}']) == 3
    print("    OK: self-test")


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    if len(argv) == 4 and argv[0] == "--bump":
        version, paths = argv[1], [pathlib.Path(p) for p in argv[2:]]
        changelog, chart = bump(paths[0].read_text(), paths[1].read_text(), version,
                                datetime.date.today().isoformat())
        # both written beside their target first, then renamed: a failed write leaves neither file half-bumped
        for path, text in zip(paths, (changelog, chart)):
            path.with_name(path.name + ".release-tmp").write_text(text)
        for path in paths:
            os.replace(path.with_name(path.name + ".release-tmp"), path)
        print(f"    OK: [Unreleased] is [{version}], Chart.yaml version {version}")
        return
    if len(argv) != 2:
        sys.exit(__doc__.rsplit("Usage: ", 1)[1])
    chart_file = pathlib.Path(argv[1])
    chart, changelog = chart_file.read_text(), pathlib.Path(argv[0]).read_text()
    mismatches = problems(changelog, chart)
    if mismatches:
        print("    FAIL: Chart.yaml and CHANGELOG.md name different releases:")
        for p in mismatches:
            print(f"          - {p}")
        sys.exit(1)
    secs = sections(changelog)
    if secs[0][0] == "Unreleased":
        now = fail_count(p.read_text() for p in sorted((chart_file.parent / "templates").rglob("*")) if p.is_file())
        unmarked = breaking_problems(changelog, fail_count(release_templates(chart_file, secs[1][0])), now)
        if unmarked:
            print("    FAIL: a Breaking change is not marked in [Unreleased]:")
            for p in unmarked:
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
        print(f"    FAIL: cannot read or write CHANGELOG.md or Chart.yaml: {e}")
        sys.exit(1)
