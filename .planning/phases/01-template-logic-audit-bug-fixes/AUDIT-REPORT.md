# Template Correctness Audit Report

**Date:** 2026-03-15
**Scope:** 15 template files (~1,400 lines of Go template code) in `charts/global-chart/templates/`
**Auditor:** Automated analysis against established `hasKey`+`ternary` conventions

---

## TMPL-01: Falsy-Value Masking Audit

### Overview

Go templates treat `false`, `0`, and `""` as falsy. The `default` function replaces falsy values with the default, meaning a user who explicitly sets `automountServiceAccountToken: false` would silently get `true` instead.

The codebase has ~60+ `default` calls across all templates. Most are safe nil-guard patterns (`default (dict)`) or enum defaults where empty string is invalid. Below are the findings requiring attention.

### HIGH Risk Findings

These `default` calls will silently replace valid user-intended values:

| # | File | Line | Current Code | Issue | Proposed Fix |
|---|------|------|-------------|-------|-------------|
| H1 | `cronjob.yaml` | 47 | `default true $job.automountServiceAccountToken` | `false` is a valid and common security hardening value; silently replaced with `true` | Replace with `hasKey` check (see fix below) |

**H1 Fix:**
```yaml
# BEFORE (line 47):
automountServiceAccountToken: {{ default true $job.automountServiceAccountToken }}

# AFTER:
{{- $saAutoMount := true -}}
{{- if hasKey $job "automountServiceAccountToken" -}}
  {{- $saAutoMount = $job.automountServiceAccountToken -}}
{{- end -}}
automountServiceAccountToken: {{ $saAutoMount }}
```

> **Note:** The deployment-level cronjob section (lines 209-215) and the deployment-level hook section (lines 236-249) already use the correct `hasKey` pattern for `automountServiceAccountToken`. This bug only affects root-level CronJob SA resources.

### MEDIUM Risk Findings

Edge cases where `0` or `"0"` is a valid Kubernetes value that would be silently replaced:

| # | File | Line(s) | Current Code | Issue | Proposed Fix |
|---|------|---------|-------------|-------|-------------|
| M1 | `cronjob.yaml` | 63 | `default 2 $job.successfulJobsHistoryLimit` | `0` is valid K8s (means "keep no history"); silently replaced with `2` | `hasKey` + `if/else` |
| M2 | `cronjob.yaml` | 64 | `default 2 $job.failedJobsHistoryLimit` | Same as M1 | `hasKey` + `if/else` |
| M3 | `cronjob.yaml` | 258 | `default 2 $job.successfulJobsHistoryLimit` | Deployment-level duplicate of M1 | `hasKey` + `if/else` |
| M4 | `cronjob.yaml` | 259 | `default 2 $job.failedJobsHistoryLimit` | Deployment-level duplicate of M2 | `hasKey` + `if/else` |
| M5 | `hook.yaml` | 65 | `default "5" $command.weight` | Hook SA weight `"0"` is valid Helm annotation; silently replaced with `"5"` | `hasKey` + `if/else` |
| M6 | `hook.yaml` | 81 | `default "10" $command.weight` | Hook Job weight `"0"` is valid; silently replaced with `"10"` | `hasKey` + `if/else` |
| M7 | `hook.yaml` | 265 | `default "5" $command.weight` | Deployment-level hook SA duplicate of M5 | `hasKey` + `if/else` |
| M8 | `hook.yaml` | 286 | `default "10" $command.weight` | Deployment-level hook Job duplicate of M6 | `hasKey` + `if/else` |
| M9 | `deployment.yaml` | 20 | `$deploy.replicaCount \| default 2` | `0` replicas is valid K8s (scale-to-zero intent without HPA); silently replaced with `2` | `hasKey` + `if/else` |

**M1/M2 Fix (root-level cronjob, lines 63-64):**
```yaml
# BEFORE:
  successfulJobsHistoryLimit: {{ default 2 $job.successfulJobsHistoryLimit }}
  failedJobsHistoryLimit: {{ default 2 $job.failedJobsHistoryLimit }}

# AFTER:
  successfulJobsHistoryLimit: {{ hasKey $job "successfulJobsHistoryLimit" | ternary $job.successfulJobsHistoryLimit 2 }}
  failedJobsHistoryLimit: {{ hasKey $job "failedJobsHistoryLimit" | ternary $job.failedJobsHistoryLimit 2 }}
```

**M3/M4 Fix (deployment-level cronjob, lines 258-259):** Same pattern as M1/M2.

