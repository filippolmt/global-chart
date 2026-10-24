#!/usr/bin/env python3
"""Render every TEST_CASES scenario on a base ref and on the working tree, and
diff them: a rename or a refactor that claims to change no manifest proves it
here (issue #221 did it three times by hand).

Pairing. A scenario is paired with the base's entry of the same values file;
the entries left over on both sides (a renamed file) pair by namespace, the
second field of a TEST_CASES entry, in order. An entry left with no partner
fails as "only on HEAD" or "only on <base>".

Masking. Both sides render under one release name. Dropped or masked, since
they change with no manifest change: the `# Source:` lines (the template's
path, which a template rename changes), the version in `helm.sh/chart` (a
release PR bumps it), and the `timestamp` pod annotation of a workload with
pod recreation (workload.yaml reads the clock). An error renders as its
message, so a scenario failing the same way on both sides is a match.

--ignore-quotes (make render-diff QUOTES=ignore) also reads `key: "value"` as
`key: value` on both sides when the plain form is still a string: the proof
that a change only quoted what YAML already read as a string (issue #251). A
value YAML 1.1 could read as another type keeps its quotes ("0", "1e3",
"true", "on", "null"), so a quote that changes a type still differs.

The base is checked out in a temporary git worktree, removed on exit, on an
error or on SIGTERM; a SIGKILL leaves it registered: `git worktree prune`.

Usage: render-diff.py [--ignore-quotes] <base ref> [helm template flags...]
       render-diff.py --self-test
"""
import pathlib
import re
import signal
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHART = "charts/global-chart"
ENTRY = re.compile(r"^\s*([^\s:]+):([^\s:]+):([^\s:\\]+)", re.M)
MASKS = (
    (re.compile(r'(\btimestamp: )"\d{14}"'), r'\1"<now>"'),
    (re.compile(r"(helm\.sh/chart: \S+?-)\d+\.\d+\.\d+\S*"), r"\1<version>"),
)
# The Basic Auth password and its hash are random on every render (ADR 0024):
# masked in securitypolicy.yaml only, so a Secret of the values keeps its diff
RANDOM_SOURCE = "# Source: global-chart/templates/securitypolicy.yaml"
RANDOM = re.compile(r'^(  (?:password|\.htpasswd): )"[A-Za-z0-9+/=]+"$')
QUOTED = re.compile(r'^(\s*(?:- )?[\w./-]+: )"([A-Za-z/][-A-Za-z0-9./_]*)"$')
# YAML 1.1 words a plain scalar resolves to a bool or a null; a leading digit,
# sign or dot is excluded by QUOTED itself (a number, "1e3", a timestamp)
YAML11_WORDS = {w for b in ("y", "yes", "n", "no", "true", "false", "on", "off", "null")
                for w in (b, b.capitalize(), b.upper())}


def unquote(line):
    """`key: "value"` as `key: value` when the plain value is still a string."""
    m = QUOTED.match(line)
    return f"{m.group(1)}{m.group(2)}" if m and m.group(2) not in YAML11_WORDS else line


def self_test():
    same = {'  name: "render-diff-web"': "  name: render-diff-web",
            '    - name: "http"': "    - name: http", '  - path: "/x"': "  - path: /x",
            '  app.kubernetes.io/instance: "render-diff"': "  app.kubernetes.io/instance: render-diff"}
    kept = ['  name: "0"', '  name: "1e3"', '  name: "true"', '  name: "On"', '  name: "NULL"',
            '  name: "a b"', '  name: "-a"']
    for line, want in same.items():
        assert unquote(line) == want, f"unquote({line!r}) = {unquote(line)!r}, want {want!r}"
    for line in kept:
        assert unquote(line) == line, f"unquote({line!r}) changed it"
    assert RANDOM.sub(r'\1"<random>"', '  password: "YWJj"') == '  password: "<random>"'
    assert RANDOM.sub(r'\1"<random>"', '  username: "YWJj"') == '  username: "YWJj"'
    print("    OK: self-test")


