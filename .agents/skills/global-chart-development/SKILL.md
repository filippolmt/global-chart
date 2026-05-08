---
name: global-chart-development
description: Use when modifying global-chart Helm templates, adding features, fixing bugs, or updating values. Covers hasKey vs truthiness pitfalls, global fallback chains, inheritance logic (with defensive opt-out toggles), validation with fail, deterministic rendering, schema integer bounds, empty metadata block pitfall, and the required lint-test-generate workflow.
---

# Global-Chart Development Patterns

Coding patterns extracted from the global-chart repository (Feb 2025 – May 2026, chart v1.5.0).

## Commit Conventions

This project uses **conventional commits** (~65% adoption):

| Prefix | Usage |
|--------|-------|
| `feat:` | New features (RBAC, mountedConfigFiles, protocol) |
| `fix:` | Bug fixes (naming, enabled flag, hooks) |
| `chore:` | Maintenance, version bumps, dep updates |
| `chore(deps):` | Renovate dependency updates |
| `refactor:` | Structural changes |

Always include PR number: `feat: add X (#42)`

## File Co-Change Rules

**Every template change MUST touch these files together:**

1. `charts/global-chart/templates/<resource>.yaml` — the template
2. `charts/global-chart/tests/<resource>_test.yaml` — unit tests
3. `charts/global-chart/Chart.yaml` — version bump (patch for fixes, minor for features)
4. `CLAUDE.md` — update test count, architecture docs if changed

**Version bump also requires:** `charts/global-chart/values.yaml` annotation updates → `make generate-docs`

## Development Workflow

```bash
# After ANY template change, always run in order:
make lint-chart      # Lints all test scenarios
make unit-test       # Runs helm-unittest via Docker
make generate-templates  # Visual inspection
```

Never commit without all three passing.

## Helm Template Gotchas (Project-Specific)

### Boolean Fields: Never Use `default`

Go templates treat `false` as falsy. `default true .field` replaces `false` with `true`.

```yaml
# ❌ WRONG: loses explicit false
enabled: {{ default true $deploy.enabled }}

# ✅ CORRECT: preserves false
enabled: {{ hasKey $deploy "enabled" | ternary $deploy.enabled true }}
```

Use the centralized helper when available:
```yaml
{{- if eq (include "global-chart.deploymentEnabled" (dict "deploy" $deploy)) "true" }}
```

### Never Mutate .Values

```yaml
# ❌ WRONG: mutates shared state
{{- $_ := set $ing.annotations "key" "value" }}

# ✅ CORRECT: work on a copy
{{- $annotations := deepCopy $ing.annotations }}
{{- $_ := set $annotations "key" "value" }}
```

### Inheritance: Use hasKey to Distinguish "Not Set" from "Empty"

For hooks/cronjobs inside deployments that inherit from parent:

```yaml
# ❌ WRONG: treats {} and [] as falsy, incorrectly inherits
{{- if not $job.field }}{{ $deploy.field }}{{- end }}

# ✅ CORRECT: only inherits when field is truly absent
{{ hasKey $job "field" | ternary $job.field $deploy.field }}
```

### Global Fallback Chains: hasKey at Every Level

When falling back through job → deployment → global (e.g., imagePullSecrets), use `hasKey` at each level. An explicit empty list (`imagePullSecrets: []`) must stop the fallback — it means "no pull secrets", not "unset".

```yaml
# ❌ WRONG: [] is falsy, falls through to global
{{- $imagePullSecrets := $job.imagePullSecrets -}}
{{- if not $imagePullSecrets -}}
  {{- $imagePullSecrets = $global.imagePullSecrets -}}
{{- end -}}

# ✅ CORRECT: hasKey at each level
{{- $imagePullSecrets := list -}}
{{- if hasKey $job "imagePullSecrets" -}}
  {{- $imagePullSecrets = $job.imagePullSecrets -}}
{{- else if hasKey $deploy "imagePullSecrets" -}}
  {{- $imagePullSecrets = $deploy.imagePullSecrets -}}
{{- else -}}
  {{- $imagePullSecrets = $global.imagePullSecrets -}}
{{- end -}}
```

### Numeric Fields: Never Use Truthiness

Go templates treat `0` as falsy. For fields like PDB `minAvailable`/`maxUnavailable`, use `hasKey`:

```yaml
# ❌ WRONG: 0 is falsy, won't render
{{- if $pdb.minAvailable }}
minAvailable: {{ $pdb.minAvailable }}
{{- end }}

# ✅ CORRECT: hasKey preserves 0
{{- if hasKey $pdb "minAvailable" }}
minAvailable: {{ $pdb.minAvailable }}
{{- end }}
```

### Template Validation with fail

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

### Nil-Safe Nested Access

```yaml
# ❌ WRONG: nil pointer if parent missing
{{ $deploy.service.port }}

# ✅ CORRECT: safe default
{{- $service := default (dict) $deploy.service }}
{{ $service.port }}
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

## Multi-Deployment Iteration Pattern

All resource templates iterate over the deployments map:

```yaml
{{- range $name, $deploy := .Values.deployments }}
{{- if eq (include "global-chart.deploymentEnabled" (dict "deploy" $deploy)) "true" }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "global-chart.deploymentFullname" (dict "root" $ "name" $name) }}
  labels:
    {{- include "global-chart.labels" $ | nindent 4 }}
    app.kubernetes.io/component: {{ $name }}
# ... template body ...
{{- end }}
{{- end }}
```

Key points:
- `$name` = deployment key (frontend, backend, worker)
- `$deploy` = deployment config map
- Always pass `$` (root context) to helpers, not `.`
- `app.kubernetes.io/component` ensures unique selectors per deployment

## Resource Naming Limits

| Resource | Max Chars | Why |
|----------|-----------|-----|
| Most resources | 63 | Kubernetes label limit |
| CronJobs | **52** | K8s appends 11-char timestamp to Job names |

## Test Structure

- **`tests/`** (root): Value files for lint scenarios (`make lint-chart`)
- **`charts/global-chart/tests/`**: helm-unittest suites (`make unit-test`)
- **`tests/bad-values/`**: fixtures that MUST be rejected by `values.schema.json` (`make validate-bad-values`)
- Current: **17 suites, 331 tests**

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

## New-Field Checklist

When exposing a new Kubernetes spec field on a chart resource, walk through:

1. **Template** (`templates/<resource>.yaml`): use `hasKey`-safe pattern. Guard with `{{- with ... }}` for optional maps/lists; `{{- if hasKey ... }}` for booleans/numbers.
2. **Helper applicability**: if the field is shared between cronjobs and hooks, route it through `_job-helpers.tpl` to avoid PART1/PART2 drift.
3. **Schema** (`values.schema.json`): add the property under the right `$defs` (`deployment`, `cronJob`, `deploymentCronJob`, `hookJob`, `deploymentHookJob`). Apply `minimum`/`enum` if the API server has constraints.
4. **values.yaml**: commented example showing typical use. Run `make generate-docs` after.
5. **Tests** (`charts/global-chart/tests/<resource>_test.yaml`): three cases minimum — field set & rendered, field absent & not rendered, edge value (0, false, empty) rendered correctly.
6. **Bad-values** (`tests/bad-values/`): fixture for any schema constraint you tightened.
7. **CHANGELOG.md** + Chart.yaml version bump (patch for fixes, minor for opt-in features).
8. **CLAUDE.md**: update test count and any architecture changes; refresh the Helper Files table if you added one.
