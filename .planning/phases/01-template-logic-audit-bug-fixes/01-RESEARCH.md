# Phase 1: Template Logic Audit & Bug Fixes - Research

**Researched:** 2026-03-15
**Domain:** Helm chart Go template correctness -- `default` masking, SA inheritance, truncation guards, helper extraction
**Confidence:** HIGH

## Summary

This phase addresses four concrete template correctness issues in a Helm chart with 12 resource templates and ~30 helpers. The codebase already follows correct patterns in most places (`hasKey` + `ternary` for booleans, `default (dict)` for nil safety) but has specific gaps: (1) several `default` calls on potentially falsy values, (2) a confirmed CronJob SA inheritance bug missing the `deploySA.name` branch, (3) truncation applied consistently but never verified at boundaries, and (4) ~220 lines of duplicated inheritance logic between hook.yaml and cronjob.yaml.

The audit scope is well-bounded: 12 template files + 1 helpers file totaling ~1,200 lines of template code. Every `default` call has been cataloged (see findings below). The CronJob SA bug is a 2-line fix (adding the `else if $deploySA.name` branch). The shared helper extraction is the largest task -- converting ~200 lines of duplicated pod-spec inheritance into a single named template.

**Primary recommendation:** Produce AUDIT-REPORT.md with categorized findings first, then apply fixes in a single batch with regression tests for each fix.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Report-first approach: complete audit -> AUDIT-REPORT.md with all findings -> user approval -> fix batch
- Audit scope is comprehensive: `default` calls + `if/else` on falsy values + global fallback chains + `required`/`fail` paths
- Report format: `.planning/phases/01-*/AUDIT-REPORT.md` with finding/severity/fix table
- Extract full pod spec inheritance into a single shared helper (e.g., `global-chart.inheritedJobPodSpec`)
- Covers: SA resolution, imagePullSecrets, hostAliases, podSecurityContext, securityContext, nodeSelector, tolerations, affinity, envFrom, env inheritance
- Scope: deployment-level hooks/cronjobs only -- root-level have different logic (fromDeployment, no inheritance) and stay separate
- Helper returns a rendered string block (Go template constraint); callers use `include` + `nindent`
- Falsy-value masking fixes are applied directly (hasKey+ternary replacing incorrect `default`): if a user passed `false`, they intended it
- CronJob SA bug is classified as a bugfix, not breaking change
- No deprecation warnings needed for correctness fixes
- Complete truncation analysis: calculate worst-case name length for every resource type and verify `trunc` is applied correctly
- Standard Helm truncation: `trunc N | trimSuffix "-"` -- no smart word-boundary truncation

### Claude's Discretion
- Exact structure and severity levels for AUDIT-REPORT.md
- Order of findings in the report
- Grouping strategy for related findings
- Implementation details of the shared helper's dict interface

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| TMPL-01 | Audit all `default` calls for falsy-value masking | Complete catalog of 80+ `default` calls across all templates; categorized by risk level (see Standard Stack / Architecture Patterns sections) |
| TMPL-02 | Fix CronJob SA inheritance to match Hooks | Exact bug location identified: cronjob.yaml lines 183-186 missing `else if $deploySA.name` branch; hook.yaml lines 207-212 is reference |
| TMPL-03 | Verify truncation guards on all resource names | All naming patterns cataloged with max-length calculations for each resource type (see Truncation Analysis section) |
| TMPL-04 | Extract shared inheritance helper from hook.yaml/cronjob.yaml | Inheritance logic mapped: ~15 fields to share; dict interface designed; deployment-level only scope confirmed |
</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Helm | v3 | Chart templating and deployment | Project standard; Go template engine |
| helm-unittest | Docker-based | Template assertion testing | Already in CI; 220 existing tests across 16 suites |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| Make | GNU Make | Task runner | `make unit-test`, `make lint-chart` for validation |

### No Additional Dependencies
This phase modifies existing Go templates and adds unit tests. No new tools or libraries needed.

## Architecture Patterns

### Pattern 1: Falsy-Value Safe Field Access

**What:** Use `hasKey` + `ternary` instead of `default` when `false`, `0`, or `""` are valid user inputs.

**When to use:** Any field where a user might intentionally set a zero/false/empty value.

