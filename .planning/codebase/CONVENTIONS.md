# Coding Conventions

**Analysis Date:** 2026-03-15

## Language

This is a **Helm chart** codebase. All templates are written in the Go template language (via Helm's Sprig extension). Conventions below apply to `.tpl` and `.yaml` template files.

---

## Naming Patterns

**Helper definitions (`_helpers.tpl`):**
- Prefixed with chart name: `global-chart.<helperName>` (e.g., `global-chart.deploymentFullname`)
- camelCase after the prefix (e.g., `global-chart.renderImagePullSecrets`, `global-chart.deploymentSelectorLabels`)

**Template variables:**
- Short, lowercase (e.g., `$root`, `$name`, `$deploy`, `$pdb`, `$svc`)
- Context dict for helpers uses descriptive keys: `root`, `deploymentName`, `deployment`

**Values keys:**
- camelCase (e.g., `replicaCount`, `imagePullSecrets`, `podSecurityContext`, `portName`)
- Boolean flags named `enabled` consistently across all sub-resources
- Plural for maps/lists: `deployments`, `cronJobs`, `hooks`, `volumes`, `tolerations`

**Kubernetes resource names:**
- Pattern: `{release}-{chart}-{deploymentName}` (truncated at 63 chars)
- CronJobs truncated at 52 chars (Kubernetes appends 11-char timestamp)
- See `charts/global-chart/templates/_helpers.tpl` helpers `deploymentFullname`, `hookfullname`

**Labels:**
- Use standard `app.kubernetes.io/` labels
- Per-deployment resources add `app.kubernetes.io/component: {deploymentName}`
- Hook labels omit selector labels to avoid HPA matching (see `global-chart.hookLabels`)

---

## Template File Structure

Every template file follows this pattern:

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

Pattern: capture `$root` first, then range over deployments, then guard with `deploymentEnabled`.

---

## Boolean Field Handling

**Critical rule: Never use `default true $var` for boolean fields.** Go templates treat `false` as falsy and `default` would replace it with `true`.

**Correct pattern using `hasKey` + `ternary`:**
```yaml
{{- $create := ternary $sa.create true (hasKey $sa "create") -}}
```
This means: if the key exists, use its value; otherwise default to `true`.

**Correct pattern for enabled flag:**
```yaml
{{- define "global-chart.deploymentEnabled" -}}
{{- ternary .deploy.enabled true (hasKey .deploy "enabled") -}}
{{- end }}
```

---

## Inheritance Pattern (Hooks and CronJobs inside Deployments)

When a nested job inherits a field from its parent deployment, use `hasKey` to distinguish "not set" (inherit) from "set but empty" (explicit override):

```yaml
{{- $nodeSelector := ternary $job.nodeSelector $deploy.nodeSelector (hasKey $job "nodeSelector") -}}
```

This means:
- `job.nodeSelector` is absent → inherit from `$deploy.nodeSelector`
- `job.nodeSelector: {}` (empty map) → use empty map, suppress inheritance
- `job.nodeSelector: {key: val}` → use job's value

**Never use `if not $job.field`** — this incorrectly treats `{}` and `[]` as falsy, causing unintended inheritance.

---

## Global Fallback Chains

For cascading values (e.g., `imagePullSecrets`), always use `hasKey` at every level:

```yaml
{{- $imagePullSecrets := list -}}
{{- if hasKey $deploy "imagePullSecrets" -}}
  {{- $imagePullSecrets = $deploy.imagePullSecrets -}}
{{- else -}}
  {{- $global := default (dict) $root.Values.global -}}
  {{- $imagePullSecrets = $global.imagePullSecrets -}}
{{- end -}}
```

An explicit `imagePullSecrets: []` on a deployment must block fallback to global defaults.

---

## Shared Helpers Usage

Shared helpers (`renderImagePullSecrets`, `renderDnsConfig`, `renderResources`) can return empty strings. Always wrap with `{{- with }}` to avoid blank lines:

```yaml
{{- with (include "global-chart.renderImagePullSecrets" $imagePullSecrets) }}
{{- . | nindent 6 }}
{{- end }}
```

Shared helper definitions must use `-}}` (trim-right) on the `with`/conditional line before literal content:

```yaml
{{- define "global-chart.renderImagePullSecrets" -}}
{{- with . -}}
imagePullSecrets:
  ...
```

---

## Error Handling

Use `fail` with descriptive messages that include resource type, parent name, and context:

```yaml
{{- fail (printf "PDB for deployment '%s': minAvailable and maxUnavailable are mutually exclusive — set only one." $name) }}

{{- fail (printf "hooks.%s.%s.fromDeployment references deployment '%s' which does not exist in .Values.deployments" $hookType $name $depName) }}

{{- fail (printf "renderVolume: unknown legacy volume type '%s' for volume '%s'. Supported types: emptyDir, configMap, secret, persistentVolumeClaim. For other volume types, use native Kubernetes volume spec (omit .type)." $vol.type $vol.name) }}
```

Use `required` for mandatory fields with a descriptive message:

```yaml
image: {{ required (printf "deployments.%s.image must define a repository with tag/digest or be a full image reference" $name) $depImageRef | quote }}
```

---

## Template Whitespace Control

- Use `{{-` (trim-left) and `-}}` (trim-right) aggressively to avoid blank lines
- Use `nindent N` for block-level content (never manual spaces)
- Opening `---` separator is placed after all guards/variable setup, directly before `apiVersion:`

---

## Values Mutation

**Never mutate `.Values` during rendering.** Use `deepCopy` to create a local copy:

```yaml
{{- $annotations := deepCopy (default (dict) $ing.annotations) }}
```

---

## Nil Safety for Optional Nested Fields

Use `default (dict)` when accessing optional sub-maps:

```yaml
{{- $sa := default (dict) $deploy.serviceAccount -}}
{{- $pdb := default (dict) $deploy.pdb }}
{{- $dnsConfig := default (dict) $deploy.dnsConfig }}
```

---

## `hasKey` vs Zero Value

Use `hasKey` whenever `0`, `false`, or `""` are valid values and must be preserved:

```yaml
{{- if hasKey $deploy "revisionHistoryLimit" }}
revisionHistoryLimit: {{ $deploy.revisionHistoryLimit }}
{{- end }}
```

This correctly handles `revisionHistoryLimit: 0`.

---

## Comments

**Block separators:** Use `# ====== <section name> ======` in test files to group related tests:
```yaml
# ====== enabled flag ======
# ====== extraContainers (Bug Fix #1) ======
```

**Inline template comments:** Use `{{- /* comment */ -}}` for significant logic steps:
```yaml
{{- /* Resolve image: explicit > fromDeployment > error */ -}}
{{- /* ServiceAccount uses weight 5 so it exists before the Job (weight 10) */ -}}
{{- /* ImagePullSecrets: deployment-level > global (hasKey distinguishes unset from empty) */ -}}
```

---

## Values Documentation

Values in `charts/global-chart/values.yaml` use helm-docs annotations:
```yaml
# -- Global image registry prefix (e.g., registry.example.com)
# @default -- `""` (no prefix)
imageRegistry: ""
```

---

## Multi-Document Templates

Templates that produce both a ServiceAccount and a Job (root-level hooks) use `documentIndex` in tests to target specific documents. SA always has lower `helm.sh/hook-weight` (5) than the Job (10) to ensure ordering.

---

*Convention analysis: 2026-03-15*
