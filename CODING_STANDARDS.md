# Coding standards

How templates and helpers are written in this chart. Read before writing a
template or helper, and in review, where these rules are enforced.

Two kinds of rule:

- **Mechanical**: a fixed pattern, so a check enforces it and the review need
  not. `make lint-templates` (`tests/lint-templates.py`, its docstring lists
  them): `default true` on a boolean, `set` on `.Values`, the shape of a
  `fail` message, a suite per template. `make null-sweep` nulls every values
  node of every scenario, then gives each map and list the wrong type, and
  holds `valuesShape` to the schema's types. `make e2e-dryrun` sends every
  scenario to a real API server. `lint-templates`' kind-fields rule holds the backstop guard's
  `$kindOnly` to the schema's `if/then/else` on `kind`, and its workload-kind
  rule keeps a quoted kind (`"Deployment"`) in `workloadKind`, `isStatefulSet`
  and `$kindOnly`. `make lint-glossary` keeps out the phrases GLOSSARY.md
  avoids with one reading only. The rules stay written
  below for their reason; the check is what holds them.
- **Judgement**: no pattern can see it — the review's job.

## Template rules

Hard-won. Violating them causes subtle bugs.

**Boolean/numeric fields — never use `default`:**
```yaml
# WRONG: default true $var replaces false with true
enabled: {{ default true $deploy.enabled }}
# CORRECT: isSet is "present and not null" — a null is unset, the default applies
enabled: {{ ternary $deploy.enabled true (eq (include "global-chart.isSet" (list $deploy "enabled")) "true") }}
```

**Numbers from values — never print them bare, never `toString` / `%v` them:**
```yaml
# WRONG: a values-file number is a float64; 10000000 renders as 1e+07
terminationGracePeriodSeconds: {{ $deploy.terminationGracePeriodSeconds }}
LIMIT: {{ toString $value | quote }}
# CORRECT: whole numbers print as digits, 1.5 stays 1.5, strings pass through
terminationGracePeriodSeconds: {{ include "global-chart.printScalar" $deploy.terminationGracePeriodSeconds }}
LIMIT: {{ include "global-chart.printScalar" $value | quote }}
```
A number that went through `toJson | fromJson` is a float64 too, whatever
`--set` made of it: a guard on `kindIs "float64"` after `fromJson` sees every
number (the `_render-helpers.tpl` header).

**Inheritance — use `isSet` to distinguish "not set" from "empty":**
```yaml
# WRONG: {} and [] are falsy, incorrectly inherits
{{- if not $job.field }}{{ $deploy.field }}{{- end }}
# WRONG: hasKey takes a null for a value, and the job inherits nothing
{{ hasKey $job "field" | ternary $job.field $deploy.field }}
# CORRECT: {} and [] stop the inheritance, a null inherits
{{ ternary $job.field $deploy.field (eq (include "global-chart.isSet" (list $job "field")) "true") }}
```

**Never mutate `.Values`:**
```yaml
# WRONG:
{{- $_ := set $ing.annotations "key" "value" }}
# CORRECT:
{{- $annotations := deepCopy $ing.annotations }}
```

**Nil-safe nested access:**
```yaml
{{- $service := default (dict) $deploy.service }}
```

**Shared helpers that can return empty — wrap with `{{- with }}`:**
```yaml
{{- with (include "global-chart.renderFoo" $arg) }}{{- . | nindent N }}{{- end }}
```

**Shared helpers — use `-}}` trim before literal content:**
```yaml
{{- with . -}}
imagePullSecrets:
```

**Schema ↔ Template consistency:**
- Every field a template accesses must be declared in the schema
- Every schema field must be used by a template
- Run `make lint-chart` to verify the schema doesn't reject valid test values

