---
name: global-chart-development
description: Use for any hands-on work on this repo's `global-chart` Helm chart — editing, adding, fixing, refactoring, or testing it. Covers exposing a new Kubernetes field (e.g. priorityClassName, topologySpreadConstraints) on a deployment/cronjob/hook; adding `fail`-based validation for invalid or mutually-exclusive config (e.g. PDB minAvailable + maxUnavailable); refactoring or deduplicating helpers in `_helpers.tpl`/`_job-helpers.tpl`; debugging chart rendering (`enabled: false` ignored, name collisions, misbehaving hooks); fixing failing helm-unittest suites after a `.tpl` change; and touching `values.yaml`, `values.schema.json`, tests, `CHANGELOG`, or `Chart.yaml`. Provides the template+test+schema+version co-change, lint/unit-test/generate workflow, conventional-commit and prove-before-`fix:` discipline, and chart-specific patterns not in CLAUDE.md. Do NOT use for generic Helm/Kubernetes how-to, installing charts, formatting files, or explaining an existing helper without changing it.
---

# Global-Chart Development Patterns

Procedural disciplines and the patterns that are NOT already in `CLAUDE.md`.

> **Core template coding rules live in `CLAUDE.md`** (always loaded): `hasKey` vs
> `default` for bool/numeric, never mutate `.Values`, nil-safe nested access,
> `with`-wrap empty helpers, global fallback chains, multi-deployment iteration,
> schema↔template consistency, resource naming limits. This skill does NOT repeat
> them — it adds the workflow, the commit/fix discipline, and the project-specific
> patterns below.

## Commit Conventions

This project uses **conventional commits**:

| Prefix | Usage |
|--------|-------|
| `feat:` | New features (RBAC, mountedConfigFiles, protocol) |
| `fix:` | Bug fixes (naming, enabled flag, hooks) |
| `chore:` | Maintenance, version bumps, dep updates |
| `chore(deps):` | Renovate dependency updates |
| `refactor:` | Structural changes |

Always include PR number: `feat: add X (#42)`

### Before You Label Something a `fix:` — Prove It's Observable

`fix:` and a CHANGELOG `### Fixed` entry are a promise: a user-reachable input
produced wrong behaviour, and now it doesn't. In a templating engine it's easy to
spot a code smell — two formulas that *look* like they disagree — and reach for
"bug" before checking whether the disagreement is ever reachable. It often isn't:
a name validator that uses one truncation formula for *every* comparison is
internally self-consistent, so its collision verdicts can be correct even if the
formula differs from the template's. The divergence may only exist for inputs
Kubernetes itself rejects (names ending in `-`, etc.).

