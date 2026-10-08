#!/usr/bin/env python3
"""The mechanical half of CODING_STANDARDS.md, checked on the templates.

Each rule here is a fixed pattern: a check, not a reviewer's call. The rules a
pattern cannot see (a single home for each enumeration, the precision of a
values path) stay in CODING_STANDARDS.md, for the review — and so does any form
a rule below cannot recognise: a check that sees nothing is not a pass.

- default-true: `default true <value>` and `<value> | default true` turn an
  explicit false into true. A boolean defaults through `hasKey … | ternary`.
- values-mutation: `set` on a map reached from `.Values` mutates the values
  every later template reads: on `.Values…` itself, or on a variable bound to
  it (`$d := index .Values.deployments $n`, `range $k, $d := .Values.x`, and
  anything bound from such a variable). A variable bound through `deepCopy` is
  a copy, and so is one built by `dict`, `list`, `include` or `fromJson`.
- fail-shape: a `fail` message leads with the values path of the wrong key, or
  with one of the two documented exceptions. The shape and the exceptions are
  the _validate-helpers.tpl header's (issue #190), mirrored by FAIL_SHAPE below:
  change both. A path is `%s` followed by `.`, `[` or `:` (a path from its
  single home), or a top-level values key of values.schema.json followed by
  `.`, `[` or `: `. A helper's own invariant leads with a helper the chart
  defines, then `: `. A message that is not a literal (`fail $msg`,
  `fail (print …)`) cannot be checked and is reported as such.
- template-suite: every template has a `tests/<name>_test.yaml` suite
  (`notes_test.yaml` for NOTES.txt).

Comments (`{{/* … */}}`) are stripped before matching, so a rule may be named in
prose. Matching runs over the whole file, so an expression split across lines
is seen whole.

Usage: lint-templates.py <chart dir>
"""
import json
import pathlib
import re
import sys

COMMENT = re.compile(r"\{\{-?\s*/\*.*?\*/\s*-?\}\}", re.S)
DEFAULT_TRUE = re.compile(r"\bdefault\s+true\s+[$.(]|\|\s*default\s+true\b")
SET_TARGET = re.compile(r"\bset\s+(\$[\w]+|\.Values\b|\$\.Values\b|\$root\.Values\b)")
BIND = re.compile(r"(\$\w+)\s*:?=\s*([^}]*?)\s*-?\}\}")
RANGE_BIND = re.compile(r"\brange\s+(?:\$\w+\s*,\s*)?(\$\w+)\s*:=\s*([^}]*?)\s*-?\}\}")
COPY = re.compile(r"^\(?\s*(deepCopy|dict|list|include|fromJson|fromJsonArray|toJson|printf|print|len|keys)\b")
FAIL = re.compile(r"\bfail\s+(\(\s*printf\s+\"|\")((?:[^\"\\]|\\.)*)\"", re.S)
FAIL_ANY = re.compile(r"\bfail\s+(?!\(\s*printf\s+\"|\")(\S+)")
EXCEPTIONS = ("Name collision: ", "The fullname ", "Both .Values.ingress")


def blank_comments(text):
    """Replace each comment with as many newlines as it spans, keeping line numbers."""
    return COMMENT.sub(lambda m: "\n" * m.group(0).count("\n"), text)


def lineno(text, pos):
    return text.count("\n", 0, pos) + 1


def values_aliases(text):
    """The variables of a file bound, directly or through each other, to .Values."""
    binds = [(m.group(1), m.group(2)) for m in BIND.finditer(text)]
    binds += [(m.group(1), m.group(2)) for m in RANGE_BIND.finditer(text)]
    aliases = set()
    changed = True
    while changed:
        changed = False
        for var, rhs in binds:
            if var in aliases or COPY.match(rhs.strip()):
                continue
            if ".Values" in rhs or any(re.search(re.escape(a) + r"\b", rhs) for a in aliases):
                aliases.add(var)
                changed = True
    return aliases


def fail_shape(message, top_keys, helpers):
    if message.startswith(EXCEPTIONS):
        return True
    if re.match(r"%s[.:\[]", message):
        return True
    m = re.match(r"([A-Za-z][A-Za-z0-9-]*)(\.|\[|: )", message)
    if not m:
        return False
    word, sep = m.groups()
    if word in top_keys:
        return True
    return sep == ": " and word in helpers


def main(chart):
    chart = pathlib.Path(chart)
    templates = chart / "templates"
    schema = json.loads((chart / "values.schema.json").read_text())
    top_keys = set(schema.get("properties", {}))
    helpers = set()
    for path in templates.rglob("*.tpl"):
        helpers |= set(re.findall(r'define\s+"global-chart\.([\w-]+)"', path.read_text()))
    problems = []
    for path in sorted(templates.rglob("*")):
        if path.suffix not in {".yaml", ".tpl", ".txt"}:
            continue
        text = blank_comments(path.read_text())
        rel = path.relative_to(chart)
        for m in DEFAULT_TRUE.finditer(text):
            problems.append(f"{rel}:{lineno(text, m.start())}: default-true: {m.group(0).strip()}")
        aliases = values_aliases(text)
        for m in SET_TARGET.finditer(text):
            target = m.group(1)
            if "Values" in target or target in aliases:
                problems.append(f"{rel}:{lineno(text, m.start())}: values-mutation: set on {target}, bound to .Values; work on a deepCopy")
        for m in FAIL.finditer(text):
            if not fail_shape(m.group(2), top_keys, helpers):
                problems.append(f"{rel}:{lineno(text, m.start())}: fail-shape: \"{m.group(2)[:60]}\" leads with neither a values path nor a documented exception")
        for m in FAIL_ANY.finditer(text):
            problems.append(f"{rel}:{lineno(text, m.start())}: fail-shape: the message ({m.group(1)[:40]}) is not a literal and cannot be checked; write it as fail \"…\" or fail (printf \"…\" …)")
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