**Correct pattern:**
```yaml
# Boolean field defaulting to true
{{- $create := ternary $sa.create true (hasKey $sa "create") -}}

# Integer field where 0 is valid
{{- if hasKey $deploy "revisionHistoryLimit" }}
revisionHistoryLimit: {{ $deploy.revisionHistoryLimit }}
{{- end }}
```

**Current `default` calls categorized by risk:**

**HIGH RISK (falsy values are valid user input):**
| File | Line | Call | Issue | Fix |
|------|------|------|-------|-----|
| `cronjob.yaml` | 47 | `default true $job.automountServiceAccountToken` | `false` is valid and common | `hasKey` + `ternary` |
| `deployment.yaml` | 20 | `$deploy.replicaCount \| default 2` | `0` replicas is unusual but `replicaCount` is only rendered when HPA is disabled, so `0` would be a valid "scale-to-zero" intent | Verify if 0 is valid; if so, use `hasKey` |
| `hpa.yaml` | 6-7 | `default 0 $hpa.targetCPUUtilizationPercentage` | 0 is the "not set" sentinel here -- actually SAFE because `int (default 0 ...)` and then `gt $cpu 0` is the guard | No fix needed |

**MEDIUM RISK (edge cases unlikely but possible):**
| File | Line | Call | Issue |
|------|------|------|-------|
| `cronjob.yaml` | 62 | `default "Forbid" $job.concurrencyPolicy` | Empty string `""` would be replaced; but empty concurrencyPolicy is invalid K8s anyway |
| `cronjob.yaml` | 63-64 | `default 2 $job.successfulJobsHistoryLimit` | `0` is valid K8s (means "don't keep history") -- would be masked |
| `cronjob.yaml` | 257-259 | Same defaults on deployment-level cronjob | Same issue as root-level |
| `hook.yaml` | 65, 81 | `default "5"/"10" $command.weight` | Weight `"0"` is valid Helm hook weight -- would be masked |
| `hook.yaml` | 265, 286 | Same defaults on deployment-level hook | Same issue |
| `hook.yaml` | 113, 322 | `default "Never" $command.restartPolicy` | Empty string would be masked; but empty is invalid K8s |
| `cronjob.yaml` | 152, 400 | `default "Never" $job.restartPolicy` | Same as hooks |
| `service.yaml` | 23 | `$svc.port \| default 80` | Port `0` would be masked; but port 0 is invalid K8s |
| `deployment.yaml` | 93-95 | `$svc.portName \| default "http"`, `$svc.port \| default 80` | Same analysis as service.yaml |

**LOW RISK / SAFE (nil-guard pattern, not user-facing):**
| Pattern | Count | Assessment |
|---------|-------|------------|
| `default (dict) $optional.nested` | ~20 | SAFE -- guards against nil pointer on optional sub-maps |
| `default (list) $optional.list` | ~3 | SAFE -- guards against nil for `len` calls |
| `default "" $string` | ~5 | SAFE -- used for string trimming/concatenation, not user-visible |
| `default $generatedName $explicitName` | ~6 | SAFE -- empty name means "use generated" |
| ExternalSecret `default "Default"/"None"/"Owner"/"Retain"` | 5 | SAFE -- these are enum defaults; empty string is not a valid K8s enum value |

### Pattern 2: CronJob SA Inheritance (Bug Fix)

**What:** CronJob deployment-level SA inheritance is missing the `create: false` + `name` path.

**Current cronjob.yaml (lines 183-186) -- BUGGY:**
```yaml
{{- $deploymentSAName := "" -}}
{{- if $deploySA.create -}}
  {{- $deploymentSAName = include "global-chart.deploymentServiceAccountName" ... -}}
{{- end -}}
```

**Current hook.yaml (lines 206-212) -- CORRECT:**
```yaml
{{- $deploymentSAName := "" -}}
{{- if $deploySA.create -}}
  {{- $deploymentSAName = include "global-chart.deploymentServiceAccountName" ... -}}
{{- else if $deploySA.name -}}
  {{- /* Deployment references an existing SA - inherit it */ -}}
  {{- $deploymentSAName = $deploySA.name -}}
{{- end -}}
```

**Fix:** Add `else if $deploySA.name` branch to cronjob.yaml line 186.

**Impact:** CronJobs inside a deployment with `serviceAccount.create: false, name: "existing-sa"` will now correctly use `existing-sa` instead of creating a spurious cronjob-specific SA.

### Pattern 3: Shared Inheritance Helper Design

**What:** Extract duplicated deployment-level inheritance logic into `global-chart.inheritedJobPodSpec`.

