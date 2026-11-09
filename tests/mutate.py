#!/usr/bin/env python3
"""Prove a check goes red (CODING_STANDARDS.md, *A check proves it can fail*).

Replaces FROM by TO in FILE, runs the command, and restores FILE whatever
happens. Passes only when FROM occurs exactly once and the command fails on the
mutated file: a FROM that matches nothing leaves the file as it was, and the
check that then passes, or fails on something else, proves nothing. Issue #288
read a red run as the original code's when the mutation had applied.

Prints the command's last lines, so the red can be checked to be the one meant.

Usage: mutate.py <file> <from> <to> <command>...
"""
import pathlib
import subprocess
import sys
import tempfile


def mutate(path, old, new, command):
    """(passed, message): whether the command failed on the mutated file."""
    try:
        original = path.read_text()
    except OSError as e:
        return False, f"cannot read {path}: {e}"
    count = original.count(old)
    if count != 1:
        return False, f"{path}: FROM occurs {count} times, not once: the mutation would prove nothing"
    path.write_text(original.replace(old, new))
    try:
        out = subprocess.run(command, capture_output=True, text=True)
    finally:
        path.write_text(original)
    tail = "\n".join((out.stdout + out.stderr).strip().splitlines()[-8:])
    if out.returncode == 0:
        return False, f"{' '.join(command)} passed on the mutated file: the check does not see the mutation\n{tail}"
    return True, f"{' '.join(command)} went red on the mutated file, and {path} is restored\n{tail}"


def self_test():
    with tempfile.TemporaryDirectory() as tmp:
        f = pathlib.Path(tmp) / "x.txt"
        f.write_text("a b a")
        assert not mutate(f, "a", "c", ["false"])[0], "FROM twice"
        assert not mutate(f, "z", "c", ["false"])[0], "FROM absent"
        assert not mutate(f, "b", "c", ["true"])[0], "a check that stays green"
        assert mutate(f, "b", "c", ["grep", "-q", "b", str(f)])[0], "a check that sees the mutation"
        assert f.read_text() == "a b a", "the file is restored"


def main(argv):
    self_test()
    if len(argv) < 5:
        sys.exit(__doc__.rsplit("Usage: ", 1)[1])
    passed, message = mutate(pathlib.Path(argv[1]), argv[2], argv[3], argv[4:])
    print(f"    {'OK' if passed else 'FAIL'}: {message}")
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main(sys.argv)
