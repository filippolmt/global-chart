#!/usr/bin/env python3
"""Render every TEST_CASES scenario on a base ref and on the working tree, and
diff them: a rename or a refactor that claims to change no manifest proves it
here (issue #221 did it three times by hand).

A scenario is paired with its base by namespace (the second field of a
TEST_CASES entry) and by its rank among the entries sharing that namespace,
not by file or slug, which a rename changes. Both sides render under one
release name, and the `# Source:` lines are dropped: they carry only the
template's path, which a template rename changes. The `timestamp` pod
annotation of a workload with pod recreation reads the clock (workload.yaml),
so its value is masked. An error renders as its message, so a scenario failing
the same way on both sides is a match.

The base is checked out in a temporary git worktree, removed on exit.

Usage: render-diff.py <base ref> [helm template flags...]
"""
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHART = "charts/global-chart"
ENTRY = re.compile(r"^\s*(tests/[^\s:]+):([^\s:]+):([^\s:\\]+)", re.M)
CLOCK = re.compile(r'(\btimestamp: )"\d{14}"')


def entries(makefile):
    """TEST_CASES as {(namespace, rank): (values, slug)}."""
    block = makefile.split("TEST_CASES := \\", 1)[1].split("\n\n", 1)[0]
    out, seen = {}, {}
    for values, namespace, slug in ENTRY.findall(block):
        rank = seen[namespace] = seen.get(namespace, -1) + 1
        out[(namespace, rank)] = (values, slug)
    return out


def render(cwd, values, namespace, flags):
    run = subprocess.run(["helm", "template", "render-diff", f"./{CHART}", "-f", values,
                          "--namespace", namespace, *flags], cwd=cwd, capture_output=True, text=True)
    text = run.stdout + run.stderr
    return "\n".join(CLOCK.sub(r'\1"<now>"', line) for line in text.splitlines() if not line.startswith("# Source:"))


def main(base, flags):
    head = entries((ROOT / "Makefile").read_text())
    old = entries(subprocess.run(["git", "show", f"{base}:Makefile"], cwd=ROOT,
                                 capture_output=True, text=True, check=True).stdout)
    problems = [f"{ns}#{r}: only on {side}" for side, a, b in (("HEAD", head, old), (base, old, head))
                for ns, r in sorted(a.keys() - b.keys())]
    with tempfile.TemporaryDirectory() as tmp:
        tree = pathlib.Path(tmp) / "base"
        subprocess.run(["git", "worktree", "add", "--detach", "-q", str(tree), base], cwd=ROOT, check=True)
        try:
            for key in sorted(head.keys() & old.keys()):
                (values, slug), (base_values, _) = head[key], old[key]
                a = render(tree, base_values, key[0], flags)
                b = render(ROOT, values, key[0], flags)
                if a == b:
                    print(f"    OK: {slug}")
                    continue
                lines = [f"{slug}: differs from {base}:{base_values}"]
                al, bl = a.splitlines(), b.splitlines()
                first = next((i for i, (x, y) in enumerate(zip(al, bl)) if x != y), min(len(al), len(bl)))
                lines += [f"      line {first + 1}: {base}: {al[first] if first < len(al) else '<end>'}",
                          f"      line {first + 1}: HEAD: {bl[first] if first < len(bl) else '<end>'}"]
                problems.append("\n".join(lines))
        finally:
            subprocess.run(["git", "worktree", "remove", "--force", str(tree)], cwd=ROOT, check=True)
    if problems:
        print(f"    FAIL: the rendered manifests differ from {base}:")
        for p in problems:
            print(f"          - {p}")
        return 1
    print(f"    OK: {len(head)} scenarios render the same manifests as {base}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__.rsplit("Usage: ", 1)[1])
    sys.exit(main(sys.argv[1], sys.argv[2:]))
