# Coding standards

How templates and helpers are written in this chart. Read before writing a
template or helper, and in review, where these rules are enforced.

Two kinds of rule:

- **Mechanical**: a fixed pattern, so a check enforces it and the review need
  not. `make lint-templates` (`tests/lint-templates.py`, its docstring lists
  them): `default true` on a boolean, `set` on `.Values`, the shape of a
  `fail` message, a suite per template. `make null-sweep` nulls every values
  node of every scenario. `make e2e-routes` sends every rendered route to a real
  API server. The rules stay written below for their reason; the check is what
  holds them.
- **Judgement**: no pattern can see it — the review's job.

## Template rules

Hard-won. Violating them causes subtle bugs.

**Boolean/numeric fields — never use `default`:**
```yaml
# WRONG: default true $var replaces false with true
enabled: {{ default true $deploy.enabled }}
# CORRECT:
enabled: {{ hasKey $deploy "enabled" | ternary $deploy.enabled true }}
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

**Inheritance — use `hasKey` to distinguish "not set" from "empty":**
```yaml
# WRONG: {} and [] are falsy, incorrectly inherits
{{- if not $job.field }}{{ $deploy.field }}{{- end }}
# CORRECT:
{{ hasKey $job "field" | ternary $job.field $deploy.field }}
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
{{- fail (printf "PDB for deployment '%s': set only one." $name) }}
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

## Judgement rules

**One home per enumeration.** A list of things that more than one template
reads (kinds, fields, ports, hooks, active targets) lives in one helper, and
every reader ranges over it: `l4RouteKinds`, `prereqCopyHooks`,
`servicePorts`, `hpaActiveTargets`. The same `dict "A" … "B" …` or the same
`range` written at two sites is the smell; the third kind added to one site
and not the other is the bug (issue #82 is the port version of it).

**The path names the key that chose.** A `fail` leads with the values path
"as precise as the caller knows it" (the `_validate-helpers.tpl` header): when
one key picked the wrong value among several, the path ends on it
(`….backendRefs[0].portName:` when `portName` picked the port,
`….backendRefs[0]:` when nothing did and the default was taken).

**A guard the schema shadows is a fallback guard.** When the schema already
rejects a value and a template `fail` repeats it, the `fail` is what a user on
`--skip-schema-validation` sees: it gets a `tests/bad-values/skip-schema/`
fixture, and a list the template ranges over takes `default (dict)` on its
entries, so a `null` entry fails naming its path rather than a template line.
`make null-sweep` covers the scenarios; a values node no scenario reaches is
not swept, so a new map or list gets a scenario that sets it.

**A rule the API server enforces is checked against the API server.** A CEL
rule of a CRD (Gateway API's `RequestRedirect` without `backendRefs`) is
invisible to helm-unittest and kubeconform. When the chart renders a new route
kind, or a new combination of route fields, a `TEST_CASES` scenario renders it
(`make e2e-routes` sends every scenario carrying a route) and a new kind joins
`GATEWAY_ROUTE_KINDS`; when the chart can tell the combination is invalid at
render time, it fails there too, naming the key.