**Scope of shared logic (15 fields):**
1. ServiceAccount resolution (create/inherit/explicit)
2. imagePullSecrets (job > deploy > global)
3. hostAliases (job > deploy)
4. podSecurityContext (job > deploy)
5. securityContext (container-level, job > deploy)
6. dnsConfig (job > deploy) -- CronJobs only currently; hooks do NOT inherit dnsConfig
7. nodeSelector (job > deploy)
8. tolerations (job > deploy)
9. affinity (job > deploy)
10. envFrom (deployment's generated CM/Secret + deployment's external refs + job's external refs)
11. env/additionalEnvs (deployment's + job's, concatenated)
12. imagePullPolicy (job override > image map > fallback)
13. image (job > deploy)
14. automountServiceAccountToken
15. serviceAccountAnnotations

**Dict interface recommendation:**
```yaml
{{- $podSpec := dict
  "root" $root
  "deployName" $deployName
  "deploy" $deploy
  "jobName" $name
  "job" $command
  "jobFullname" $hookFullname
  "deployFullname" $deployFullname
-}}
```

**Key constraint:** Go template helpers return strings, not structured data. The helper must either:
- (A) Return the full rendered pod spec block as a string (callers use `include` + `nindent`)
- (B) Return individual resolved values via separate small helpers (more helpers, less coupling)

**Recommendation:** Option (A) -- a single helper returning the full `spec:` block from `imagePullSecrets` through `tolerations`. This matches the existing pattern of `renderImagePullSecrets`, `renderDnsConfig`, `renderResources`. The SA resolution and SA resource creation stay in the calling templates because hooks need helm annotations on SA while cronjobs don't.

**Differences between hook.yaml and cronjob.yaml that must be preserved:**
| Aspect | hook.yaml | cronjob.yaml | In shared helper? |
|--------|-----------|--------------|-------------------|
| SA resource has helm hook annotations | Yes | No | No -- SA creation stays in caller |
| dnsConfig inheritance from deploy | No (absent) | Yes | Yes -- controlled by a flag or always present |
| Job struct nesting | `spec.template.spec` | `spec.jobTemplate.spec.template.spec` | No -- indentation is caller's concern |
| Container name | `$name` (job name) | `$name` (cronjob name) | Passed as parameter |

### Pattern 4: Truncation Analysis

**Resource naming formulas and max lengths:**

| Resource Type | Name Formula | Trunc Limit | Helper/Inline |
|---------------|-------------|-------------|---------------|
| Deployment, Service, SA, CM, Secret, HPA, PDB, NP | `{fullname}-{deployName}` | 63 | `deploymentFullname` helper |
| Mounted ConfigMap | `{fullname}-{deployName}-md-cm-{name}` | 63 | Inline in deployment.yaml -- **NOT truncated** |
| Ingress | `{fullname}` | 63 | `fullname` helper |
| ExternalSecret | `{fullname}-{secretName}` | **NOT truncated** | Inline in externalsecret.yaml |
| Root CronJob | `{fullname}-{cronName}` | 52 | Inline in cronjob.yaml |
| Deploy CronJob | `{fullname}-{deployName}-{cronName}` | 52 | Inline in cronjob.yaml |
| Root Hook | `{fullname}-{hookType}-{jobName}` | 63 | `hookfullname` helper |
| Deploy Hook | `{fullname}-{deployName}-{hookType}-{jobName}` | 63 | Inline in hook.yaml |
| RBAC Role | `{fullname}-role-{index}` | 63 | Inline in rbac.yaml |
| RBAC SA | `{roleName}-sa` | 63 | Inline in rbac.yaml |
| RBAC RoleBinding | `{bindingBase}-rolebinding` | 63 | Inline in rbac.yaml |

**Findings:**
1. **Mounted ConfigMap names are NOT truncated.** `deployment.yaml` lines 174, 184 use `$depFullname -md-cm-{name}` without `trunc 63`. If `$depFullname` is already 63 chars (after `deploymentFullname` truncation), adding `-md-cm-{name}` creates names exceeding 63 chars -- Kubernetes will reject these.
2. **ExternalSecret names are NOT truncated.** `externalsecret.yaml` line 7 uses `printf "%s-%s" fullname $name` without `trunc 63`.
3. **RBAC RoleBinding name**: `rbac.yaml` line 52 applies `trunc 63` -- correct.
4. **Root CronJob SA name**: `cronjob.yaml` line 33 uses `default $jobFullname $job.serviceAccountName` -- the `$jobFullname` is already truncated to 52, so the SA name is safe.
5. **Deploy Hook inline name**: `hook.yaml` line 184 -- `printf "%s-%s-%s-%s" fullname deployName hookType name | trunc 63` -- correct.
6. **Deploy CronJob inline name**: `cronjob.yaml` line 166 -- `printf "%s-%s-%s" fullname deployName name | trunc 52` -- correct.

### Anti-Patterns to Avoid
- **Never use `default true $booleanVar`** -- Go templates treat `false` as falsy
- **Never use `if not $job.field`** for inheritance -- treats `{}` and `[]` as falsy
- **Never mutate `.Values`** -- use `deepCopy` for local modifications
- **Never add inheritance logic directly in templates** when a shared helper exists -- always extend the helper

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Boolean default detection | Custom `if/else` chains | `hasKey` + `ternary` (Sprig built-in) | One-liner, idiomatic, handles all falsy cases |
| Nil-safe nested access | Multi-level `if` guards | `default (dict) $parent.field` | Standard Go template pattern |
| Image string assembly | String concatenation with conditionals | `global-chart.imageString` helper (existing) | Handles string/map formats, registry prefix, digest vs tag |
| SA name resolution | Inline logic per template | `global-chart.deploymentServiceAccountName` helper (existing) | Single source of truth |
| Pod spec inheritance | Copy-paste between hook/cronjob templates | `global-chart.inheritedJobPodSpec` helper (to be created) | Eliminates the root cause of the SA divergence bug |

**Key insight:** The CronJob SA bug exists precisely because inheritance logic was hand-rolled in two places instead of using a shared helper. The helper extraction (TMPL-04) is the permanent fix; the SA bugfix (TMPL-02) is the immediate patch.

## Common Pitfalls

### Pitfall 1: `default` Masking `false` and `0`
**What goes wrong:** User sets `automountServiceAccountToken: false`; template uses `default true $val`; Go treats `false` as falsy; result is `true`.
**Why it happens:** Go `default` means "if falsy" not "if undefined."
**How to avoid:** Always use `hasKey $map "field" | ternary $map.field <defaultValue>` for any field where `false`/`0`/`""` is a valid user input.
**Warning signs:** Any `default true`, `default 0` on user-controlled fields.

### Pitfall 2: Shared Helper String Trimming
**What goes wrong:** Shared helper returns a string with leading/trailing newlines; caller uses `nindent` and gets blank lines in output.
**Why it happens:** Go template whitespace is implicit; `define` blocks capture surrounding whitespace.
**How to avoid:** Use `-}}` trim on the line before literal content inside helpers. Callers wrap with `{{- with (include ...) }}`.
**Warning signs:** Blank lines in rendered YAML above blocks like `imagePullSecrets:`.

### Pitfall 3: Helper Dict Key Typos
**What goes wrong:** Caller passes `dict "deployName" $name` but helper reads `.deploymentName` -- silently gets empty string.
**Why it happens:** Go template dicts are untyped maps; no compile-time check for key existence.
**How to avoid:** Document the expected dict keys in the helper's comment block. Add tests that exercise every parameter.
**Warning signs:** Resources rendered with empty names or missing fields.

### Pitfall 4: Truncation Without Collision Detection
**What goes wrong:** Two deployments with long names sharing a prefix get identical truncated names; Kubernetes silently overwrites one.
**Why it happens:** `trunc 63 | trimSuffix "-"` has no uniqueness guarantee.
**How to avoid:** Document maximum safe deployment name lengths. Consider adding a `fail` guard when truncation actually removes characters. Always test at the boundary.
**Warning signs:** Deployment names approaching 40+ chars with similar prefixes.

## Code Examples

### Example 1: Fixing `default true` on automountServiceAccountToken (cronjob.yaml line 47)
```yaml
# BEFORE (buggy):
automountServiceAccountToken: {{ default true $job.automountServiceAccountToken }}

# AFTER (correct):
{{- $autoMount := true -}}
{{- if hasKey $job "automountServiceAccountToken" -}}
  {{- $autoMount = $job.automountServiceAccountToken -}}
{{- end -}}
automountServiceAccountToken: {{ $autoMount }}
```

### Example 2: Fixing CronJob SA inheritance (cronjob.yaml lines 183-186)
```yaml
# BEFORE (buggy -- missing else if):
{{- $deploymentSAName := "" -}}
{{- if $deploySA.create -}}
  {{- $deploymentSAName = include "global-chart.deploymentServiceAccountName" (dict "root" $root "deploymentName" $deployName "deployment" $deploy) -}}
{{- end -}}

# AFTER (matches hook.yaml):
{{- $deploymentSAName := "" -}}
{{- if $deploySA.create -}}
  {{- $deploymentSAName = include "global-chart.deploymentServiceAccountName" (dict "root" $root "deploymentName" $deployName "deployment" $deploy) -}}
{{- else if $deploySA.name -}}
  {{- $deploymentSAName = $deploySA.name -}}
{{- end -}}
```

### Example 3: Fixing `successfulJobsHistoryLimit: 0` masking
```yaml
# BEFORE (buggy):
successfulJobsHistoryLimit: {{ default 2 $job.successfulJobsHistoryLimit }}

# AFTER (correct):
{{- if hasKey $job "successfulJobsHistoryLimit" }}
successfulJobsHistoryLimit: {{ $job.successfulJobsHistoryLimit }}
{{- else }}
successfulJobsHistoryLimit: 2
{{- end }}
```

### Example 4: Fixing missing truncation on mounted configmap names
```yaml
# BEFORE (no truncation):
name: {{ $depFullname }}-md-cm-{{ $f.name }}

# AFTER (with truncation):
name: {{ printf "%s-md-cm-%s" $depFullname $f.name | trunc 63 | trimSuffix "-" }}
```

## Truncation Boundary Analysis

**Budget calculation for each resource type:**

Assuming release name = R chars, chart name = C chars (default "global-chart" = 12):
- `fullname` = `R-C` truncated to 63 (if R contains C, just R truncated to 63)
- Typical: R=10, C=12 -> fullname = 23 chars ("myrelease-global-chart")

| Resource | Formula | Budget for variable part | Safe max variable chars |
|----------|---------|------------------------|------------------------|
| deploymentFullname | `{fullname}-{deploy}` | 63 - len(fullname) - 1 | 39 (with 23-char fullname) |
| Root CronJob | `{fullname}-{cron}` | 52 - len(fullname) - 1 | 28 |
| Deploy CronJob | `{fullname}-{deploy}-{cron}` | 52 - len(fullname) - 1 | 28 total for deploy+cron |
| Root Hook | `{fullname}-{type}-{job}` | 63 - len(fullname) - 1 | 39 total for type+job |
| Deploy Hook | `{fullname}-{deploy}-{type}-{job}` | 63 - len(fullname) - 1 | 39 total |
| Mounted CM | `{depFullname}-md-cm-{name}` | **NO TRUNC** | BUG: overflows |
| ExternalSecret | `{fullname}-{name}` | **NO TRUNC** | BUG: overflows |

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `default true $val` | `hasKey` + `ternary` | Helm community best practice ~2022 | Prevents falsy-value masking |
| Duplicate template logic | Shared named templates via `include` | Standard Go template pattern | Single source of truth |
| No truncation validation | `trunc N \| trimSuffix "-"` everywhere | Helm scaffold default | Prevents K8s name rejections |

**Still outdated in this codebase:**
- `cronjob.yaml` line 47: `default true` on `automountServiceAccountToken`
- `cronjob.yaml` lines 63-64: `default 2` on history limits where 0 is valid
- `hook.yaml` lines 65, 81: `default "5"/"10"` on weight where "0" is valid
- Mounted ConfigMap and ExternalSecret names: missing truncation

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | helm-unittest (Docker-based, no local plugin) |
| Config file | None (uses default helm-unittest discovery) |
| Quick run command | `make unit-test` |
| Full suite command | `make unit-test && make lint-chart` |

### Phase Requirements -> Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| TMPL-01a | `automountServiceAccountToken: false` not masked | unit | `make unit-test` (cronjob_test.yaml) | Needs new test |
| TMPL-01b | `successfulJobsHistoryLimit: 0` not masked | unit | `make unit-test` (cronjob_test.yaml) | Needs new test |
| TMPL-01c | `hook weight: "0"` not masked | unit | `make unit-test` (hook_test.yaml) | Needs new test |
| TMPL-02 | CronJob inherits SA from `create:false + name` deploy | unit | `make unit-test` (cronjob_test.yaml) | Needs new test |
| TMPL-03a | Mounted ConfigMap name truncated at 63 | unit | `make unit-test` (deployment_test.yaml or mounted-configmap_test.yaml) | Needs new test |
| TMPL-03b | ExternalSecret name truncated at 63 | unit | `make unit-test` (externalsecret_test.yaml) | Needs new test |
| TMPL-03c | Deploy CronJob name at 52-char boundary | unit | `make unit-test` (cronjob_test.yaml) | Needs new test |
| TMPL-04 | Shared helper produces same output as current inline logic | unit | `make unit-test` (helpers_test.yaml or dedicated) | Needs new test |

### Sampling Rate
- **Per task commit:** `make unit-test`
- **Per wave merge:** `make unit-test && make lint-chart`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] New test cases in `cronjob_test.yaml` for falsy-value masking (TMPL-01a, TMPL-01b)
- [ ] New test cases in `hook_test.yaml` for falsy-value masking (TMPL-01c)
- [ ] New test case in `cronjob_test.yaml` for SA inheritance from `create: false` + `name` (TMPL-02)
- [ ] New test cases for truncation boundaries in relevant test files (TMPL-03)
- [ ] New test cases for shared helper output equivalence (TMPL-04)

