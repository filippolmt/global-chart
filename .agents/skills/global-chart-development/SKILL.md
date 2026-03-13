---
name: global-chart-development
description: Use when modifying global-chart Helm templates, adding features, fixing bugs, or updating values. Covers multi-deployment iteration patterns, boolean field handling, inheritance logic, and the required lint-test-generate workflow.
---

# Global-Chart Development Patterns

Coding patterns extracted from the global-chart repository (51 commits, Feb 2025 – Mar 2026).

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

### Nil-Safe Nested Access

```yaml
# ❌ WRONG: nil pointer if parent missing
{{ $deploy.service.port }}

# ✅ CORRECT: safe default
{{- $service := default (dict) $deploy.service }}
{{ $service.port }}
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
- Current: **16 suites, 220 tests**

When adding a new template, always create a corresponding `*_test.yaml`.

## Architecture Decisions

1. **Multi-deployment over multi-release**: Single release, multiple deployments with shared ingress
2. **Inheritance over duplication**: Hooks/CronJobs inside deployments inherit image, configMap, secret, SA, nodeSelector, tolerations, affinity
3. **ServiceAccount per deployment by default**: `serviceAccount.create` defaults to `true`
4. **Docker-based tooling**: helm-unittest and helm-docs run via Docker, no local plugins needed