**M5/M6 Fix (root-level hook SA weight line 65, Job weight line 81):**
```yaml
# BEFORE (SA, line 65):
    "helm.sh/hook-weight": {{ default "5" $command.weight | quote }}
# BEFORE (Job, line 81):
    "helm.sh/hook-weight": {{ default "10" $command.weight | quote }}

# AFTER (SA):
    "helm.sh/hook-weight": {{ hasKey $command "weight" | ternary $command.weight "5" | quote }}
# AFTER (Job):
    "helm.sh/hook-weight": {{ hasKey $command "weight" | ternary $command.weight "10" | quote }}
```

**M7/M8 Fix (deployment-level hook, lines 265, 286):** Same pattern as M5/M6.

**M9 Fix (deployment.yaml, line 20):**
```yaml
# BEFORE:
  replicas: {{ $deploy.replicaCount | default 2 }}

# AFTER:
  replicas: {{ hasKey $deploy "replicaCount" | ternary $deploy.replicaCount 2 }}
```

### LOW Risk / SAFE `default` Calls (No Action Needed)

| Pattern | Count | Assessment |
|---------|-------|------------|
| `default (dict) $optional.nested` (nil-guard) | ~20 | SAFE -- prevents nil pointer on optional sub-maps |
| `default (list) $optional.list` | ~3 | SAFE -- guards `len` calls against nil |
| `default "" $string` (string trim/concat) | ~5 | SAFE -- used in helper internals, not user-facing |
| `default $generatedName $explicitName` | ~6 | SAFE -- empty name means "use generated" |
| ExternalSecret enum defaults (`"Default"`, `"None"`, `"Owner"`, `"Retain"`) | 5 | SAFE -- empty string is not a valid K8s enum value |
| `default "Forbid" $job.concurrencyPolicy` | 2 | SAFE -- empty concurrencyPolicy is invalid K8s |
| `default "Never" $job.restartPolicy` | 4 | SAFE -- empty restartPolicy is invalid K8s |
| `default "ClusterIP" $svc.type` | 1 | SAFE -- empty service type is invalid K8s |
| `default "http" $svc.portName` | 2 | SAFE -- empty port name is invalid K8s |
| `default 80 $svc.port` | 3 | SAFE -- port 0 is invalid K8s |
| `default "TCP" $svc.protocol` | 2 | SAFE -- empty protocol is invalid K8s |
| `default "ImplementationSpecific" $path.pathType` | 1 | SAFE -- empty pathType is invalid K8s |
| `default "before-hook-creation" $command.deletePolicy` | 4 | SAFE -- empty deletePolicy is invalid Helm |
| HPA `default 0` on CPU/memory targets | 2 | SAFE -- used as "not set" sentinel with `gt $val 0` guard |

**Total safe `default` calls: ~55+**

---

## TMPL-02: CronJob ServiceAccount Inheritance Bug

### Bug Description

When a deployment defines `serviceAccount.create: false` with `name: "existing-sa"` (referencing a pre-existing ServiceAccount), deployment-level **hooks** correctly inherit that SA name, but deployment-level **CronJobs** do not. The CronJob falls through to creating a spurious job-specific SA instead.

### Root Cause

The CronJob SA resolution block is missing the `else if $deploySA.name` branch.

### Current Code Comparison

**cronjob.yaml (lines 182-186) -- BUGGY:**
```yaml
{{- $deploymentSAName := "" -}}
{{- if $deploySA.create -}}
  {{- $deploymentSAName = include "global-chart.deploymentServiceAccountName" (dict "root" $root "deploymentName" $deployName "deployment" $deploy) -}}
{{- end -}}
```

**hook.yaml (lines 206-212) -- CORRECT reference implementation:**
```yaml
{{- $deploymentSAName := "" -}}
{{- if $deploySA.create -}}
  {{- $deploymentSAName = include "global-chart.deploymentServiceAccountName" (dict "root" $root "deploymentName" $deployName "deployment" $deploy) -}}
{{- else if $deploySA.name -}}
  {{- /* Deployment references an existing SA - inherit it */ -}}
  {{- $deploymentSAName = $deploySA.name -}}
{{- end -}}
```

### Impact

When a user configures:
```yaml
deployments:
  backend:
    serviceAccount:
      create: false
      name: "existing-sa"
    cronJobs:
      cleanup:
        schedule: "0 4 * * *"
        command: ["./cleanup.sh"]
```

