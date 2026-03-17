# Coding Conventions

**Analysis Date:** 2026-03-17

## Language & Template Engine

This is a Helm chart codebase. All logic is written in Go templates (`*.tpl`, `*.yaml` under `templates/`). There is no application source code — conventions apply to Helm template authoring patterns.

## Naming Patterns

**Template Helpers (in `templates/_helpers.tpl`):**
- Named with `global-chart.` prefix: `global-chart.deploymentFullname`, `global-chart.renderVolume`
- Shared rendering helpers prefixed with `render`: `renderImagePullSecrets`, `renderDnsConfig`, `renderResources`, `renderVolume`
- Boolean-return helpers named descriptively: `deploymentEnabled`, `deploymentServiceAccountName`

**Template Variables:**
- Root context always captured as `$root := .` at the start of templates that `range` over values
- Loop variables named semantically: `$name, $deploy`, `$hookType, $jobs`, `$bi, $b` (bundle index/bundle)
- Computed names use `Fullname` suffix: `$depFullname`, `$hookFullname`
- Context dicts named `$labelCtx`

**Values Keys:**
- camelCase throughout: `replicaCount`, `imagePullSecrets`, `serviceAccount`, `envFromConfigMaps`, `podSecurityContext`
- Sub-maps accessed via `default (dict) $deploy.field` pattern to avoid nil panics
- Plural for lists: `deployments`, `cronJobs`, `hooks`, `externalSecrets`, `rbacs`
- Singular for objects with keys: `service`, `autoscaling`, `pdb`, `networkPolicy`

**Kubernetes Resource Names:**
- Always use helpers: `global-chart.deploymentFullname`, `global-chart.fullname`, `global-chart.hookfullname`
- Never construct names inline without `trunc 63 | trimSuffix "-"`
- CronJob names truncated to 52 (not 63) to leave room for Kubernetes timestamp suffix

**Files:**
- Template files: `kebab-case.yaml` (e.g., `mounted-configmap.yaml`, `externalsecret.yaml`)
- Test files: match template name with `_test.yaml` suffix (e.g., `deployment_test.yaml`)
- Value fixture files: `kebab-case.yaml` or descriptive name (e.g., `cron-only.yaml`, `hooks-sa-inheritance.yaml`)

## Boolean and Optional Field Handling

**Critical rule:** Never use `default true $var` for boolean fields. Go templates treat `false` as falsy and replace it with the default.

**Use `hasKey` + `ternary` instead:**
```yaml
{{- $create := ternary $sa.create true (hasKey $sa "create") -}}
```

**For optional nested dicts, always use `default (dict)`:**
```yaml
{{- $sa := default (dict) $deploy.serviceAccount -}}
{{- $hpa := default (dict) $deploy.autoscaling }}
{{- $pdb := default (dict) $deploy.pdb }}
```

**For optional lists, always use `default (list)`:**
```yaml
{{- $userVolumes := default (list) $deploy.volumes }}
```

**Distinguishing "not set" from "set but empty":**
Use `hasKey` at inheritance decision points — never `if not $job.field`:
```yaml
{{- $hostAliases := ternary $command.hostAliases $deploy.hostAliases (hasKey $command "hostAliases") -}}
```
This correctly treats `hostAliases: []` (explicit empty) as "do not inherit" while absent key falls back to parent.

## Inheritance Pattern (Deployment → CronJob/Hook)

The canonical inheritance pattern for fields that can be overridden per-job:
```yaml
{{- $fieldValue := ternary $job.field $deploy.field (hasKey $job "field") -}}
{{- with $fieldValue }}
fieldKey:
  {{- toYaml . | nindent 8 }}
{{- end }}
```

For fallback chains across three levels (job > deployment > global):
```yaml
{{- $imagePullSecrets := list -}}
{{- if hasKey $command "imagePullSecrets" -}}
  {{- $imagePullSecrets = $command.imagePullSecrets -}}
{{- else if hasKey $deploy "imagePullSecrets" -}}
  {{- $imagePullSecrets = $deploy.imagePullSecrets -}}
{{- else -}}
  {{- $global := default (dict) $root.Values.global -}}
  {{- $imagePullSecrets = $global.imagePullSecrets -}}
{{- end -}}
```

