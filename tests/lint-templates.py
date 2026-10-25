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
  it (`$d := index .Values.workloads $n`, `range $k, $d := .Values.x`, and
  anything bound from such a variable, within one define). A variable bound
  through `deepCopy` is a copy, and so is one built by `dict`, `list`,
  `append`, `include` or `fromJson`.
- fail-shape: a `fail` message leads with the values path of the wrong key, or
  with one of the two documented exceptions. The shape and the exceptions are
  the _validate-helpers.tpl header's (issue #190), mirrored by FAIL_SHAPE below:
  change both. A path is `%s` followed by `.`, `[` or `:` (a path from its
  single home), or a top-level values key of values.schema.json followed by
  `.`, `[` or `: `. A helper's own invariant leads with a helper the chart
  defines, then `: `. A message that is not a literal (`fail $msg`,
  `fail (print …)`) cannot be checked and is reported as such.
- template-suite: every template has a `tests/<name>_test.yaml` suite
  (`notes_test.yaml` for NOTES.txt), and every file in `tests/` but
  `__snapshot__/` is a `*_test.yaml` suite: helm-unittest skips any other name
  without a word, so a misnamed suite (`pdb_tests.yaml`) never runs.
- every-kind: a template that reads a `workloads` entry is rendered with
  `kind: StatefulSet` by one suite case at least, as CODING_STANDARDS.md asks
  of a rule that holds for every kind. The pattern sees the template, not the
  rule: which of its paths hold for every kind stays the review's call. The
  hooks and cronjobs of a StatefulSet went untested until issue #262.
- kind-fields: the backstop guard's `$kindOnly` in workload.yaml lists, per
  kind, the fields the other kind rejects, and the `if/then/else` on `kind` of
  `$defs/deployment` rejects the same ones with `false` (ADR 0020). The two are
  one partition written twice, the guard being what --skip-schema-validation
  leaves: a field added to one and not the other is the bug.
- workload-kind: a quoted kind of a workload ("Deployment", "StatefulSet",
  "DaemonSet") appears only in its homes: the workloadKind and isStatefulSet
  defines and the `$kindOnly` map. Anywhere else it is a kind written by hand,
  which holds for one kind and is wrong for the others: validateNameCollisions
  named every entry "Deployment" until issue #217. Read the kind from
  global-chart.workloadKind.
- chart-home: the `home` URL of Chart.yaml is never written in a template: a
  link (the migration guide a removal `fail` names, NOTES) reads `.Chart.Home`,
  so it follows Chart.yaml. A helper called with a dict gets the link from the
  caller's root (validateRemovedKeys passes it as `see`, issue #221).
- render-order: templates/validate/validate.yaml is the first template Helm
  renders. Helm sorts by depth, deepest first, then in reverse lexical order
  (sortTemplates in pkg/engine), and stops at the first error. A helper that
  skips what a validator rejects needs no order (CODING_STANDARDS.md); one
  that reads through it does, and the deployment.yaml -> workload.yaml rename
  of issue #221 surfaced about fifteen: renamed ahead of the validators, each
  crashed with no values path. This keeps the validators first while such a
  helper exists. Partials (`_*`) render nothing and are left out.