- **Expected behavior:** CronJob uses `existing-sa` (same as hooks would)
- **Actual behavior:** CronJob creates a new SA named `{release}-{chart}-{deploy}-{cron}` and uses that instead
- **Severity:** HIGH -- produces unexpected SA resources and breaks least-privilege configurations

### Proposed Fix

Add the missing branch to `cronjob.yaml` after line 186:

```yaml
{{- $deploymentSAName := "" -}}
{{- if $deploySA.create -}}
  {{- $deploymentSAName = include "global-chart.deploymentServiceAccountName" (dict "root" $root "deploymentName" $deployName "deployment" $deploy) -}}
{{- else if $deploySA.name -}}
  {{- /* Deployment references an existing SA - inherit it */ -}}
  {{- $deploymentSAName = $deploySA.name -}}
{{- end -}}
```

A unit test must verify: deployment-level CronJob with `serviceAccount: {create: false, name: "existing-sa"}` renders `serviceAccountName: "existing-sa"` and does NOT produce a ServiceAccount resource.

---

## TMPL-03: Truncation Guard Analysis

### Resource Naming Table

| # | Resource Type | Name Formula | Template File | Line(s) | Trunc Applied | Limit | Status |
|---|---------------|-------------|---------------|---------|---------------|-------|--------|
| 1 | Deployment | `{fullname}-{deployName}` | `_helpers.tpl` | 59 | Yes | 63 | OK |
| 2 | Service | `{depFullname}` (from helper) | `service.yaml` | 11, 17 | Yes (via helper) | 63 | OK |
| 3 | ServiceAccount | `{depFullname}` or SA name | `serviceaccount.yaml` | 10, 15 | Yes (via helper) | 63 | OK |
| 4 | ConfigMap | `{depFullname}` | `configmap.yaml` | 5, 11 | Yes (via helper) | 63 | OK |
| 5 | Secret | `{depFullname}` | `secret.yaml` | 5, 11 | Yes (via helper) | 63 | OK |
| 6 | HPA | `{depFullname}` | `hpa.yaml` | 10, 16 | Yes (via helper) | 63 | OK |
| 7 | PDB | `{depFullname}` | `pdb.yaml` | 7, 13 | Yes (via helper) | 63 | OK |
| 8 | NetworkPolicy | `{depFullname}` | `networkpolicy.yaml` | 7, 13 | Yes (via helper) | 63 | OK |
| 9 | Ingress | `{fullname}` | `ingress.yaml` | 4, 9 | Yes (via helper) | 63 | OK |
| 10 | **Mounted ConfigMap** | `{depFullname}-md-cm-{name}` | `mounted-configmap.yaml` | 16, 33 | **NO** | - | **BUG** |
| 11 | **Mounted ConfigMap (volume ref)** | `{depFullname}-md-cm-{name}` | `deployment.yaml` | 174, 184 | **NO** | - | **BUG** |
| 12 | **ExternalSecret** | `printf "%s-%s" fullname $name` | `externalsecret.yaml` | 7, 12 | **NO** | - | **BUG** |
| 13 | Root CronJob | `printf "%s-%s" fullname $name` | `cronjob.yaml` | 15 | Yes | 52 | OK |
| 14 | Deploy CronJob | `printf "%s-%s-%s" fullname deploy cron` | `cronjob.yaml` | 166 | Yes | 52 | OK |
| 15 | Root Hook | `{fullname}-{hookType}-{jobName}` | `_helpers.tpl` | 129 | Yes | 63 | OK |
| 16 | Deploy Hook | `printf "%s-%s-%s-%s" fullname deploy type name` | `hook.yaml` | 184 | Yes | 63 | OK |
| 17 | RBAC Role | `printf "%s-role-%d" fullname $index` | `rbac.yaml` | 5 | Yes | 63 | OK |
| 18 | RBAC SA | `printf "%s-sa" $roleName` | `rbac.yaml` | 11 | Yes | 63 | OK |
| 19 | RBAC RoleBinding | `printf "%s-rolebinding" $base` | `rbac.yaml` | 52 | Yes | 63 | OK |

### BUG Details

**BUG #10/11: Mounted ConfigMap names are NOT truncated**

- **File:** `mounted-configmap.yaml` lines 16 and 33; `deployment.yaml` lines 174 and 184
- **Current code:** `{{ $depFullname }}-md-cm-{{ $f.name }}`
- **Issue:** `$depFullname` is already truncated to 63 chars by `deploymentFullname` helper. Appending `-md-cm-{name}` (minimum 7 chars for `-md-cm-` prefix alone) always produces a name > 63 chars when `$depFullname` is at or near the 63-char limit. Kubernetes will reject the ConfigMap creation.
- **Impact:** Users with long release names or deployment names will get runtime errors.