**Error messages — `<values path>: <problem>`:**
```yaml
# WRONG: the entry named in prose, the path printed by hand
{{- fail (printf "PDB for workload '%s': set only one." $name) }}
# CORRECT: the path of the key holding the wrong value leads, from its single home
{{- fail (printf "%s.pdb: set only one." (include "global-chart.deploymentValuesPath" $name)) }}
```
The rule, where each path comes from, its two exceptions and the form a null
takes live in the `_validate-helpers.tpl` header (issues #190, #191): read it
before writing a `fail`. `make lint-templates` checks the shape.

**Adding a new helper:** place it in the appropriate domain file, not
`_helpers.tpl`, and give it a header comment carrying its rules — that header is
where the next reader looks

**Adding `merge` on `.Values` maps:** always `deepCopy` the first argument

**Adding a hook role:** add a row to the table in `hookAnnotations`
(`_hook-helpers.tpl`), never a new weight or delete-policy derivation at the call
site. The row is the enforcement: the two `fail` guards beside it exist because a
missing row renders a null annotation instead of stopping

**Every template must have a corresponding `*_test.yaml`** in
`charts/global-chart/tests/`

## Check scripts (`tests/*.py`)

A check reports every problem as a `    FAIL: <where>: <what>` line and exits 1,
and a pass as one `    OK:` line. Input it cannot read (a format that moved, a
tool that is missing or unauthenticated) is a FAIL naming what it expected,
never a traceback: a crash reads as a bug in the check, not as the finding.
A check proves it can fail: a probe or a fixture makes it go red once. A known
limit carries `shortcut: <the limit>, <when to upgrade>`. `make lint-shell`
holds the shell side: a value piped onward goes through `printf '%s\n'`.

## Judgement rules

**One home per enumeration.** A list of things that more than one template
reads (kinds, fields, ports, hooks, active targets) lives in one helper, and
every reader ranges over it: `l4RouteKinds`, `prereqCopyHooks`,
`servicePorts`, `hpaActiveTargets`. The same `dict "A" … "B" …` or the same
`range` written at two sites is the smell; the third kind added to one site
and not the other is the bug (issue #82 is the port version of it).

**Text names a kind only where it holds for that kind alone.** A `fail`
message, a schema description, NOTES or a comment that holds for every kind of
a `workloads` entry says *workload* (GLOSSARY); *Deployment* or
*StatefulSet* only where the text is true of that kind alone (`strategy`, the
headless Service). The kind in a message comes from `workloadKind`. The
helper names (`deploymentFullname`) and the schema `$defs` names keep theirs:
they are not part of the values API (ADR 0023).

**A rule that holds for every kind is tested on every kind.** A check or a
render path that reads a `workloads` entry whatever its kind gets a suite
case with `kind: StatefulSet` beside the Deployment one: the kind changes the
template's branches, and a rule tested on one kind alone is assumed on the other
(issue #216).

**The path names the key that chose.** A `fail` leads with the values path
"as precise as the caller knows it" (the `_validate-helpers.tpl` header): when
one key picked the wrong value among several, the path ends on it
(`….backendRefs[0].portName:` when `portName` picked the port,
`….backendRefs[0]:` when nothing did and the default was taken).

**A guard the schema shadows is a fallback guard.** When the schema already
rejects a value and a template `fail` repeats it, the `fail` is what a user on
`--skip-schema-validation` sees, and it gets a `tests/bad-values/skip-schema/`
fixture. `make null-sweep` covers the scenarios; a values node no scenario
reaches is not swept, so a new map or list gets a scenario that sets it. A
map or list a template reads goes in `valuesShape` (`_validate-helpers.tpl`),
and the sweep's type pass fails a raw error on one it misses (issue #235).

**A null means one thing per kind of node** (issue #198):

- a null **map value** is unset, as Helm itself reads it: a key the chart
  defaults takes its default (`enabled`, `create`, the `inherit*` toggles, a
  job's inherited fields, the enums with a default), a map entry
  (`httpRoutes.x`, like `workloads.x`) renders nothing. "Set" has one home,
  `isSet`; `hasKey` alone hands the null on. Numbers are the exception: a null
  number fails naming its key, through `printScalar` (issue #191);
- a null **list item** fails, anywhere, passthrough lists included:
  `rejectNullInLists`, run over all of `.Values` by `validateNullItems`;
- a null in a **required field** of an item the chart reads fails:
  `rejectNullItems` with its `required` fields — in `validateNullItems` for
  the lists more than one template reads, in the template itself for a list
  only it reads.

A helper reading such a list skips the item it cannot read
(`isNamedEntry`, `kindIs "map"`) instead of reading through it: the error is
then the validator's, whatever order Helm renders the templates in.

**A validator's `fail` is tested in the suite of `validate/validate.yaml`.**
A helm-unittest suite renders only the templates its `templates:` lists, so a
`failedTemplate` case in `workload_test.yaml` never sees a check that runs in
`validate/validate.yaml`: the case passes or fails on something else. A check
moved from a template into a validator takes its cases to `validate_test.yaml`
(issue #221 moved them twice).

**A rule the API server enforces is checked against the API server.** A CEL
rule of a CRD (Gateway API's `RequestRedirect` without `backendRefs`) is
invisible to helm-unittest and kubeconform, and so is a rule between fields of
a core kind (a StatefulSet's `rollingUpdate` with `OnDelete`, two pod volumes
of one name). When the chart renders a new kind, or a new combination of
fields, a `TEST_CASES` scenario renders it (`make e2e-dryrun` sends every
scenario) and a new route kind joins `GATEWAY_ROUTE_KINDS`; when the chart can
tell the combination is invalid at render time, it fails there too, naming the
key.

**A key is deprecated for a minor, then removed in a major with a `fail`
naming its replacement** (ADR 0022, issue #205). The rule covers the keys and
formats a values author writes; a new `fail` on values that never worked, or
a raised version floor, is a Breaking change with a migration guide and no
deprecation. Skipping phase 1 takes an ADR of its own (ADR 0023).

1. **Deprecated**, for at least one released minor: the key keeps working.
   `NOTES.txt` lists every values path that uses it and names the
   replacement; the schema description of the key, or of the surface
   declaring it, says `deprecated, removed in X.0.0, issue #N`; the CHANGELOG
   lists it under *Deprecated* with an **Action:**.
2. **Removed** in the major: a template `fail`, leading with the path of the
   removed key itself: `<values path>: removed in X.0.0, use <replacement>`.
   When the replacement does not fit one line, the message names it and links
   the release's *Migration guide* in `CHANGELOG.md`, built from
   `.Chart.Home`. The schema keeps the key declared with no constraint, only a
   description saying `removed in X.0.0, issue #N`, where `#N` is the
   deprecation issue, as in phase 1: a schema rejection prints the path but
   never the replacement, so any value, of any type, must reach the `fail`.
   The `NOTES.txt` warning and the deprecation wording go, and so does every
   other mention of the key as current: README, `values.yaml`, `GLOSSARY.md`,
   and an ADR, amended inline (`*Amended by issue #N:*`). A
   `tests/bad-values/fail/` fixture asserts the message.
3. **Gone** at the next major: the `fail`, the schema declaration and the
   fixture go together.
