#!/usr/bin/env python3
"""Every schema property carries a non-empty description.

The schema is what a values author reads (ADR 0019): an IDE or an LLM shows the
`description` where the field is, while a values.yaml comment or the README is
somewhere else. A property without one is a property the author guesses
(issue #203).

The walk. Every entry of every `properties` map is a property, wherever the map
sits: the root, a `$defs`, an `allOf` branch, `items`, `then`. The walk
descends through the schema keywords check-closure-coverage.py names; `$ref` is
not followed, its target is walked where it is defined. A property is named by
its JSON pointer relative to `$defs` (`deployment/properties/image`), or from
the schema root (`properties/global`). A property under `if`, `then`, `else` or
`not` that refines one declared beside the condition (`strategy: false` for a
StatefulSet) is skipped: the declaration beside it carries the description. A
removed key (ADR 0022) is a property too: its description names the
replacement.

The ratchet. tests/schema-descriptions-baseline.txt lists the properties of the
day the check arrived that carried no description. A property missing from both
fails: a new property comes with its description. A baseline line that names no
undescribed property fails too, so the file only shrinks: delete the line.

Usage: check-schema-descriptions.py <schema file> <baseline file>
       check-schema-descriptions.py --self-test
"""
import json
import pathlib
import sys

SCHEMA_MAPS = {"properties", "patternProperties", "$defs", "dependentSchemas"}
SCHEMA_LISTS = {"allOf", "anyOf", "oneOf", "prefixItems"}
SCHEMA_ONE = {"items", "additionalProperties", "unevaluatedProperties", "unevaluatedItems",
              "if", "then", "else", "not", "propertyNames", "contains"}


CONDITIONS = {"if", "then", "else", "not"}


def properties(node, keys=(), refined=()):
    """Yield (keys, schema) for every property; keys is its full JSON path.
    refined: the names a condition refines, declared (and described) beside it."""
    if not isinstance(node, dict):
        return
    for key, value in node.items():
        if key in SCHEMA_MAPS and isinstance(value, dict):
            for name, sub in value.items():
                if key == "properties":
                    if name in refined:
                        continue
                    yield keys + (key, name), sub
                yield from properties(sub, keys + (key, name))
        elif key in SCHEMA_LISTS and isinstance(value, list):
            for i, sub in enumerate(value):
                yield from properties(sub, keys + (key, i))
        elif key in SCHEMA_ONE:
            yield from properties(value, keys + (key,),
                                  node.get("properties", {}).keys() if key in CONDITIONS else ())


def pointer(keys):
    rel = keys[1:] if keys[:1] == ("$defs",) else keys
    return "/".join(map(str, rel))


def undescribed(schema):
    out = set()
    for keys, sub in properties(schema):
        desc = sub.get("description") if isinstance(sub, dict) else None
        if not (isinstance(desc, str) and desc.strip()):
            out.add(pointer(keys))
    return out


def problems(missing, baseline, baseline_name):
    out = [f"{p}: no description; add one to the property" for p in sorted(missing - baseline)]
    out += [f"{p}: described now, or gone; delete the line from {baseline_name}" for p in sorted(baseline - missing)]
    return out


def self_test():
    schema = {
        "properties": {
            "a": {"type": "string", "description": "A."},
            "b": {"type": "string"},
            "c": {"type": "string", "description": "  "},
            "d": {"type": "object", "properties": {"e": {"$ref": "#/$defs/x"}}},
        },
        "$defs": {
            "x": {"description": "A $defs needs none: only properties do.", "type": "object",
                  "properties": {"f": {"description": "F."}},
                  "items": {"properties": {"g": {}}}},
            "y": {"allOf": [{"properties": {"h": {"description": ""}}}],
                  "then": {"properties": {"i": {"description": 1}}}},
            "z": {"properties": {"j": {"description": "J."}},
                  "if": {"properties": {"j": {"const": 1}}},
                  "then": {"properties": {"j": False, "k": {}}}},
        },
    }
    want = {"properties/b", "properties/c", "properties/d", "properties/d/properties/e",
            "x/items/properties/g", "y/allOf/0/properties/h", "y/then/properties/i", "z/then/properties/k"}
    got = undescribed(schema)
    assert got == want, f"undescribed: got {sorted(got)}, want {sorted(want)}"
    assert problems(want, want, "b.txt") == []
    new = problems(want, want - {"properties/b"}, "b.txt")
    assert new == ["properties/b: no description; add one to the property"], new
    stale = problems(want - {"properties/b"}, want, "b.txt")
    assert stale == ["properties/b: described now, or gone; delete the line from b.txt"], stale
    print("    OK: self-test")


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    if len(argv) != 2:
        sys.exit(__doc__.rsplit("Usage: ", 1)[1])
    schema = json.loads(pathlib.Path(argv[0]).read_text())
    baseline_file = pathlib.Path(argv[1])
    baseline = {line for line in baseline_file.read_text().splitlines() if line and not line.startswith("#")}
    missing = undescribed(schema)
    found = problems(missing, baseline, baseline_file.name)
    if found:
        print("    FAIL: the schema properties and the description baseline do not match:")
        for p in found:
            print(f"          - {p}")
        sys.exit(1)
    total = sum(1 for _ in properties(schema))
    print(f"    OK: {total} schema properties, {len(missing)} without a description, all in {baseline_file.name}")


if __name__ == "__main__":
    main(sys.argv[1:])
