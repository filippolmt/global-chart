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
calls are read with lint-templates.py's patterns, comments left out, and the
FAIL lists the messages that are not at the tag. Right after a release PR
merges, the tag lands when CI's release job finishes.
shortcut: the trigger is the net count, and any Breaking entry satisfies it, so
a change that adds one fail and drops another passes, as does a new fail beside
an unrelated Breaking entry; tie each new message to an entry if a Breaking
change ships unmarked that way.

A change is logged (CLAUDE.md, *Releases*): when the diff from the merge-base
with <base> (working tree and untracked files included) touches charts/ or
tests/, the
[Unreleased] section differs from the merge-base's. A dependency bump touches
only the Makefile or a workflow, and a release PR renames [Unreleased], so
neither needs an exemption. On a push to main the merge-base is HEAD itself and
the diff is empty.

Every `## [` heading is `## [x.y.z] — yyyy-mm-dd`, or `## [Unreleased]` on
top; one in any other form fails, rather than drop out of the release order.

--bump x.y.z is the release PR's edit (make release VERSION=x.y.z): it renames
`[Unreleased]` to `[x.y.z] — <today>` and sets Chart.yaml's version. It refuses
when the two files already disagree, when `[Unreleased]` holds no entry, a
version not above the last release, and a non-major one when the section
carries `### Removed`: a key is removed only in a major (ADR 0022). It refuses
a non-major too over a *BC break*: values or a deploy flow that installed with
the last release and fail now, stated by `BC break` in `[Unreleased]` or by a
`# BC break: <last release>` line in a tests/bad-values/ fixture (make bc-check
holds the fixtures to the cluster). And it refuses a major while
values.schema.json still declares a key `removed in <an earlier major>`:
phase 3 of the removal rule undeclares it then (ADR 0022; #236 found 5.0.0
about to ship the 4.0.0 declarations).

shortcut: a pre-release (x.y.z-rc.1) is refused, as a VERSION and as a
heading: the chart has never published one; accept SemVer's pre-release form
in SEMVER and RELEASE, ordered below its release, the day one is wanted. 1.3.0
removed keys in a minor, before the policy, so the rule binds the bump only,
never the history.

Usage: check-release.py <CHANGELOG.md> <Chart.yaml> <base ref>
       check-release.py --bump <x.y.z> <CHANGELOG.md> <Chart.yaml>
       check-release.py --self-test
"""
import collections
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
CHART_NAME = re.compile(r'^name:[ \t]*"?([^"\s#]+)', re.M)
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


def fail_calls(texts):
    """The fail calls of the template texts, comments left out: a printf or
    literal message by its text, any other argument as written."""
    out = []
    for text in texts:
        text = lint_templates.blank_comments(text)
        out += [m.group(2) for m in lint_templates.FAIL.finditer(text)]
        out += [m.group(1) for m in lint_templates.FAIL_ANY.finditer(text)]
    return out


def breaking_problems(changelog, fails_at_release, fails_now):
    secs = sections(changelog)
    if secs[0][0] != "Unreleased" or len(secs) < 2:
        return []
    body, last = secs[0][1], secs[1][0]
    breaking = re.search(r"^- \*\*Breaking\b", body, re.M)
    out = []
    if len(fails_now) > len(fails_at_release) and not breaking:
        new = collections.Counter(fails_now) - collections.Counter(fails_at_release)
        out.append(f"CHANGELOG.md: the templates call fail {len(fails_now) - len(fails_at_release)} more "
                   f"time(s) than at {last}, and [Unreleased] has no `- **Breaking: …**` entry: a new fail is "
                   f"Breaking (CODING_STANDARDS.md, the deprecation rule). Not at {last}: "
                   + "; ".join(f'"{m[:100]}"' for m in new.elements()))
    if breaking and not re.search(rf"^### Migration guide from {re.escape(last)}[ \t]*$", body, re.M):
        out.append(f"CHANGELOG.md: [Unreleased] has a Breaking entry and no `### Migration guide from {last}`")
    return out


LOGGED = ("charts/", "tests/")


def git(cwd, *args, hint):
    """git's stdout in cwd; a failure is a Failure built by hint(stderr)."""
    out = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True)
    if out.returncode:
        raise Failure(hint(out.stderr.strip()))
    return out.stdout


def unreleased_body(changelog):
    """The [Unreleased] section's body, "" when the top section is a release."""
    secs = sections(changelog)
    return secs[0][1] if secs[0][0] == "Unreleased" else ""


def unlogged_problems(changed, before, now):
    """changed: the paths the diff touches; before/now: the CHANGELOG at the merge-base and now."""
    touched = [p for p in changed if p.startswith(LOGGED)]
    if not touched or unreleased_body(before) != unreleased_body(now):
        return []
    return [f"CHANGELOG.md: the change touches {', '.join(touched[:3])}{' …' if len(touched) > 3 else ''}, "
            "and [Unreleased] is the same as at the merge-base: add its entry (CLAUDE.md, *Releases*)"]


