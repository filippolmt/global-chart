#!/usr/bin/env python3
"""Every integer the schema accepts is one the chart carries exactly to the API.

Helm reads a values number as a float64: past 2^53 an integer renders rounded,
and the API server takes the wrong number without a word (issue #250). Below
that, an API field is an int32 or an int64, and the schema mirrors the bound
(issue #226). make bound-sweep holds a declared bound to the API server, but
it cannot see a missing one that a template `fail` shadows in every scenario:
pdb.minAvailable lost its int32 maximum that way (PR #254). This reads the
schema instead:

- an integer node (a `type` that holds "integer") declares a `maximum`, or a
  `const` or an `enum`;
- no `maximum` above 2^53-1 and no `minimum` below -(2^53-1);
- a node that takes an integer or its digit string (`type` holds both
  "integer" and "string") bounds the digits of its `pattern`: `[0-9]*`,
  `[0-9]+` and `\\d` with no count leave a digit string free to overflow the
  int64 arithmetic of a template (a hook weight rendered "0", PR #254).

Every node is walked, conditions included; `$ref` is not followed, its target
is walked where it is defined.

Usage: check-schema-bounds.py <schema file>
       check-schema-bounds.py --self-test
"""
import json
import pathlib
import re
import sys

INT53 = 2**53 - 1
UNBOUNDED_DIGITS = re.compile(r"(\[0-9\]|\\d)[*+]")


def nodes(node, path="#"):
    if isinstance(node, dict):
        yield path, node
        for key, value in node.items():
            yield from nodes(value, f"{path}/{key}")
    elif isinstance(node, list):
        for i, value in enumerate(node):
            yield from nodes(value, f"{path}/{i}")


def types_of(n):
    """The node's type keyword, or nothing: a `properties` map may hold a field named type."""
    t = n.get("type")
    return {t} if isinstance(t, str) else set(t) if isinstance(t, list) else set()


def problems(schema):
    out = []
    for path, n in nodes(schema):
        types = types_of(n)
        if "integer" not in types:
            continue
        if not ({"maximum", "const", "enum"} & n.keys()):
            out.append(f"{path}: an integer with no maximum; declare the API field's (2147483647 for an int32, {INT53} for an int64)")
        if n.get("maximum", 0) > INT53 or n.get("minimum", 0) < -INT53:
            out.append(f"{path}: a bound past ±{INT53}, which Helm cannot carry exactly")
        if "string" in types and UNBOUNDED_DIGITS.search(n.get("pattern", "")):
            out.append(f"{path}: the digit string's pattern {n['pattern']!r} leaves the digits unbounded; give them a count")
    return out


def self_test():
    schema = {"$defs": {
        "ok": {"type": "integer", "minimum": 0, "maximum": 2147483647},
        "const": {"type": "integer", "const": 1},
        "enum": {"type": ["integer", "string"], "enum": [1, "a"]},
        "str": {"type": "string", "pattern": "^[0-9]+$"},
        "nomax": {"type": "integer", "minimum": 0},
        "big": {"type": "integer", "maximum": 2**53},
        "low": {"type": "integer", "minimum": -(2**53), "maximum": 1},
        "digits": {"type": ["string", "integer"], "pattern": "^-?[0-9]*$", "maximum": 1},
        "counted": {"type": ["integer", "string"], "pattern": "^[0-9]{1,9}$", "maximum": 1},
        "nested": {"oneOf": [{"type": "integer"}]},
        "field": {"properties": {"type": {"type": "string"}}},
    }}
    got = {p.split(":")[0] for p in problems(schema)}
    want = {"#/$defs/nomax", "#/$defs/big", "#/$defs/low", "#/$defs/digits", "#/$defs/nested/oneOf/0"}
    assert got == want, f"problems: got {sorted(got)}, want {sorted(want)}"
    print("    OK: self-test")


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    if len(argv) != 1:
        sys.exit(__doc__.rsplit("Usage: ", 1)[1])
    schema = json.loads(pathlib.Path(argv[0]).read_text())
    found = problems(schema)
    if found:
        print("    FAIL: integers the chart cannot carry exactly to the API server:")
        for p in found:
            print(f"          - {p}")
        sys.exit(1)
    total = sum(1 for _, n in nodes(schema) if "integer" in types_of(n))
    print(f"    OK: {total} integer nodes, each bounded within ±(2^53-1)")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (OSError, json.JSONDecodeError) as e:
        print(f"    FAIL: cannot read the schema: {e}")
        sys.exit(1)
