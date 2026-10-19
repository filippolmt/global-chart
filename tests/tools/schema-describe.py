#!/usr/bin/env python3
"""Add descriptions to values.schema.json properties, keeping the file's hand
formatting (inline properties beside multi-line objects): a json.dump would
rewrite every line. Each description lands as the first key of its property.

The input is a JSON object from a property pointer, in the form
check-schema-descriptions.py prints (`deployment/properties/image`, relative to
$defs, or `properties/global` from the root), to its description. A pointer
that names no object, or a property that already carries a description, fails
before anything is written.

Usage: schema-describe.py <schema file> <descriptions.json>
       schema-describe.py --self-test
"""
import json
import re
import sys

WS = re.compile(r"\s*")


def object_offsets(text):
    """Every JSON object of text by its path (a tuple of keys and indexes), at the offset of its '{'."""
    out = {}

    def skip(i):
        return WS.match(text, i).end()

    def value(i, path):
        i = skip(i)
        if text[i] == "{":
            out[path] = i
            i = skip(i + 1)
            if text[i] == "}":
                return i + 1
            while True:
                key, i = json.decoder.scanstring(text, skip(i) + 1)
                i = skip(value(skip(i) + 1, path + (key,)))
                if text[i] == "}":
                    return i + 1
                i += 1
        if text[i] == "[":
            i, n = skip(i + 1), 0
            if text[i] == "]":
                return i + 1
            while True:
                i, n = skip(value(i, path + (n,))), n + 1
                if text[i] == "]":
                    return i + 1
                i += 1
        if text[i] == '"':
            return json.decoder.scanstring(text, i + 1)[1]
        return json.JSONDecoder().raw_decode(text, i)[1]

    value(0, ())
    return out


def describe(text, descriptions):
    """text with each description inserted; raises ValueError naming a pointer it cannot place."""
    schema, offsets, edits = json.loads(text), object_offsets(text), []
    for pointer, desc in descriptions.items():
        parts = tuple(int(p) if p.isdigit() else p for p in pointer.split("/"))
        path = parts if parts[0] == "properties" else ("$defs",) + parts
        if path not in offsets:
            raise ValueError(f"{pointer}: names no object in the schema")
        node = schema
        for key in path:
            node = node[key]
        if "description" in node:
            raise ValueError(f"{pointer}: carries a description already")
        i = offsets[path] + 1
        entry = f'"description": {json.dumps(desc, ensure_ascii=False)}'
        indent = re.compile(r"\n([ \t]*)").match(text, i)
        if indent:
            edits.append((i, f"\n{indent.group(1)}{entry},"))
        else:
            edits.append((i, f" {entry} " if text[WS.match(text, i).end()] == "}" else f" {entry},"))
    for i, ins in sorted(edits, reverse=True):
        text = text[:i] + ins + text[i:]
    json.loads(text)
    return text


def self_test():
    text = '{\n  "$defs": {\n    "x": {\n      "type": "object",\n      "properties": {\n        "a": { "type": "string" },\n        "b": {},\n        "c": {\n          "type": "number"\n        }\n      }\n    }\n  }\n}\n'
    got = describe(text, {"x/properties/a": "A \"q\".", "x/properties/b": "B.", "x/properties/c": "C."})
    want = text.replace('"a": { "type"', '"a": { "description": "A \\"q\\".", "type"') \
               .replace('"b": {}', '"b": { "description": "B." }') \
               .replace('"c": {\n          "type"', '"c": {\n          "description": "C.",\n          "type"')
    assert got == want, got
    for bad in ({"x/properties/z": "Z."}, {"x/properties/a": "Again."}):
        try:
            describe(got, bad)
        except ValueError:
            continue
        raise AssertionError(f"{bad} was placed")
    print("    OK: self-test")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        sys.exit(0)
    if len(sys.argv) != 3:
        sys.exit(__doc__.rsplit("Usage: ", 1)[1])
    try:
        with open(sys.argv[1]) as f:
            text = f.read()
        with open(sys.argv[2]) as f:
            descriptions = json.load(f)
        if not isinstance(descriptions, dict):
            raise ValueError(f"{sys.argv[2]}: not a JSON object from property pointer to description")
        text = describe(text, descriptions)
    except (OSError, ValueError) as e:
        print(f"    FAIL: {e}")
        sys.exit(1)
    with open(sys.argv[1], "w") as f:
        f.write(text)
    print(f"    OK: {len(descriptions)} descriptions added")