def unlogged_change(changelog_file, base):
    """unlogged_problems against the merge-base of base and HEAD, read through git."""
    root = changelog_file.resolve().parent

    def run(*args):
        return git(root, *args, hint=lambda err: f"git {' '.join(args)}: {err} "
                   f"(fetch {base}; in CI, checkout with fetch-depth: 0)")
    merge_base = run("merge-base", base, "HEAD").strip()
    changed = run("diff", "--name-only", merge_base).splitlines() + \
        run("ls-files", "--others", "--exclude-standard").splitlines()
    return unlogged_problems(changed, run("show", f"{merge_base}:{changelog_file.name}"), changelog_file.read_text())


def release_templates(chart_file, version):
    """The template texts at the release tag of version, read through git."""
    name = CHART_NAME.search(chart_file.read_text())
    if not name:
        raise Failure("Chart.yaml: no `name:` line")
    tag, templates = f"{name.group(1)}-{version}", chart_file.parent / "templates"

    def hint(err):
        missing = "Not a valid object name" in err or "unknown revision" in err
        fix = ("fetch the tags (git fetch --tags; in CI, checkout with fetch-depth: 0)" if missing
               else f"{templates} must be in a git clone")
        return f"git: cannot read the templates at {tag}, the last release ({err}): {fix}"
    # run inside templates/: ls-tree lists paths relative to it, and <tag>:./<path> reads them
    return [git(templates, "show", f"{tag}:./{p}", hint=hint)
            for p in git(templates, "ls-tree", "-r", "--name-only", tag, ".", hint=hint).splitlines()]


def unmarked_breaking(changelog, chart_file):
    """breaking_problems against the last release's tag; nothing to check on a release PR."""
    secs = sections(changelog)
    if secs[0][0] != "Unreleased" or len(secs) < 2:
        return []
    now = [p.read_text() for p in sorted((chart_file.parent / "templates").rglob("*")) if p.is_file()]
    return breaking_problems(changelog, fail_calls(release_templates(chart_file, secs[1][0])), fail_calls(now))


BC_BREAK = re.compile(r"^# BC break: (\S+)$", re.M)
REMOVED_IN = re.compile(r"removed in (\d+)\.0\.0")


