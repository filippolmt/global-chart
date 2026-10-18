#!/usr/bin/env python3
"""A value piped onward in a recipe or a script goes through printf, not echo.

`sh` (dash, which runs every Makefile recipe on Debian and on the CI runner)
expands backslash escapes in echo's arguments: `echo "$manifest" | kubectl`
turned the `\\n` of a rendered nginx config into a line break and sent kubectl
broken YAML. The old e2e-routes carried the bug unseen, because no route
scenario holds a backslash. `printf '%s\\n' "$var"` prints the value as it is.

Checked: the Makefile (`$$var` in recipes) and every tracked `*.sh`. Only a
variable piped onward is flagged: a literal message, or a value echoed to the
terminal, reaches nothing that parses it.

Usage: lint-shell.py
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
# shortcut: a value inside a longer string (`echo "x $var" |`) passes; widen
# the pattern when such a pipe appears
ECHO_PIPE = re.compile(r'echo\s+"\$\$?\{?[A-Za-z_]\w*\}?"\s*\|')


def main():
    files = ["Makefile"] + subprocess.run(["git", "ls-files", "*.sh"], cwd=ROOT, capture_output=True,
                                          text=True, check=True).stdout.split()
    problems = []
    for rel in files:
        for n, line in enumerate((ROOT / rel).read_text().splitlines(), 1):
            if ECHO_PIPE.search(line):
                problems.append(f"{rel}:{n}: pipe a value with printf '%s\\n' \"$var\": sh's echo expands its backslashes")
    if problems:
        print("\n".join(f"    FAIL: {p}" for p in problems))
        return 1
    print(f"    OK: no value piped through echo in {len(files)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