## Shared Helpers Usage

**Always wrap shared helpers that can return empty with `{{- with }}`:**
```yaml
{{- with (include "global-chart.renderImagePullSecrets" $imagePullSecrets) }}
{{- . | nindent 6 }}
{{- end }}
```

Never call them unconditionally — they return an empty string when no output is needed, and an unwrapped call produces blank lines.

**Shared helpers that follow this pattern:**
- `global-chart.renderImagePullSecrets` — `templates/_helpers.tpl`
- `global-chart.renderDnsConfig` — `templates/_helpers.tpl`
- `global-chart.renderResources` — `templates/_helpers.tpl`

**Shared helpers must use `-}}` trim-right on their opening conditional:**
```yaml
{{- define "global-chart.renderImagePullSecrets" -}}
{{- with . -}}
imagePullSecrets:
```
This prevents the leading newline that `nindent` would turn into a blank line.

## Error Handling

**Use `fail` for invalid configurations with descriptive messages:**
```yaml
{{- fail (printf "PDB for deployment '%s': minAvailable and maxUnavailable are mutually exclusive — set only one." $name) }}
{{- fail (printf "deployments.%s.image requires either a tag or digest when repository is provided" $name) }}
```

**Use `required` for mandatory fields with contextual error messages:**
```yaml
image: {{ required (printf "deployments.%s.image must define a repository with tag/digest or be a full image reference" $name) $depImageRef | quote }}
```

**Validate cross-references at render time:**
```yaml
{{- if not $deploy -}}
  {{- fail (printf "hooks.%s.%s.fromDeployment references deployment '%s' which does not exist in .Values.deployments" ...) -}}
{{- end -}}
```

## Template Structure Pattern

Every resource template follows this structure:
```yaml
{{- $root := . }}
{{- range $name, $deploy := .Values.deployments }}
{{- if $deploy }}
{{- if eq (include "global-chart.deploymentEnabled" (dict "deploy" $deploy)) "true" }}
{{- $depFullname := include "global-chart.deploymentFullname" (dict "root" $root "deploymentName" $name) }}
{{- $labelCtx := dict "root" $root "deploymentName" $name }}
---
apiVersion: ...
```

The guard `{{- if $deploy }}` prevents nil map panics on empty entries.

## Labels Convention

- Non-deployment resources (Ingress, ExternalSecret, RBAC): use `global-chart.labels` and `global-chart.selectorLabels`
- Per-deployment resources: use `global-chart.deploymentLabels` and `global-chart.deploymentSelectorLabels` (includes `app.kubernetes.io/component: {deploymentName}`)
- Hook resources: use `global-chart.hookLabels` or `global-chart.hookLabelsWithComponent` — never `selectorLabels` (would interfere with HPA matching)

## Values Mutation

Never mutate `.Values` during rendering. For annotations or any nested map modification:
```yaml
{{- $annotations := deepCopy (default (dict) $ing.annotations) }}
```
Failing to `deepCopy` causes state to bleed across template invocations.

## Whitespace Control

- Opening `{{- $root := . }}` and variable assignments: always use `{{-` to strip leading whitespace
- `nindent` is preferred over `indent` for block scalars
- Use `{{- with }}...{{- end }}` to entirely suppress blocks when the value is nil/empty
- Inline values: `{{ $var | quote }}` without trimming to preserve placement on the line

## YAML Comments in Templates

Inline explanations for non-obvious logic use `{{- /* ... */ -}}`:
```yaml
{{- /* hasKey distinguishes unset from empty */ -}}
{{- /* ServiceAccount uses weight 5 so it exists before the Job (weight 10) */ -}}
```

Section dividers use `{{/* ====== SECTION NAME ====== */}}` pattern (seen in `hook.yaml`).

## values.yaml Documentation

All top-level keys and nested fields use `helm-docs` annotations:
```yaml
# -- Description of the field
# @default -- `value` (when default differs from YAML default)
fieldName: value
```

---

*Convention analysis: 2026-03-17*