**Proposed fix:**
```yaml
# BEFORE:
  name: {{ $depFullname }}-md-cm-{{ $f.name }}

# AFTER:
  name: {{ printf "%s-md-cm-%s" $depFullname $f.name | trunc 63 | trimSuffix "-" }}
```

This must be applied in 4 locations:
1. `mounted-configmap.yaml` line 16 (files section)
2. `mounted-configmap.yaml` line 33 (bundles section)
3. `deployment.yaml` line 174 (volume configMap name reference)
4. `deployment.yaml` line 184 (projected volume configMap name reference)

**BUG #12: ExternalSecret names are NOT truncated**

- **File:** `externalsecret.yaml` line 7
- **Current code:** `$secretName := printf "%s-%s" (include "global-chart.fullname" $root) $name`
- **Issue:** No `trunc 63 | trimSuffix "-"` applied. If `fullname` (up to 63 chars) + `-` + `$name` > 63, Kubernetes will reject the resource.
- **Impact:** Users with long release names and long ExternalSecret names get runtime errors.

**Proposed fix:**
```yaml
# BEFORE:
{{- $secretName := printf "%s-%s" (include "global-chart.fullname" $root) $name -}}

# AFTER:
{{- $secretName := printf "%s-%s" (include "global-chart.fullname" $root) $name | trunc 63 | trimSuffix "-" -}}
```

Also update the `target.name` default on line 30 to use the truncated `$secretName` (it already does via `default $secretName $target.name`).

### Boundary Budget Analysis

With a typical release (`myrelease-global-chart` = 23 chars):

| Resource | Formula overhead | Budget for user names | Overflow at |
|----------|-----------------|----------------------|-------------|
| Mounted CM | `-md-cm-` = 7 chars from depFullname | 63 - 23 - 1(hyphen) - 7 = 32 chars | depFullname 56+ chars |
| ExternalSecret | `-` = 1 char from fullname | 63 - 23 - 1 = 39 chars | fullname 63 + any name |

---

## TMPL-04: Inheritance Duplication Analysis

### Scope of Duplication

The deployment-level sections of `hook.yaml` (lines 175-424, ~250 lines) and `cronjob.yaml` (lines 157-405, ~250 lines) contain nearly identical inheritance logic for resolving values from a parent deployment.

### Duplicated Fields (15 fields)

