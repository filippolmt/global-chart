# Phase 1: Template Logic Audit & Bug Fixes - Context

**Gathered:** 2026-03-15
**Status:** Ready for planning

<domain>
## Phase Boundary

Fix all template correctness issues: audit every `default` call and falsy-value pattern, fix CronJob SA inheritance asymmetry with Hooks, verify truncation guards on all resource names, and extract shared inheritance helper from hook.yaml/cronjob.yaml. Report findings first, then fix after approval.

</domain>

<decisions>
## Implementation Decisions

### Audit approach
- Report-first approach: complete audit → AUDIT-REPORT.md with all findings → user approval → fix batch
- Audit scope is comprehensive: `default` calls + `if/else` on falsy values + global fallback chains + `required`/`fail` paths
- Report format: `.planning/phases/01-*/AUDIT-REPORT.md` with finding/severity/fix table

### Helper extraction
- Extract full pod spec inheritance into a single shared helper (e.g., `global-chart.inheritedJobPodSpec`)
- Covers: SA resolution, imagePullSecrets, hostAliases, podSecurityContext, securityContext, nodeSelector, tolerations, affinity, envFrom, env inheritance
- Scope: deployment-level hooks/cronjobs only — root-level have different logic (fromDeployment, no inheritance) and stay separate
- Helper returns a rendered string block (Go template constraint); callers use `include` + `nindent`

### Backward compatibility
- Falsy-value masking fixes are applied directly (hasKey+ternary replacing incorrect `default`): if a user passed `false`, they intended it
- CronJob SA bug is classified as a bugfix, not breaking change: users with `serviceAccount.create: false` + `name` expected CronJob to inherit it
- No deprecation warnings needed for correctness fixes

### Truncation scope
- Complete analysis: calculate worst-case name length for every resource type and verify `trunc` is applied correctly
- Standard Helm truncation: `trunc N | trimSuffix "-"` — no smart word-boundary truncation
- Check all naming helpers and inline `printf` calls for consistent truncation

### Claude's Discretion
- Exact structure and severity levels for AUDIT-REPORT.md
- Order of findings in the report
- Grouping strategy for related findings
- Implementation details of the shared helper's dict interface

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Template conventions
- `.planning/codebase/CONVENTIONS.md` — Boolean field handling patterns, inheritance pattern, global fallback chains, hasKey vs zero value
- `.planning/codebase/CONCERNS.md` — Known bugs (CronJob SA asymmetry), tech debt (duplicate inheritance), fragile areas (hookfullname, ingress guards)

### Architecture
- `.planning/codebase/ARCHITECTURE.md` — Data flow for inheritance, image resolution, global fallback chains
- `CLAUDE.md` — Helper catalog, design patterns, naming conventions, working guidelines

### Source files (primary audit targets)
- `charts/global-chart/templates/_helpers.tpl` — All helper functions to audit
- `charts/global-chart/templates/hook.yaml` — Hook template with inheritance logic (reference implementation)
- `charts/global-chart/templates/cronjob.yaml` — CronJob template with divergent inheritance (bug location)
- `charts/global-chart/templates/deployment.yaml` — Deployment template with configMap/secret SHA annotations

### Research findings
- `.planning/research/PITFALLS.md` — Go template pitfalls, `default` masking, helm-unittest limitations
- `.planning/research/FEATURES.md` — Feature gaps and enterprise readiness assessment

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `global-chart.deploymentServiceAccountName` helper: already handles SA resolution for Deployments — can inform the shared helper design
- `global-chart.renderImagePullSecrets`, `global-chart.renderDnsConfig`, `global-chart.renderResources`: existing shared helpers that demonstrate the `include` + `with` + `nindent` pattern

### Established Patterns
- `hasKey` + `ternary` for boolean fields with `true` default: `ternary $map.field true (hasKey $map "field")`
- `hasKey` for inheritance override: `ternary $job.field $deploy.field (hasKey $job "field")`
- `default (dict)` for nil safety on optional nested maps
- `-}}` trim on conditional lines before literal content in shared helpers

### Integration Points
- Hook SA inheritance (lines 196-234 in hook.yaml) is the reference implementation for the shared helper
- CronJob SA inheritance (lines 177-207 in cronjob.yaml) is the buggy counterpart to align
- Both hook.yaml and cronjob.yaml have root-level and deployment-level sections — only deployment-level gets the shared helper

</code_context>

<specifics>
## Specific Ideas

No specific requirements — open to standard approaches. The user wants a thorough, methodical audit with clear reporting before any code changes.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 01-template-logic-audit-bug-fixes*
*Context gathered: 2026-03-15*
