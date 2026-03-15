---
phase: 01-template-logic-audit-bug-fixes
plan: 03
subsystem: templates
tags: [helm, go-templates, refactoring, DRY, inheritance]

requires:
  - phase: 01-02
    provides: "Fixed SA inheritance, falsy-value masking, truncation guards"
provides:
  - "global-chart.inheritedJobPodSpec shared helper eliminating duplicated inheritance logic"
  - "Single edit location for deployment-level hook/cronjob inheritance changes"
affects: [template-testing, future-inheritance-additions]

tech-stack:
  added: []
  patterns: ["Shared helper for duplicated pod spec rendering via include + trim + nindent"]

key-files:
  created: []
  modified:
    - charts/global-chart/templates/_helpers.tpl
    - charts/global-chart/templates/hook.yaml
    - charts/global-chart/templates/cronjob.yaml

key-decisions:
  - "Canonical field ordering in shared helper (imagePullSecrets, hostAliases, securityContext, dnsConfig, initContainers, containers, volumes, serviceAccountName, nodeSelector, affinity, tolerations, restartPolicy) -- differs from original per-template order but is semantically equivalent"
  - "Helper output trimmed via pipe (include | trim | nindent) to avoid leading blank lines from conditional blocks"
  - "SA resolution, SA resource creation, and job metadata stay in callers (hook-specific annotations, weight handling differ between hooks and cronjobs)"

patterns-established:
  - "Shared helper pattern: include + trim + nindent for large conditional blocks"
  - "Parameters as dict with pre-resolved values (imageRef, saName, deployFullname) to keep helper focused on rendering"

requirements-completed: [TMPL-04]

duration: 9min
completed: 2026-03-15
---

# Phase 01 Plan 03: Shared Inheritance Helper Summary

**Extracted duplicated deployment-level inheritance logic (~260 lines) into single inheritedJobPodSpec helper, reducing hook.yaml and cronjob.yaml by 77 net lines**

## Performance

- **Duration:** 9 min
- **Started:** 2026-03-15T20:27:35Z
- **Completed:** 2026-03-15T20:37:03Z
- **Tasks:** 1
- **Files modified:** 3

## Accomplishments
- Created `global-chart.inheritedJobPodSpec` shared helper in `_helpers.tpl` consolidating 15 inherited fields
- Refactored hook.yaml deployment-level section to call shared helper (removed ~120 lines of inline logic)
- Refactored cronjob.yaml deployment-level section to call shared helper (removed ~140 lines of inline logic)
- All 239 unit tests pass across 16 suites, all 16 lint scenarios pass
- Future inheritance changes (e.g., adding a new inherited field) need only one edit location

## Task Commits

Each task was committed atomically:

1. **Task 1: Create shared inheritedJobPodSpec helper and refactor hook.yaml + cronjob.yaml** - `6cfb131` (refactor)

**Plan metadata:** pending (docs: complete plan)

## Files Created/Modified
- `charts/global-chart/templates/_helpers.tpl` - Added inheritedJobPodSpec helper (~150 lines) rendering pod-level and container-level inherited fields
- `charts/global-chart/templates/hook.yaml` - Replaced PART 2 inline inheritance with shared helper call
- `charts/global-chart/templates/cronjob.yaml` - Replaced PART 2 inline inheritance with shared helper call

## Decisions Made
- Used canonical field ordering in the shared helper rather than matching each template's original order -- this changes field position in rendered YAML but is semantically equivalent (all tests pass)
- Applied `| trim | nindent N` pattern in callers to handle leading/trailing whitespace from conditional helper blocks
- Kept SA resolution, SA resource creation, hook annotations, and job metadata outside the helper since these have hook-specific vs cronjob-specific differences

## Deviations from Plan

None - plan executed as written. The field reordering in rendered output (serviceAccountName, restartPolicy, resources position) is a cosmetic difference; all values and nesting are preserved.

## Issues Encountered
- Go template whitespace management required multiple iterations to avoid blank lines in output -- resolved with `trim` pipe before `nindent`

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Phase 01 (Template Logic Audit & Bug Fixes) is now complete: audit report (01-01), fixes (01-02), shared helper refactor (01-03)
- All templates produce valid Kubernetes manifests
- Ready to proceed to Phase 02

## Self-Check: PASSED

- [x] _helpers.tpl exists and contains `inheritedJobPodSpec` definition
- [x] hook.yaml exists and contains `include "global-chart.inheritedJobPodSpec"`
- [x] cronjob.yaml exists and contains `include "global-chart.inheritedJobPodSpec"`
- [x] Commit 6cfb131 found in git log
- [x] 01-03-SUMMARY.md exists
- [x] All 239 unit tests pass
- [x] All 16 lint scenarios pass

---
*Phase: 01-template-logic-audit-bug-fixes*
*Completed: 2026-03-15*
