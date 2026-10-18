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

The base is checked out in a temporary git worktree, removed on exit, on an
error or on SIGTERM; a SIGKILL leaves it registered: `git worktree prune`.

Usage: render-diff.py <base ref> [helm template flags...]
"""
import pathlib
import re
import signal
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHART = "charts/global-chart"
ENTRY = re.compile(r"^\s*(tests/[^\s:]+):([^\s:]+):([^\s:\\]+)", re.M)
MASKS = (
    (re.compile(r'(\btimestamp: )"\d{14}"'), r'\1"<now>"'),
    (re.compile(r"(helm\.sh/chart: \S+?-)\d+\.\d+\.\d+\S*"), r"\1<version>"),
)


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


def render(cwd, values, namespace, flags):
    run = subprocess.run(["helm", "template", "render-diff", f"./{CHART}", "-f", values,
                          "--namespace", namespace, *flags], cwd=cwd, capture_output=True, text=True)
    lines = []
    for line in (run.stdout + run.stderr).splitlines():
        if line.startswith("# Source:"):
            continue
        for pattern, repl in MASKS:
            line = pattern.sub(repl, line)
        lines.append(line)
    return lines


def git(*args):
    run = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True)
    if run.returncode:
        raise Failure(f"git {' '.join(args)}: {run.stderr.strip()}")
    return run.stdout


def compare(base, flags):
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
                a = render(tree, base_values, namespace, flags)
                b = render(ROOT, values, namespace, flags)
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


def main(base, flags):
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        count, problems = compare(base, flags)
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
    if len(sys.argv) < 2:
        sys.exit(__doc__.rsplit("Usage: ", 1)[1])
    sys.exit(main(sys.argv[1], sys.argv[2:]))
