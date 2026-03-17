# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Global-chart is a reusable Helm chart (v1.4.0) providing multi-deployment Kubernetes building blocks. See `README.md` for full feature list and examples, `CHANGELOG.md` for version history and migration guides.

## Commands

```bash
make all                    # Full pipeline: lint + test + bad-values + generate + kubeconform + kube-linter
make lint-chart             # Lint all 17 test scenarios
make unit-test              # 312 helm-unittest tests via Docker
make validate-bad-values    # Verify schema rejects invalid values
make kubeconform            # Validate manifests against K8s 1.29
make kube-linter            # Lint manifests (addAllBuiltIn)
make generate-docs          # Regenerate helm-docs README
make render VALUES=tests/test01/values.01.yaml TEMPLATE=deployment.yaml  # Debug single template
```

Always run `make lint-chart` and `make unit-test` after modifying templates or values.

## Architecture

### File Layout

- `charts/global-chart/templates/` — Helm templates
- `charts/global-chart/templates/_*.tpl` — Helper files (5 domain files, see below)
- `charts/global-chart/values.schema.json` — JSON Schema Draft 7
- `charts/global-chart/tests/` — helm-unittest suites (17 suites)
- `tests/` — Lint scenario values + `bad-values/` for schema rejection tests

### Helper Files

| File | Domain |
|------|--------|
| `_helpers.tpl` | Core naming, labels (`fullname`, `deploymentFullname`, `labels`, `selectorLabels`, `deploymentEnabled`, `deploymentServiceAccountName`) |
| `_image-helpers.tpl` | `imageString` (string/map/global registry/numeric tags), `imagePullPolicy` |
| `_job-helpers.tpl` | `inheritedJobPodSpec` — shared pod spec for deployment-level hooks/cronjobs with full inheritance chain. Params: `inheritDnsConfig` (true=cronjob, false=hook), `renderInitContainers` (true=cronjob, false=hook) |
| `_render-helpers.tpl` | `renderVolume` (native + legacy), `renderImagePullSecrets`, `renderDnsConfig`, `renderResources`, `renderCommonAnnotations` |
| `_validate-helpers.tpl` | `validateNameCollisions` — fails on truncation-induced name collisions |

### Key Design Patterns

1. **Multi-deployment iteration**: `range $name, $deploy := .Values.deployments` — each deployment generates Deployment, Service, SA, ConfigMap, Secret, HPA, PDB, NetworkPolicy
2. **Naming**: `{release}-{chart}-{deploymentName}` (trunc 63). CronJobs trunc 52 (K8s adds 11-char timestamp)
3. **Selector labels**: `app.kubernetes.io/component: {deploymentName}` ensures pods don't overlap
4. **SA default**: `serviceAccount.create` defaults to `true`. Deployment-level hooks/cronjobs inherit the deployment SA via `hasKey/ternary` with default true
5. **Inheritance**: Deployment-level hooks/cronjobs inherit image, configMap, secret, SA, envFrom, imagePullSecrets, hostAliases, securityContext, dnsConfig (cronjobs only), nodeSelector, tolerations, affinity. Override with explicit value; use empty `{}` or `[]` to stop inheritance
6. **Hook weight ordering**: `prereq ConfigMap/Secret (w-7) < SA (w-5) < Job (w)`, derived from effective Job weight (default 10). `minJobWeight` across all hooks per deployment determines prereq weight
7. **Hook prerequisite resources**: Deployment ConfigMap/Secret are duplicated as hook-annotated resources because normal resources aren't updated until after hooks complete
8. **Global fallback chains**: job > deployment > global, using `hasKey` at every level. Explicit `[]` stops fallback
9. **Schema**: `values.schema.json` validates during install/upgrade/lint. Does NOT use `required` on `mountedConfigFiles` items (templates handle runtime validation to allow `failedTemplate` tests)

### Resource Naming Limits

| Resource | Max |
|----------|-----|
| Most resources | 63 chars |
| CronJobs | **52 chars** |
| Hook prerequisite ConfigMap/Secret | 63 chars (name includes `-hook-config`/`-hook-secret` suffix) |

## Template Coding Rules

These are the hard-won patterns from this codebase. Violating them causes subtle bugs.

**Boolean/numeric fields — never use `default`:**
```yaml
# WRONG: default true $var replaces false with true
enabled: {{ default true $deploy.enabled }}
# CORRECT:
enabled: {{ hasKey $deploy "enabled" | ternary $deploy.enabled true }}
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
- Run `make lint-chart` to verify schema doesn't reject valid test values

**Adding new helpers:** Place in the appropriate domain file, not `_helpers.tpl`

**Adding `merge` on `.Values` maps:** Always `deepCopy` the first argument

**Adding hook weight logic:** Maintain invariant `prereq (w-7) < SA (w-5) < Job (w)`

**Every template must have a corresponding `*_test.yaml`** in `charts/global-chart/tests/`