*All tests will be created alongside the fixes -- the report-first approach means test gaps are expected at Wave 0.*

## Open Questions

1. **`replicaCount: 0` validity**
   - What we know: Currently `$deploy.replicaCount | default 2` would mask `0`. The field is only rendered when HPA is disabled.
   - What's unclear: Is `replicaCount: 0` a valid use case for this chart (scale-to-zero without HPA)?
   - Recommendation: Treat as MEDIUM risk; fix with `hasKey` to be safe, since 0 replicas is valid Kubernetes.

2. **Hook dnsConfig inheritance**
   - What we know: CronJobs inherit dnsConfig from deployment (cronjob.yaml lines 290-295). Hooks do NOT inherit dnsConfig (hook.yaml has no such logic).
   - What's unclear: Is this intentional or an oversight?
   - Recommendation: Document in AUDIT-REPORT.md as an asymmetry. The shared helper should support dnsConfig inheritance, controlled by a parameter, so hooks can opt in later if desired.

3. **EnvFrom inheritance for shared helper**
   - What we know: EnvFrom logic is complex -- it merges deployment's generated CM/Secret + deployment's external refs + job's external refs.
   - What's unclear: Whether this merge logic should be in the shared helper or stay inline.
   - Recommendation: Include in shared helper since it's identical between hook.yaml and cronjob.yaml. The helper receives `$deployFullname`, `$hasDeployConfigMap`, `$hasDeploySecret` as parameters.