So before writing `fix:`, demonstrate the bug with a **schema-valid, K8s-valid
input** — ideally a failing test first (red-green). If you can't construct one
(e.g. an exhaustive sweep over realistic release names / deployment names / hook
types finds zero divergent verdicts), it isn't an observable bug: call it what it
is — a `refactor:` that removes a latent inconsistency — and say so plainly in the
CHANGELOG ("the verdict was never wrong for valid input; this removes the
divergence"). Honest, narrow claims age better than a `Fixed` entry that a reader
can't reproduce. The same discipline applies to the regression test: a test that
passes against the *old* code too is locking the shape, not the fix — name it
accordingly, don't dress it up as a bug regression.

## File Co-Change Rules

**Every template change MUST touch these files together:**

1. `charts/global-chart/templates/<resource>.yaml` — the template
2. `charts/global-chart/tests/<resource>_test.yaml` — unit tests
3. `charts/global-chart/Chart.yaml` — version bump (patch for fixes, minor for features)
4. `CLAUDE.md` — update architecture docs if changed (do NOT add fixed counts; CLAUDE.md is kept number-free so it can't drift)

**Version bump also requires:** `charts/global-chart/values.yaml` annotation updates → `make generate-docs`

## Development Workflow

```bash
# After ANY template change, always run in order:
make lint-chart      # Lints all test scenarios
make unit-test       # Runs helm-unittest via Docker
make generate-templates  # Visual inspection
```

Never commit without all three passing.

**Refactor = render-neutral.** When a change is meant to be a pure refactor
(extracting a helper, deduplicating logic), the proof is that the existing
unit-test suite passes **unchanged** — same assertions, same expected strings.
If you have to edit existing test expectations to make them pass, the manifests
moved and it isn't a pure refactor; either that's a real (and intended) behaviour
change you should call out, or a mistake. New tests are fine; *changed* old
expectations are the signal to stop and look.

## Project-Specific Patterns (not in CLAUDE.md)

### Template Validation with `fail`

Use `fail` for invalid configurations instead of silently producing bad manifests:

```yaml
# Mutually exclusive fields
{{- if and (hasKey $pdb "minAvailable") (hasKey $pdb "maxUnavailable") }}
{{- fail (printf "PDB for '%s': minAvailable and maxUnavailable are mutually exclusive" $name) }}
{{- end }}

# Unknown enum values
{{- else }}
{{- fail (printf "unknown type '%s' for volume '%s'" $vol.type $vol.name) }}
{{- end }}
```

### Native Volumes: Deterministic Key Ordering

Go map iteration is randomized. Use `toYaml` with `omit` for native volumes:

```yaml
# ❌ WRONG: nondeterministic, causes noisy diffs
{{- range $key, $value := $vol }}
{{- if ne $key "name" }}
{{ $key }}: {{ toYaml $value | nindent 4 }}
{{- end }}{{- end }}

# ✅ CORRECT: deterministic via toYaml
{{- $native := omit $vol "name" -}}
{{- toYaml $native | nindent 2 }}
```

### Avoid Empty `metadata:` Blocks

Wrapping shared annotation helpers with `{{- with ... }}` indents the body but still emits the parent key. If the helper returns empty, you get a bare `metadata:` line resolving to null. Strict linters (kubeval, polaris) flag this. Wrap the whole metadata block:

```yaml
# ❌ WRONG: emits empty `metadata:` when no annotations
jobTemplate:
  metadata:
    {{- with (include "global-chart.renderCommonAnnotations" $root) }}
    annotations:
      {{- . | nindent 8 }}
    {{- end }}

# ✅ CORRECT: skip the whole block when empty
jobTemplate:
  {{- $jtAnn := include "global-chart.renderCommonAnnotations" $root }}
  {{- if $jtAnn }}
  metadata:
    annotations:
      {{- $jtAnn | nindent 8 }}
  {{- end }}
```

This applies anywhere you'd otherwise emit a parent key with all-optional children.

### Inheritance Opt-Out Toggles (Defensive)

Auto-inheritance of deployment ConfigMap/Secret into deployment-level cronjobs/hooks is convenient, but it widens the secret leak surface for narrow-scope jobs. The chart exposes per-job opt-out flags with default `true`:

```yaml
deployments:
  fast-api:
    secret:
      DB_PASSWORD: "..."
      MAILJET_KEY: "..."
    cronJobs:
      narrow-scope-job:
        schedule: "*/10 * * * *"
        inheritDeploymentSecret: false        # break secret envFrom inheritance
        inheritDeploymentConfigMap: false     # (optional) same for ConfigMap
        envFromSecrets: ["only-this-token"]   # explicit narrow scope
```

The toggle is implemented in `_job-helpers.tpl` by gating `$hasDeploySecret` / `$hasDeployConfigMap` with the boolean — keeps the rest of the inheritance chain (image, SA, dnsConfig, nodeSelector...) intact.

When adding a new inheritable field that could leak sensitive surface, follow this pattern: a `inheritDeployment<Field>` boolean defaulting to `true`, gating only the inheritance branch.

### Schema Integer Minimum Bounds

When a Kubernetes API rejects a value at apply-time, the chart's schema should reject it earlier. Common case: integer fields where 0 is invalid:

```jsonc
// values.schema.json
"completions":  { "type": "integer", "minimum": 1 }   // k8s rejects 0
"backoffLimit": { "type": "integer", "minimum": 0 }   // k8s allows 0
"activeDeadlineSeconds": { "type": "integer", "minimum": 1 }  // 0 nonsensical
```

Always pair a tightened minimum with a `tests/bad-values/` fixture so CI keeps the schema honest.

### Image Registry Detection

`global.imageRegistry` is prepended when the first path segment does NOT look like a registry (no `.`, no `:`, not `localhost`). This means `myorg/myapp` gets the prefix, but `ghcr.io/myorg/myapp` does not.

```yaml
{{- $needsRegistry := true -}}
{{- if contains "/" $image -}}
  {{- $firstSegment := index (splitList "/" $image) 0 -}}
  {{- if or (contains "." $firstSegment) (contains ":" $firstSegment) (eq $firstSegment "localhost") -}}
    {{- $needsRegistry = false -}}
  {{- end -}}
{{- end -}}
```

### One Helper Per Name — Never Recompute a Name Inline

A resource name is computed from a `printf | trunc N | trimSuffix "-"` rule. The
trap: the *same* name often has to be computed in two places — the template that
emits the resource (`cronjob.yaml`, `hook.yaml`) **and** `validateNameCollisions`
in `_validate-helpers.tpl`, which must predict the emitted name to detect
truncation collisions. When both sides inline their own `printf | trunc`, they
drift. They can even reach the *same* string by *different* decompositions — e.g.
`printf "%s-%s-%s-%s" $fullname $dep $hookType $job | trunc 63` versus
`printf "%s-%s-%s" $deployFullname $hookType $job | trunc 63` (the latter
truncates `deployFullname` first, then re-truncates). Those agree for short names
but can diverge at the truncation boundary, so the validator ends up predicting a
name the template never emits.

Give every resource name exactly one home: a named helper in `_helpers.tpl` that
owns the `printf`, the truncation constant, and the `trimSuffix`. Both the
emitting template and the validator call that helper.

```yaml
# ❌ WRONG: same rule typed in cronjob.yaml AND _validate-helpers.tpl
{{- $jobFullname := printf "%s-%s-%s" $fullname $deployName $name | trunc 52 | trimSuffix "-" }}

# ✅ CORRECT: one helper, both sites call it
{{- $jobFullname := include "global-chart.deploymentCronJobName" (dict "root" $root "deploymentName" $deployName "jobName" $name) }}
```

When you add a new named resource, add its name helper first, then call it from
the template and (if it participates in collision detection) the validator.

## Test Structure

- **`tests/`** (root): Value files for lint scenarios (`make lint-chart`)
- **`charts/global-chart/tests/`**: helm-unittest suites (`make unit-test`) — one `*_test.yaml` per template; `make unit-test` prints the live suite/test totals
- **`tests/bad-values/`**: fixtures that MUST be rejected by `values.schema.json` (`make validate-bad-values`)

When adding a new template, always create a corresponding `*_test.yaml`.
When adding a schema constraint that should reject configurations, add a fixture in `tests/bad-values/` so the schema's rejection is locked in by CI.

## Architecture Decisions

1. **Multi-deployment over multi-release**: Single release, multiple deployments with shared ingress
2. **Inheritance over duplication**: Hooks/CronJobs inside deployments inherit image, configMap, secret, SA, nodeSelector, tolerations, affinity
3. **Inheritance asymmetry**: only **deployment-level** hooks/cronjobs (`.Values.deployments.<name>.cronJobs` / `.hooks`) auto-inherit. **Root-level** `.Values.cronJobs` / `.Values.hooks` are standalone — they must reference deployment ConfigMaps/Secrets explicitly via `envFromConfigMaps` / `envFromSecrets` (or `fromDeployment` for image only)
4. **Defensive inheritance opt-out**: `inheritDeploymentSecret` / `inheritDeploymentConfigMap` (default `true`) let narrow-scope jobs avoid pulling the full deployment env bundle
5. **ServiceAccount per deployment by default**: `serviceAccount.create` defaults to `true`
6. **Schema as first line of defense**: every template-accessed field is declared in `values.schema.json`; integer bounds reject obviously-invalid values (e.g. `completions: 0`) before the API server does
7. **Docker-based tooling**: helm-unittest and helm-docs run via Docker, no local plugins needed
8. **No `appVersion`**: generic chart, no app version to pin; `app.kubernetes.io/version` is emitted only when set (consumers add it via `global.commonLabels`)

## New-Field Checklist

When exposing a new Kubernetes spec field on a chart resource, walk through:

1. **Template** (`templates/<resource>.yaml`): use `hasKey`-safe pattern. Guard with `{{- with ... }}` for optional maps/lists; `{{- if hasKey ... }}` for booleans/numbers.
2. **Helper applicability**: if the field is shared between cronjobs and hooks, route it through `_job-helpers.tpl` to avoid PART1/PART2 drift.
3. **Schema** (`values.schema.json`): add the property under the right `$defs` (`deployment`, `cronJob`, `deploymentCronJob`, `hookJob`, `deploymentHookJob`). Apply `minimum`/`enum` if the API server has constraints.
4. **values.yaml**: commented example showing typical use. Run `make generate-docs` after.
5. **Tests** (`charts/global-chart/tests/<resource>_test.yaml`): three cases minimum — field set & rendered, field absent & not rendered, edge value (0, false, empty) rendered correctly.
6. **Bad-values** (`tests/bad-values/`): fixture for any schema constraint you tightened.
7. **CHANGELOG.md** + Chart.yaml version bump (patch for fixes, minor for opt-in features).
8. **CLAUDE.md**: update architecture changes; refresh the Helper Files table if you added one. (No fixed counts — keep it number-free.)