class Failure(Exception):
    pass


def entries(makefile, where):
    """TEST_CASES as a list of (values, namespace, slug)."""
    if "TEST_CASES := \\" not in makefile:
        raise Failure(f"{where}: no `TEST_CASES := \\` block in the Makefile")
    return ENTRY.findall(makefile.split("TEST_CASES := \\", 1)[1].split("\n\n", 1)[0])


def pairs(head, old):
    """[(head entry, base entry)] and the entries left with no partner."""
    old_by_values = {e[0]: e for e in old}
    matched = [(h, old_by_values[h[0]]) for h in head if h[0] in old_by_values]
    taken = {b[0] for _, b in matched}
    rest_head = [h for h in head if h[0] not in old_by_values]
    rest_old = [b for b in old if b[0] not in taken]
    for h in list(rest_head):
        b = next((b for b in rest_old if b[1] == h[1]), None)
        if b:
            matched.append((h, b))
            rest_head.remove(h)
            rest_old.remove(b)
    return matched, rest_head, rest_old


def render(cwd, values, namespace, flags, ignore_quotes=False):
    run = subprocess.run(["helm", "template", "render-diff", f"./{CHART}", "-f", values,
                          "--namespace", namespace, *flags], cwd=cwd, capture_output=True, text=True)
    lines, source = [], ""
    for line in (run.stdout + run.stderr).splitlines():
        if line.startswith("# Source:"):
            source = line
            continue
        if source == RANDOM_SOURCE:
            line = RANDOM.sub(r'\1"<random>"', line)
        for pattern, repl in MASKS:
            line = pattern.sub(repl, line)
        lines.append(unquote(line) if ignore_quotes else line)
    return lines


def git(*args):
    run = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True)
    if run.returncode:
        raise Failure(f"git {' '.join(args)}: {run.stderr.strip()}")
    return run.stdout


def compare(base, flags, ignore_quotes=False):
    head = entries((ROOT / "Makefile").read_text(), "HEAD")
    old = entries(git("show", f"{base}:Makefile"), base)
    matched, only_head, only_old = pairs(head, old)
    problems = [f"{e[2]} ({e[0]}): only on HEAD" for e in only_head]
    problems += [f"{e[2]} ({e[0]}): only on {base}" for e in only_old]
    with tempfile.TemporaryDirectory() as tmp:
        tree = pathlib.Path(tmp) / "base"
        git("worktree", "add", "--detach", "-q", str(tree), base)
        try:
            for (values, namespace, slug), (base_values, _, _) in matched:
                a = render(tree, base_values, namespace, flags, ignore_quotes)
                b = render(ROOT, values, namespace, flags, ignore_quotes)
                if a == b:
                    continue
                i = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
                problems.append(f"{slug} ({values}, paired with {base}:{base_values}): first difference at line {i + 1}\n"
                                f"              {base}: {a[i] if i < len(a) else '<end>'}\n"
                                f"              HEAD: {b[i] if i < len(b) else '<end>'}")
        finally:
            # check=False: a failed removal must not hide the error that got here
            subprocess.run(["git", "worktree", "remove", "--force", str(tree)], cwd=ROOT, capture_output=True)
    return len(matched), problems


def main(base, flags, ignore_quotes=False):
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        count, problems = compare(base, flags, ignore_quotes)
    except Failure as e:
        print(f"    FAIL: {e}")
        return 1
    if problems:
        print(f"    FAIL: the rendered manifests differ from {base}:")
        for p in problems:
            print(f"          - {p}")
        return 1
    print(f"    OK: {count} scenarios render the same manifests as {base}")
    return 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if args == ["--self-test"]:
        sys.exit(self_test())
    ignore_quotes = args[:1] == ["--ignore-quotes"]
    args = args[1:] if ignore_quotes else args
    if not args:
        sys.exit(__doc__.rsplit("Usage: ", 1)[1])
    sys.exit(main(args[0], args[1:], ignore_quotes))