def bump(changelog, chart, version, today, schema="", fixtures=()):
    """fixtures: (path, text) of the tests/bad-values/ files; schema: values.schema.json's text."""
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
    same_major = new[0] == semver(last, "CHANGELOG.md")[0]
    if re.search(r"^### Removed\b", body, re.M) and same_major:
        raise Failure(f"VERSION: [Unreleased] carries `### Removed`, and a key is removed only in a major "
                      f"(ADR 0022): {version} keeps the major of {last}")
    breaks = (["[Unreleased] says `BC break`"] if "BC break" in body else []) + \
        [str(path) for path, text in fixtures if last in BC_BREAK.findall(text)]
    if breaks and same_major:
        raise Failure(f"VERSION: a BC break, values that installed with {last} and fail now, takes a major: "
                      f"{version} keeps the major of {last} ({', '.join(breaks)})")
    stale = sorted({int(m) for m in REMOVED_IN.findall(schema) if int(m) < new[0]})
    if stale:
        raise Failure(f"values.schema.json: still declares keys removed in "
                      f"{', '.join(f'{m}.0.0' for m in stale)}; at {version} they go with their fail and "
                      "fixtures (ADR 0022, phase 3 of the removal rule)")
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
    declared = '{"k": {"description": "removed in 1.0.0, issue #1: use j."}}'
    assert fails(bump, log(unreleased, r120), chart, "2.0.0", "2026-02-03", declared), "a major keeping old removed keys"
    assert bump(log(unreleased, r120), chart, "1.3.0", "2026-02-03", declared), "a minor keeps them, as it should"
    bc = [(pathlib.Path("f.yaml"), "# BC break: 1.2.0\nk: v\n")]
    assert fails(bump, log(unreleased, r120), chart, "1.3.0", "2026-02-03", "", bc), "a fixture BC break in a minor"
    assert bump(log(unreleased, r120), chart, "2.0.0", "2026-02-03", "", bc), "a fixture BC break in a major"
    assert bump(log(unreleased, r120), chart, "1.3.0", "2026-02-03", "", [(bc[0][0], "# BC break: 1.1.0\n")]), \
        "a BC break of an earlier release is history"
    bc_entry = f"{unreleased}\n\n### Changed\n\n- **Breaking (BC break): x** y\n\n{r120}\n"
    assert fails(bump, bc_entry, chart, "1.3.0", "2026-02-03"), "a BC break entry in a minor"
    assert fails(bump, f"{unreleased}\n\n{r120}\n", chart, "1.3.0", "2026-02-03"), "an empty [Unreleased]"
    assert fails(bump, log(unreleased, r120), "version: 1.1.0\n", "1.3.0", "2026-02-03"), "a drift"
    assert fails(bump, log(unreleased, r120), chart, "1.3.0-rc.1", "2026-02-03"), "a pre-release"
    breaking = f"{unreleased}\n\n### Changed\n\n- **Breaking: x** y\n\n### Migration guide from 1.2.0\n\n- z\n\n{r120}\n"
    assert breaking_problems(log(unreleased, r120), ["a"], ["a"]) == []
    found = breaking_problems(log(unreleased, r120), ["a"], ["a", "b: new"])
    assert found and '"b: new"' in found[0], f"a new fail with no Breaking entry, named: {found}"
    assert breaking_problems(breaking, ["a"], ["a", "b"]) == []
    assert breaking_problems(breaking.replace("from 1.2.0", "from 1.1.0"), [], []), "a guide from another release"
    assert breaking_problems(log(r120, r110), [], ["b"]) == [], "a release PR is not checked"
    assert fail_calls(['{{- fail "a: b" }}{{/* fail "c" */}}', '{{ fail (printf "%s: d" $x) }} {{ fail $m }}']) == \
        ["a: b", "%s: d", "$m"]
    assert unmarked_breaking(log(r120, r110), pathlib.Path("no-such-chart/Chart.yaml")) == [], "a release PR reads no tag"
    try:
        release_templates(pathlib.Path(__file__).resolve().parents[1] / "charts/global-chart/Chart.yaml", "0.0.0")
        raise AssertionError("read the templates at a tag that does not exist")
    except Failure as e:
        assert "global-chart-0.0.0" in str(e) and "fetch the tags" in str(e), e
    entry = f"{unreleased}\n\n### Added\n\n- y\n\n{r120}\n"  # unreleased: the heading string above
    assert unlogged_problems(["tests/x.py"], log(unreleased, r120), log(unreleased, r120)), "an unlogged test change"
    assert unlogged_problems(["charts/a"], entry, entry), "an unlogged chart change"
    assert unlogged_problems(["tests/x.py"], log(unreleased, r120), entry) == []
    assert unlogged_problems(["Makefile", ".github/w.yml"], entry, entry) == [], "a dependency bump"
    assert unlogged_problems(["charts/a"], log(unreleased, r120), log("## [1.3.0] — 2026-01-03", r120)) == [], \
        "a release PR"
    try:
        unlogged_change(pathlib.Path(__file__).resolve().parents[1] / "CHANGELOG.md", "refs/nonexistent-self-test")
        raise AssertionError("read a merge-base with a base that does not exist")
    except Failure as e:
        assert "refs/nonexistent-self-test" in str(e) and "fetch-depth: 0" in str(e), e
    print("    OK: self-test")


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    if len(argv) == 4 and argv[0] == "--bump":
        version, paths = argv[1], [pathlib.Path(p) for p in argv[2:]]
        schema = paths[1].with_name("values.schema.json")
        fixtures = [(f, f.read_text()) for f in sorted(paths[0].parent.glob("tests/bad-values/*/*.yaml"))]
        changelog, chart = bump(paths[0].read_text(), paths[1].read_text(), version,
                                datetime.date.today().isoformat(),
                                schema.read_text() if schema.is_file() else "", fixtures)
        # both written beside their target first, then renamed: a failed write leaves neither file half-bumped
        for path, text in zip(paths, (changelog, chart)):
            path.with_name(path.name + ".release-tmp").write_text(text)
        for path in paths:
            os.replace(path.with_name(path.name + ".release-tmp"), path)
        print(f"    OK: [Unreleased] is [{version}], Chart.yaml version {version}")
        return
    if len(argv) != 3:
        sys.exit(__doc__.rsplit("Usage: ", 1)[1])
    chart_file, base = pathlib.Path(argv[1]), argv[2]
    chart, changelog = chart_file.read_text(), pathlib.Path(argv[0]).read_text()
    for header, check in (("Chart.yaml and CHANGELOG.md name different releases", lambda: problems(changelog, chart)),
                          ("a Breaking change is not marked in [Unreleased]",
                           lambda: unmarked_breaking(changelog, chart_file)),
                          ("a change is not logged in [Unreleased]",
                           lambda: unlogged_change(pathlib.Path(argv[0]), base))):
        found = check()
        if found:
            print(f"    FAIL: {header}:")
            for p in found:
                print(f"          - {p}")
            sys.exit(1)
    print(f"    OK: Chart.yaml and CHANGELOG.md agree on {chart_version(chart).group(1)}, every new fail is Breaking, the change since {base} is logged")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except Failure as e:
        print(f"    FAIL: {e}")
        sys.exit(1)
    except OSError as e:
        print(f"    FAIL: cannot read or write CHANGELOG.md or Chart.yaml: {e}")
        sys.exit(1)
