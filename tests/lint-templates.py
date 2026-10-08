#!/usr/bin/env python3
"""The mechanical half of CODING_STANDARDS.md, checked on the templates.

Each rule here is a fixed pattern: a check, not a reviewer's call. The rules a
pattern cannot see (a single home for each enumeration, the precision of a
values path) stay in CODING_STANDARDS.md, for the review.

- default-true: `default true <value>` turns an explicit false into true. A
  boolean defaults through `hasKey … | ternary`.
- values-mutation: `set` on a map reached through `.Values` mutates the values
  every later template reads. Work on a `deepCopy`.
- fail-shape: a `fail` message leads with the values path of the wrong key
  (`%s.` / `%s:` from its single home, or a literal path such as
  `httpRoute.rules[%d]`), or with one of the two documented exceptions: a
  helper's own invariant (`<helper>: …`) and a conflict between entries
  (`Name collision:`, `The fullname`, `Both .Values.ingress`). The rule and its
  exceptions live in the _validate-helpers.tpl header (issue #190).
- template-suite: every template has a `tests/<name>_test.yaml` suite
  (`notes_test.yaml` for NOTES.txt).

Comments (`{{/* … */}}`) are stripped before matching, so a rule may be named in
prose.

Usage: lint-templates.py <chart dir>
"""
import pathlib
import re
import sys

COMMENT = re.compile(r"\{\{-?\s*/\*.*?\*/\s*-?\}\}", re.S)
RULES = {
    "default-true": re.compile(r"\bdefault\s+true\s+[$.(]"),
    "values-mutation": re.compile(r"\bset\s+[$\w.]*\.Values\b"),
}
FAIL = re.compile(r'\bfail\s+(?:\(\s*printf\s+)?"((?:[^"\\]|\\.)*)"')
FAIL_SHAPE = re.compile(r"^(%s[.:\[ ]|[a-z][A-Za-z0-9]*(\.|\[|: )|Name collision: |The fullname |Both \.Values\.ingress)")


def blank_comments(text):
    """Replace each comment with as many newlines as it spans, keeping line numbers."""
    return COMMENT.sub(lambda m: "\n" * m.group(0).count("\n"), text)


def main(chart):
    chart = pathlib.Path(chart)
    templates = chart / "templates"
    problems = []
    for path in sorted(templates.rglob("*")):
        if path.suffix not in {".yaml", ".tpl", ".txt"}:
            continue
        text = blank_comments(path.read_text())
        rel = path.relative_to(chart)
        for lineno, line in enumerate(text.splitlines(), 1):
            for rule, pattern in RULES.items():
                if pattern.search(line):
                    problems.append(f"{rel}:{lineno}: {rule}: {line.strip()}")
            for message in FAIL.findall(line):
                if not FAIL_SHAPE.match(message):
                    problems.append(f"{rel}:{lineno}: fail-shape: \"{message[:60]}\" leads with neither a values path nor a documented exception")
        if path.suffix != ".tpl":
            name = "notes" if path.name == "NOTES.txt" else path.stem
            if not (chart / "tests" / f"{name}_test.yaml").exists():
                problems.append(f"{rel}: template-suite: no tests/{name}_test.yaml")
    if problems:
        print("    FAIL: templates break a mechanical rule of CODING_STANDARDS.md:")
        for p in problems:
            print(f"          - {p}")
        sys.exit(1)
    print("    OK: templates follow the mechanical rules of CODING_STANDARDS.md")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__.rsplit("Usage: ", 1)[1])
    main(sys.argv[1])
