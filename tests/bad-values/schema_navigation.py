"""Two deliberately different schema interpretations for the sweeps and coverage.

Conservative declarations (declaration / declared_paths) follow references as
replacements, ignoring siblings. They union allOf types, group alternatives,
ignore null, and use the valuesShape vocabulary (map/list/number/etc.). An
untyped branch is distinct from an undeclared path. What this reading skips
(if/then/else, not, a reference's siblings, allOf read as a union) can only
narrow what a node accepts, so its types are a superset and valuesShape
matching them fails no valid value; the one construct that widens, a branch
with no type, is reported as untyped, never read as no type. Discovery is a
separate walk, not repeated lookup: it accumulates duplicate paths in
discovery order and stops at depth > 20, including the root at depth 0.

Source queries (sources / generic_sources) retain every original (pointer,
node) contribution, in preorder: node, reference target, allOf, oneOf, anyOf.
They apply reference siblings, never merge bounds or deduplicate sources, and
expand terminal contributions once. Candidate policy belongs to bound-sweep.
resolve_pointer returns the original node for a slash-prefixed source pointer,
including list indices, so the bound self-test can mutate its scratch schema.

Paths: declaration takes tuples of property names, '*' (additional/pattern
properties), or '[]' (items). sources takes concrete string/integer tuples,
with explicit properties preferred over additionalProperties in each part;
patternProperties are ignored. generic_sources accepts coverage's dotted
strings with '*' and list suffixes, retaining its legacy list-descent defect.

These are not general JSON Schema evaluators: no pointer decoding, external
references, cycle protection, conditionals, or new schema forms. Conservative
anyOf replaces oneOf when both exist; const/enum do not imply types; a property
named '*' or '[]' reads as the wildcard of that name. Keep these
limitations until a separate behavior change updates the callers' contracts.
"""
from typing import NamedTuple


class Declaration(NamedTuple):
    types: set
    untyped: bool


_SCHEMA_TYPES = {"object": "map", "array": "list", "string": "string", "boolean": "boolean",
                 "integer": "number", "number": "number"}


def _alternatives(schema, node):
    while "$ref" in node:
        node = resolve_pointer(schema, node["$ref"].lstrip("#"))
    alternatives = [node]
    for key in ("oneOf", "anyOf"):
        if key in node:
            alternatives = [a for n in node[key] for a in _alternatives(schema, n)]
    return alternatives


def _types(schema, node):
    types = set()
    for a in _alternatives(schema, node):
        t = a.get("type")
        types |= {_SCHEMA_TYPES[x] for x in ([t] if isinstance(t, str) else t or []) if x != "null"}
        for n in a.get("allOf", []):
            types |= _types(schema, n)
    return types


def _untyped(schema, node):
    return any("type" not in a and all(_untyped(schema, n) for n in a.get("allOf", []))
               for a in _alternatives(schema, node))


def _declaration_parts(schema, node):
    return [node] + [p for n in node.get("allOf", []) for a in _alternatives(schema, n)
                     for p in _declaration_parts(schema, a)]


def _declaration_entries(part):
    yield from part.get("properties", {}).items()
    if isinstance(part.get("additionalProperties"), dict):
        yield "*", part["additionalProperties"]
    for child in part.get("patternProperties", {}).values():
        yield "*", child
    if isinstance(part.get("items"), dict):
        yield "[]", part["items"]


def _declaration_child(schema, node, key):
    branches = []
    for a in _alternatives(schema, node):
        found = [child for part in _declaration_parts(schema, a)
                 for k, child in _declaration_entries(part) if k == key]
        if found:
            branches.append({"allOf": found})
    return {"anyOf": branches} if branches else None


def declaration(schema, path):
    """Conservative types and untyped-branch flag at tuple path; None if undeclared."""
    node = schema
    for key in path:
        node = _declaration_child(schema, node, key)
        if node is None:
            return None
    return Declaration(_types(schema, node), _untyped(schema, node))


def declared_paths(schema):
    """Discover the complete ordered generic-path → type-set mapping, including root."""
    out = {}

    def walk(node, path, depth):
        if node is None or depth > 20:
            return
        out.setdefault(path, set()).update(_types(schema, node))
        for alternative in _alternatives(schema, node):
            for part in _declaration_parts(schema, alternative):
                for key, child in _declaration_entries(part):
                    walk(child, path + key if key == "[]" else f"{path}.{key}" if path else key, depth + 1)
    walk(schema, "", 0)
    return out


def resolve_pointer(schema, pointer):
    """Original node at a nonempty source pointer; no escapes or external references."""
    node = schema
    for part in pointer.lstrip("/").split("/"):
        node = node[int(part)] if isinstance(node, list) else node[part]
    return node


def _source_parts(schema, pointer, node):
    out = [(pointer, node)]
    if "$ref" in node:
        target = node["$ref"].lstrip("#")
        out += _source_parts(schema, target, resolve_pointer(schema, target))
    for key in ("allOf", "oneOf", "anyOf"):
        for i, branch in enumerate(node.get(key, [])):
            out += _source_parts(schema, f"{pointer}/{key}/{i}", branch)
    return out


def _source_child(schema, nodes, key):
    out = []
    for pointer, node in nodes:
        for p, n in _source_parts(schema, pointer, node):
            if isinstance(key, int):
                if isinstance(n.get("items"), dict):
                    out.append((f"{p}/items", n["items"]))
            elif key in n.get("properties", {}):
                out.append((f"{p}/properties/{key}", n["properties"][key]))
            elif isinstance(n.get("additionalProperties"), dict):
                out.append((f"{p}/additionalProperties", n["additionalProperties"]))
    return out


def _expand(schema, nodes):
    return [part for node in nodes for part in _source_parts(schema, *node)]


def sources(schema, path):
    """Ordered original terminal contributions at a concrete string/integer tuple path."""
    nodes = [("", schema)]
    for key in path:
        nodes = _source_child(schema, nodes, key)
    return _expand(schema, nodes)


def generic_sources(schema, path):
    """Coverage-compatible source lookup, including its historical list parser.

    shortcut: splitting at the first '[' discards that bracket, so b[] stays
    at b and b[][] descends once; fix only with a coverage behavior migration.
    Even the empty path performs a named-child lookup, unlike sources(schema, ()).
    """
    nodes = [("", schema)]
    for part in path.split("."):
        name, items = part.split("[", 1) if "[" in part else (part, "")
        nodes = _source_child(schema, nodes, name)
        for _ in range(items.count("[]")):
            nodes = _source_child(schema, nodes, 0)
    return _expand(schema, nodes)