| # | Field | hook.yaml Pattern | cronjob.yaml Pattern | Identical? |
|---|-------|-------------------|---------------------|-----------|
| 1 | ServiceAccount resolution | Lines 196-234 | Lines 177-207 | No -- cronjob is MISSING `else if $deploySA.name` (TMPL-02 bug) |
| 2 | `automountServiceAccountToken` | Lines 236-249 | Lines 209-215 | Structurally identical |
| 3 | `serviceAccountAnnotations` | Lines 246-249 | Lines 216-219 | Identical |
| 4 | `imagePullSecrets` (3-level fallback) | Lines 298-306 | Lines 264-273 | Identical |
| 5 | `hostAliases` (ternary hasKey) | Lines 311-312 | Lines 278-279 | Identical |
| 6 | `podSecurityContext` (ternary hasKey) | Lines 317-318 | Lines 284-285 | Identical |
| 7 | `securityContext` (container, ternary) | Lines 336-337 | Lines 316-317 | Identical |
| 8 | `nodeSelector` (ternary hasKey) | Lines 402-403 | Lines 383-384 | Identical |
| 9 | `tolerations` (ternary hasKey) | Lines 414-415 | Lines 395-396 | Identical |
| 10 | `affinity` (ternary hasKey) | Lines 408-409 | Lines 389-390 | Identical |
| 11 | `envFrom` (deploy CM/Secret + external refs + job refs) | Lines 344-377 | Lines 321-354 | Identical |
| 12 | `env` / `additionalEnvs` merge | Lines 379-390 | Lines 356-367 | Identical |
| 13 | `imagePullPolicy` (helper call) | Line 326 | Line 306 | Identical |
| 14 | `image` resolution (job > deploy) | Lines 187-193 | Lines 169-175 | Identical |
| 15 | `dnsConfig` inheritance | **NOT PRESENT** (hooks don't inherit) | Lines 290-295 | **Asymmetry** |

### Differences That Must Be Preserved

| Aspect | hook.yaml | cronjob.yaml | Shared Helper? |
|--------|-----------|--------------|---------------|
| SA resource gets helm hook annotations | Yes (`helm.sh/hook`, `helm.sh/hook-weight`) | No | No -- SA creation stays in caller |
| `dnsConfig` inheritance from deployment | No (hooks use `$command.dnsConfig` only) | Yes (falls back to `$deploy.dnsConfig`) | Parameterized (flag or always present) |
| Job struct nesting | `spec.template.spec` (Job) | `spec.jobTemplate.spec.template.spec` (CronJob) | No -- caller controls indentation |
| Container name source | `$name` (job name in range) | `$name` (cronjob name in range) | Passed as parameter |
| `restartPolicy` placement | Inside `spec.template.spec` before containers | After volumes/tolerations at end | Caller controls |

### Proposed Shared Helper

**Name:** `global-chart.inheritedJobPodSpec`

**Dict interface:**
```yaml
{{- $podSpec := dict
  "root" $root
  "deployName" $deployName
  "deploy" $deploy
  "jobName" $name
  "job" $command          # or $job for cronjobs
  "jobFullname" $hookFullname
  "deployFullname" $deployFullname
  "inheritDnsConfig" true  # false for hooks, true for cronjobs
-}}
```

**Returns:** A rendered string block covering the pod spec from `imagePullSecrets` through `tolerations`, including `containers` with envFrom/env/securityContext/resources. Callers use `include` + `nindent` to embed at the correct indentation level.

**What stays in the caller templates:**
1. SA resolution and SA resource creation (hooks need helm annotations; cronjobs do not)
2. CronJob-specific fields (`schedule`, `concurrencyPolicy`, `successfulJobsHistoryLimit`, `failedJobsHistoryLimit`)
3. Hook-specific fields (`helm.sh/hook`, `helm.sh/hook-weight`, `helm.sh/hook-delete-policy`)
4. `restartPolicy` placement
5. Top-level metadata (name, labels, annotations)

**Estimated reduction:** ~200 lines of duplicated template code replaced by a single ~120-line helper definition + ~10 lines of `include` calls per caller = net reduction of ~80 lines and elimination of divergence risk.

---

## Summary and Recommendations

### All Findings by Severity

| # | ID | Severity | Category | Description | Fix Type |
|---|-----|----------|----------|-------------|----------|
| 1 | H1 | HIGH | TMPL-01 | `automountServiceAccountToken: false` masked by `default true` in root CronJob SA | Direct fix |
| 2 | TMPL-02 | HIGH | TMPL-02 | CronJob SA missing `else if $deploySA.name` branch | Direct fix (2 lines) |
| 3 | BUG-10 | HIGH | TMPL-03 | Mounted ConfigMap names not truncated (4 locations) | Direct fix |
| 4 | BUG-12 | HIGH | TMPL-03 | ExternalSecret names not truncated | Direct fix |
| 5 | M1-M4 | MEDIUM | TMPL-01 | `successfulJobsHistoryLimit: 0` / `failedJobsHistoryLimit: 0` masked | Direct fix |
| 6 | M5-M8 | MEDIUM | TMPL-01 | Hook weight `"0"` masked by `default "5"/"10"` | Direct fix |
| 7 | M9 | MEDIUM | TMPL-01 | `replicaCount: 0` masked by `default 2` | Direct fix |
| 8 | TMPL-04 | INFO | TMPL-04 | ~200 lines of duplicated inheritance logic | Refactor (shared helper) |

### Fix Plan

- **Plan 02 (Direct Fixes):** Apply H1, TMPL-02, BUG-10, BUG-12, M1-M9 with unit tests for each fix
- **Plan 03 (Refactor):** Extract `global-chart.inheritedJobPodSpec` shared helper with regression tests

### Status

**Awaiting user approval to proceed with fixes in Plans 02 and 03.**

Please review the findings above and confirm:
1. Are the HIGH-risk findings correctly identified?
2. Do the proposed `hasKey`+`ternary` fixes look correct?
3. Is the CronJob SA bug description accurate?
4. Should any finding be excluded or modified?
5. Is the shared helper scope (TMPL-04) appropriate?

---

*Report generated: 2026-03-15*
*Template files audited: 15 (all templates in `charts/global-chart/templates/`)*
*Total `default` calls analyzed: ~60+*