- read-only-by: a helper header that says "Read only by A, B and C." names
  exactly the defines and templates that include the helper, itself aside (a
  recursion). The exhaustive form is the one checked: a "read by" in prose
  may name some readers only. A reader added to a helper whose header claims
  the full list is a stale header the reviews found by hand (issue #248).
- errctx: a helper that demands its caller's values path (`required
  "<helper>: errCtx is required …" .errCtx`) gets it from every caller that
  builds its argument with `(dict …)`: a call missing it renders while the
  branch is never taken and dies with the helper's own message, not the user's
  key, the day it is (a printScalar in a min>max fail, issue #226). An
  argument built elsewhere (`$ctx`) is the builder's to check.
- quoted-name: a print that is the whole value of a `name` or `*Name` key
  (`serviceAccountName`, `secretName`…), an `appProtocol`, `path` or
  `app.kubernetes.io/*` key ends in `| quote`. Kubernetes parses the rendered
  YAML, so a valid DNS name that YAML reads as another type (`0`, `1e3`,
  `true`, `on`) reaches the API server as a number or a boolean, and the apply
  fails (issue #251). Every such print is quoted, generated names too: whether
  a name can be user-written is not a pattern.

Comments (`{{/* … */}}`) are stripped before matching, so a rule may be named in
prose. Matching runs over the whole file, so an expression split across lines
is seen whole.

Usage: lint-templates.py <chart dir>
"""
import json
import pathlib
import re
import sys

NAME_PRINT = re.compile(r"^\s*(?:- )?(?:name|\w+Name|appProtocol|path|app\.kubernetes\.io/[\w-]+):\s*\{\{-?(.*?)-?\}\}\s*$", re.M)
COMMENT = re.compile(r"\{\{-?\s*/\*.*?\*/\s*-?\}\}", re.S)
DEFAULT_TRUE = re.compile(r"\bdefault\s+true\s+[$.(]|\|\s*default\s+true\b")
SET_TARGET = re.compile(r"\bset\s+(\$[\w]+|\.Values\b|\$\.Values\b|\$root\.Values\b)")
BIND = re.compile(r"(\$\w+)\s*:?=\s*([^}]*?)\s*-?\}\}")
RANGE_BIND = re.compile(r"\brange\s+(?:\$\w+\s*,\s*)?(\$\w+)\s*:=\s*([^}]*?)\s*-?\}\}")
COPY = re.compile(r"^\(?\s*(deepCopy|dict|list|append|include|fromJson|fromJsonArray|toJson|printf|print|len|keys)\b")
DEFINE = re.compile(r"\{\{-?\s*define\s")
FAIL = re.compile(r"\bfail\s+(\(\s*printf\s+\"|\")((?:[^\"\\]|\\.)*)\"", re.S)
FAIL_ANY = re.compile(r"\bfail\s+(?!\(\s*printf\s+\"|\")(\S+)")
EXCEPTIONS = ("Name collision: ", "The fullname ", "Both .Values.ingress")
KIND_ONLY = re.compile(r'\$kindOnly\s*:=\s*dict\s+(.*?)\}\}', re.S)
KIND_LIST = re.compile(r'"(\w+)"\s*\(list\s+([^)]*)\)')
WORKLOAD_KIND = re.compile(r'"(Deployment|StatefulSet|DaemonSet)"')
KIND_HOMES = {"global-chart.workloadKind", "global-chart.isStatefulSet"}
DEFINE_NAME = re.compile(r'\{\{-?\s*define\s+"([^"]+)"')
INCLUDE = re.compile(r'\b(?:include|template)\s+"global-chart\.([\w-]+)"')
READ_ONLY_BY = re.compile(r"\bRead only by\s+(.*?)\.(?:\s|$)", re.S)
ERRCTX_HELPER = re.compile(r'required\s+"([\w-]+): errCtx is required')
DICT_CALL = re.compile(r'\b(?:include|template)\s+"global-chart\.([\w-]+)"\s+\(dict\b')
HEADER_BEFORE = re.compile(r'\{\{-?\s*/\*((?:(?!\*/).)*)\*/\s*-?\}\}\s*$', re.S)


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


def kind_fields(chart, schema):
    """The kind-fields rule. shortcut: reads one if/then/else, which holds two
    kinds; the DaemonSet (issue #215) turns it into one branch per kind."""
    text = blank_comments((chart / "templates" / "workload.yaml").read_text())
    m = KIND_ONLY.search(text)
    if not m:
        return ["templates/workload.yaml: kind-fields: no `$kindOnly := dict …` to compare with the schema"]
    guard = {kind: set(re.findall(r'"(\w+)"', fields)) for kind, fields in KIND_LIST.findall(m.group(1))}
    dep = schema["$defs"]["deployment"]

    def rejected(branch):
        return {k for k, v in dep.get(branch, {}).get("properties", {}).items() if v is False}

    kind = dep.get("if", {}).get("properties", {}).get("kind", {}).get("const")
    if kind is None:
        return ["values.schema.json: kind-fields: $defs/deployment has no if/then/else on kind to compare with $kindOnly"]
    other = next((k for k in guard if k != kind), None)
    if other is None or len(guard) != 2:
        return [f"templates/workload.yaml: kind-fields: $kindOnly must name two kinds, one of them {kind}; read {sorted(guard)}"]
    schema_side = {other: rejected("then"), kind: rejected("else")}
    problems = []
    for k in sorted(set(guard) | set(schema_side)):
        if guard.get(k, set()) != schema_side.get(k, set()):
            problems.append(f"templates/workload.yaml: kind-fields: {k}-only fields differ: $kindOnly {sorted(guard.get(k, set()))}, schema {sorted(schema_side.get(k, set()))}")
    return problems


def define_at(starts, pos, default):
    """The define a position sits in, from starts = [(offset, name)] in file order; default outside any."""
    return next((name for start, name in reversed(starts) if start < pos), default)


def workload_kind(chart):
    """The workload-kind rule."""
    problems = []
    for path in sorted((chart / "templates").rglob("*")):
        if path.suffix not in {".yaml", ".tpl", ".txt"}:
            continue
        text = blank_comments(path.read_text())
        homes = [m.span() for m in KIND_ONLY.finditer(text)]
        starts = [(m.start(), m.group(1)) for m in DEFINE_NAME.finditer(text)]
        for m in WORKLOAD_KIND.finditer(text):
            define = define_at(starts, m.start(), None)
            if define in KIND_HOMES or any(a <= m.start() < b for a, b in homes):
                continue
            problems.append(f"{path.relative_to(chart)}:{lineno(text, m.start())}: workload-kind: {m.group(0)} written by hand; read the kind from global-chart.workloadKind")
    return problems


def render_order(chart):
    """The render-order rule."""
    names = sorted((str(p.relative_to(chart.parent)) for p in (chart / "templates").rglob("*")
                    if p.is_file() and not p.name.startswith("_")),
                   key=lambda n: (n.count("/"), n), reverse=True)
    first = f"{chart.name}/templates/validate/validate.yaml"
    if not names or names[0] != first:
        return [f"templates: render-order: Helm renders {names[0] if names else 'nothing'} first, not {first}; move it so the validators run before every template"]
    return []


def read_only_by(chart):
    """The read-only-by rule.
    shortcut: an include whose name is built at render time (`include $name`) is
    not seen, and only the comment right before a define is its header; widen
    both when a "Read only by" helper is reached that way."""
    readers, claims, defines, files = {}, [], set(), set()
    for path in sorted((chart / "templates").rglob("*")):
        if path.suffix not in {".yaml", ".tpl", ".txt"}:
            continue
        files.add(path.name)
        raw = path.read_text()
        text = blank_comments(raw)
        defines |= {m.group(1).removeprefix("global-chart.") for m in DEFINE_NAME.finditer(text)}
        starts = [(m.start(), m.group(1).removeprefix("global-chart.")) for m in DEFINE_NAME.finditer(text)]
        for m in INCLUDE.finditer(text):
            reader = define_at(starts, m.start(), path.name)
            if reader != m.group(1):
                readers.setdefault(m.group(1), set()).add(reader)
        for m in DEFINE_NAME.finditer(raw):
            header = HEADER_BEFORE.search(raw, 0, m.start())
            for c in READ_ONLY_BY.finditer(header.group(1) if header else ""):
                claims.append((path, lineno(raw, m.start()), m.group(1).removeprefix("global-chart."), c.group(1)))
    problems = []
    for path, line, name, claim in claims:
        # A name is a camelCase word (a define) or a template file; the rest is prose
        named = set(re.findall(r"\b[a-z]+[A-Z]\w*\b|[\w-]+\.(?:yaml|txt)\b", claim))
        for unknown in sorted(named - defines - files):
            problems.append(f"{path.relative_to(chart)}:{line}: read-only-by: {name}'s header names {unknown}, "
                            "which is no define or template of the chart")
        actual = readers.get(name, set())
        if named & (defines | files) != actual:
            problems.append(f"{path.relative_to(chart)}:{line}: read-only-by: {name}'s header names {sorted(named)}, "
                            f"its readers are {sorted(actual)}; list exactly the readers")
    return problems


def errctx(chart):
    """Every (dict …) call of a helper that requires errCtx, with no "errCtx" key at the dict's top level."""
    texts = {p: blank_comments(p.read_text()) for p in sorted((chart / "templates").rglob("*")) if p.is_file()}
    needs = {name for t in texts.values() for name in ERRCTX_HELPER.findall(t)}
    if not needs:
        return ["errctx: no helper requires errCtx any more; the rule reads nothing: update or drop it"]
    out = []
    for path, text in texts.items():
        for m in DICT_CALL.finditer(text):
            if m.group(1) not in needs:
                continue
            # The dict's own keys sit at paren depth 1; a nested (dict …) passing errCtx onward is not this call's
            depth, i, top = 1, m.end(), []
            while depth and i < len(text):
                depth += {"(": 1, ")": -1}.get(text[i], 0)
                top.append(text[i] if depth == 1 else " ")
                i += 1
            if '"errCtx"' not in "".join(top):
                out.append(f"{path.relative_to(chart)}:{lineno(text, m.start())}: errctx: {m.group(1)} requires errCtx, "
                           "and this (dict …) call passes none")
    return out


def every_kind(chart):
    """Each template reading a `workloads` entry, with no suite case setting kind: StatefulSet."""
    suites = {}
    for path in (chart / "tests").glob("*_test.yaml"):
        text = path.read_text()
        listed = re.search(r"^templates:\n((?:\s+-\s+\S+\n)+)", text, re.M)
        sts = re.search(r"^\s*kind:\s*[\"']?StatefulSet[\"']?\s*$", text, re.M) is not None
        for t in re.findall(r"-\s+(\S+)", listed.group(1)) if listed else []:
            suites[t] = suites.get(t, False) or sts
    problems = []
    for path in sorted((chart / "templates").rglob("*")):
        if path.suffix not in {".yaml", ".txt"} or path.name.startswith("_"):
            continue
        rel = path.relative_to(chart).as_posix()
        if "workloads" in blank_comments(path.read_text()) and not suites.get(rel, False):
            problems.append(f"{rel}: every-kind: reads a workloads entry, and no suite case renders it with kind: StatefulSet")
    return problems


def main(chart):
    chart = pathlib.Path(chart)
    templates = chart / "templates"
    schema = json.loads((chart / "values.schema.json").read_text())
    top_keys = set(schema.get("properties", {}))
    helpers = set()
    for path in templates.rglob("*.tpl"):
        helpers |= set(re.findall(r'define\s+"global-chart\.([\w-]+)"', path.read_text()))
    home = re.search(r"^home:\s*(\S+)", (chart / "Chart.yaml").read_text(), re.M)
    if not home:
        print("    FAIL: Chart.yaml carries no `home:`, the URL the chart-home rule keeps out of the templates")
        sys.exit(1)
    home = home.group(1)
    problems = []
    for path in sorted(templates.rglob("*")):
        if path.suffix not in {".yaml", ".tpl", ".txt"}:
            continue
        text = blank_comments(path.read_text())
        rel = path.relative_to(chart)
        for m in DEFAULT_TRUE.finditer(text):
            problems.append(f"{rel}:{lineno(text, m.start())}: default-true: {m.group(0).strip()}")
        # A variable lives in its define (or the file's top level): aliases are
        # computed per block, so two blocks reusing $out do not mix
        starts = [0] + [m.start() for m in DEFINE.finditer(text)] + [len(text)]
        for a, b in zip(starts, starts[1:]):
            block = text[a:b]
            aliases = values_aliases(block)
            for m in SET_TARGET.finditer(block):
                target = m.group(1)
                if "Values" in target or target in aliases:
                    problems.append(f"{rel}:{lineno(text, a + m.start())}: values-mutation: set on {target}, bound to .Values; work on a deepCopy")
        for m in FAIL.finditer(text):
            if not fail_shape(m.group(2), top_keys, helpers):
                problems.append(f"{rel}:{lineno(text, m.start())}: fail-shape: \"{m.group(2)[:60]}\" leads with neither a values path nor a documented exception")
        for m in FAIL_ANY.finditer(text):
            problems.append(f"{rel}:{lineno(text, m.start())}: fail-shape: the message ({m.group(1)[:40]}) is not a literal and cannot be checked; write it as fail \"…\" or fail (printf \"…\" …)")
        for m in NAME_PRINT.finditer(text):
            if not re.search(r"\|\s*quote\s*$", m.group(1)):
                problems.append(f"{rel}:{lineno(text, m.start())}: quoted-name: {m.group(0).strip()} prints a name unquoted; end the print in | quote")
        if home in text:
            problems.append(f"{rel}:{lineno(text, text.index(home))}: chart-home: {home} written by hand; read .Chart.Home")
        if path.suffix != ".tpl":
            name = "notes" if path.name == "NOTES.txt" else path.stem
            if not (chart / "tests" / f"{name}_test.yaml").exists():
                problems.append(f"{rel}: template-suite: no tests/{name}_test.yaml")
    for path in sorted((chart / "tests").iterdir()):
        if path.name != "__snapshot__" and not path.name.endswith("_test.yaml"):
            problems.append(f"{path.relative_to(chart)}: template-suite: not a *_test.yaml suite, so helm-unittest never runs it")
    problems += every_kind(chart)
    problems += kind_fields(chart, schema)
    problems += workload_kind(chart)
    problems += render_order(chart)
    problems += read_only_by(chart)
    problems += errctx(chart)
    if problems:
        print("    FAIL: templates break a mechanical rule of CODING_STANDARDS.md:")
        for p in problems:
            print(f"          - {p}")
        sys.exit(1)
    print("    OK: templates follow the mechanical rules of CODING_STANDARDS.md")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__.rsplit("Usage: ", 1)[1])
    try:
        main(sys.argv[1])
    except (OSError, json.JSONDecodeError) as e:
        print(f"    FAIL: cannot read the chart's templates, values.schema.json or Chart.yaml: {e}")
        sys.exit(1)