## Sources

### Primary (HIGH confidence)
- `charts/global-chart/templates/_helpers.tpl` -- all 323 lines read and analyzed
- `charts/global-chart/templates/hook.yaml` -- all 424 lines read; reference implementation for SA inheritance
- `charts/global-chart/templates/cronjob.yaml` -- all 405 lines read; bug location confirmed at lines 183-186
- `charts/global-chart/templates/deployment.yaml` -- all 211 lines read; `default` calls cataloged
- All other template files read in full: service.yaml, ingress.yaml, hpa.yaml, pdb.yaml, networkpolicy.yaml, serviceaccount.yaml, externalsecret.yaml, rbac.yaml, configmap.yaml, secret.yaml
- `.planning/codebase/CONVENTIONS.md` -- established `hasKey` + `ternary` patterns
- `.planning/codebase/CONCERNS.md` -- confirmed CronJob SA asymmetry bug
- `.planning/codebase/ARCHITECTURE.md` -- inheritance data flow
- `.planning/research/PITFALLS.md` -- `default` masking, truncation risks

### Secondary (MEDIUM confidence)
- Kubernetes documentation on name length limits (63-char DNS label spec, 52-char CronJob limit due to Job suffix)
- Helm best practices for `hasKey` pattern (community consensus since 2022)

### Tertiary (LOW confidence)
- None -- all findings verified against source code

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- no new dependencies, pure template work
- Architecture: HIGH -- all patterns verified against existing codebase code
- Pitfalls: HIGH -- every finding verified by reading actual template lines
- Truncation analysis: HIGH -- every naming formula traced through source code

**Research date:** 2026-03-15
**Valid until:** Indefinite (template analysis, not library version-dependent)
