#!/usr/bin/env python3
"""Prove a check goes red (CODING_STANDARDS.md, *A check proves it can fail*).

Runs the command on FILE as it is, which must pass; replaces FROM by TO in
FILE, runs the command again, which must fail; restores FILE byte for byte
whatever happens, SIGTERM included. FROM must occur exactly once: one that
matches nothing leaves the file as it was, and a red then proves nothing. The
green run first makes the red the mutation's, not a target that does not
exist or a tool that is down. Issue #288 read a red run as the original
code's when the mutation had applied.

shortcut: a SIGKILL leaves FILE mutated (`git diff` shows it); a lock file
would be the upgrade if that ever happens.

Usage: mutate.py <file> <from> <to> <command>...
       mutate.py --self-test
"""
import pathlib
import signal
import subprocess
import sys
import tempfile


def run(command):
    """(returncode, last lines of output), or (None, why) when it cannot start."""
    try:
        out = subprocess.run(command, capture_output=True, text=True)
    except OSError as e:
        return None, f"cannot run {' '.join(command)}: {e}"
    return out.returncode, "\n".join((out.stdout + out.stderr).strip().splitlines()[-8:])


def mutate(path, old, new, command):
    """(passed, message, tail): whether the command passed on FILE and failed on the mutation."""
    try:
        original = path.read_bytes()
    except OSError as e:
        return False, f"cannot read {path}: {e}", ""
    count = original.count(old.encode())
    if count != 1:
        hint = " (FROM has a `$$`: make passes it on literally, write one `$`)" if "$$" in old else ""
        return False, f"{path}: FROM occurs {count} times, not once: the mutation would prove nothing{hint}", ""
    code, tail = run(command)
    if code is None:
        return False, tail, ""
    if code != 0:
        return False, f"{' '.join(command)} is red before the mutation: a red after it would prove nothing", tail
    try:
        path.write_bytes(original.replace(old.encode(), new.encode()))
        code, tail = run(command)
    finally:
        path.write_bytes(original)
    if code is None:
        return False, tail, ""
    if code == 0:
        return False, f"{' '.join(command)} stays green on the mutation: the check does not see it", tail
    return True, f"{' '.join(command)} is green on {path} and red on the mutation; the file is restored", tail


def self_test():
    with tempfile.TemporaryDirectory() as tmp:
        f = pathlib.Path(tmp) / "x.txt"
        f.write_bytes(b"a b a\r\n")
        no_c = ["sh", "-c", f"! grep -q c {f}"]  # green on the file, red once b becomes c
        assert not mutate(f, "a", "c", no_c)[0], "FROM twice"
        assert not mutate(f, "z", "c", no_c)[0], "FROM absent"
        assert not mutate(f, "b", "c", ["true"])[0], "a check that stays green"
        assert not mutate(f, "b", "c", ["false"])[0], "a check red before the mutation"
        assert not mutate(f, "b", "c", ["/nonexistent-mutate-command"])[0], "a command that cannot start"
        assert mutate(f, "b", "c", no_c)[0], "a check that sees the mutation"
        assert f.read_bytes() == b"a b a\r\n", "the file is restored byte for byte"
    print("    OK: self-test")


def main(argv):
    if argv[1:] == ["--self-test"]:
        self_test()
        return
    if len(argv) < 5:
        sys.exit(__doc__.rsplit("Usage: ", 1)[1])
    # SIGTERM raises SystemExit, so the restore in mutate's finally runs
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    passed, message, tail = mutate(pathlib.Path(argv[1]), argv[2], argv[3], argv[4:])
    print(f"    {'OK' if passed else 'FAIL'}: {message}")
    if tail:
        print("\n".join("          " + line for line in tail.splitlines()))
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main(sys.argv)
