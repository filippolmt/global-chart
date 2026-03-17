---
phase: 01-template-logic-audit-bug-fixes
plan: 01
subsystem: templates
tags: [helm, go-templates, hasKey, ternary, falsy-masking, hook-weight]

# Dependency graph
requires: []
provides:
  - Falsy-safe CronJob template (all scalar defaults converted to hasKey+ternary)
  - Falsy-safe Hook template with correct prerequisite weights and aggregated hook types
  - Established hasKey+ternary conversion pattern for remaining template audit
affects: [01-template-logic-audit-bug-fixes]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "hasKey+ternary for all scalar defaults in Helm templates"
    - "Prerequisite resources rendered once per deployment with aggregated hook types"
    - "Weight hierarchy: ConfigMap/Secret=3, SA=5, Job=10"

key-files:
  created: []
  modified:
    - charts/global-chart/templates/cronjob.yaml
    - charts/global-chart/templates/hook.yaml
    - charts/global-chart/tests/cronjob_test.yaml
    - charts/global-chart/tests/hook_test.yaml

key-decisions:
  - "Prerequisite ConfigMap/Secret named {deployFullname}-hook-config/secret (shared across hook commands in same deployment)"
  - "Root-level hook SA name resolved with if/else instead of ternary to handle nil from coalesce"
  - "SA weight always hardcoded to 5 (not overridable by command.weight)"

patterns-established:
  - "hasKey+ternary: replace `default <value> $var` with `ternary $var <default> (hasKey $map \"field\")`"
  - "Prerequisite rendering: compute shared resources outside hookType/command loops, per deployment"
  - "Hook type aggregation: `keys $deploy.hooks | sortAlpha | join \",\"`"

requirements-completed: [BUG-01, BUG-02, BUG-03, BUG-05]

# Metrics
duration: 12min
completed: 2026-03-17
---

# Phase 01 Plan 01: Falsy Masking Fixes Summary

**Converted all scalar default usages in cronjob.yaml and hook.yaml to hasKey+ternary, fixed hook prerequisite weight ordering (3/5/10), and aggregated hook types on prerequisites**

## Performance

- **Duration:** 12 min
- **Started:** 2026-03-17T12:28:34Z
- **Completed:** 2026-03-17T12:40:19Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- Eliminated all falsy masking bugs in cronjob.yaml (10 locations) and hook.yaml (8 locations)
- Restructured hook PART 2 to render prerequisite ConfigMap/Secret once per deployment with aggregated hook types
- Established correct weight hierarchy: ConfigMap/Secret=3, SA=5, Job=10
- Added 19 new tests covering zero-value, false-value, weight ordering, and hook type aggregation
- All 246 tests pass, lint and generate pass for all 15 test scenarios

## Task Commits

Each task was committed atomically:

1. **Task 1: Fix all default -> hasKey in cronjob.yaml + tests** - `932a1ce` (fix)
2. **Task 2: Fix all default -> hasKey in hook.yaml + fix prerequisite weights + fix hook type aggregation + tests** - `2d4e0a9` (fix)

## Files Created/Modified
- `charts/global-chart/templates/cronjob.yaml` - Converted 10 scalar default usages to hasKey+ternary
- `charts/global-chart/templates/hook.yaml` - Converted 8 scalar default usages, restructured prerequisite rendering, fixed weights
- `charts/global-chart/tests/cronjob_test.yaml` - Added 8 tests for zero/false value rendering and default preservation
- `charts/global-chart/tests/hook_test.yaml` - Added 11 tests for weights, hook type aggregation, default values; updated 1 existing test for new naming

## Decisions Made
- Prerequisite ConfigMap/Secret use `{deployFullname}-hook-config` naming instead of `{hookFullname}-config` since they are shared across all hook commands in a deployment
- Root-level hook SA name uses explicit if/else guard instead of ternary because `coalesce` returns nil (not empty string) when both inputs are nil, and `ne nil ""` evaluates to true in Go templates
- SA hook-weight is always hardcoded "5" (never uses `$command.weight`) since SA creation weight should not be user-overridable

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed nil coalesce causing empty SA name in root-level hooks**
- **Found during:** Task 2 (hook.yaml hasKey conversion)
- **Issue:** Plan suggested `ternary $commandSAExplicitName $hookFullname (ne $commandSAExplicitName "")` but `coalesce` returns nil (not ""), so `ne nil ""` evaluates to true, causing empty SA name
- **Fix:** Used explicit if/else guard: `$saName := $hookFullname; if $commandSAExplicitName: $saName = $commandSAExplicitName`
- **Files modified:** charts/global-chart/templates/hook.yaml
- **Verification:** `make lint-chart` passes (previously failed with empty name warnings under --strict)
- **Committed in:** 2d4e0a9 (Task 2 commit)

**2. [Rule 1 - Bug] Fixed deployment-level cronjob test document indices**
- **Found during:** Task 1 (cronjob test RED phase)
- **Issue:** Plan test cases for deployment-level cronjobs used documentIndex 0, but when no SA is on the deployment, cronjob creates its own SA at index 0, pushing CronJob to index 1
- **Fix:** Updated tests to use documentIndex 1 with isKind assertion to verify
- **Files modified:** charts/global-chart/tests/cronjob_test.yaml
- **Verification:** All tests pass
- **Committed in:** 932a1ce (Task 1 commit)

---

**Total deviations:** 2 auto-fixed (2 bugs)
**Impact on plan:** Both auto-fixes necessary for correctness. No scope creep.

## Issues Encountered
None beyond the documented deviations.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- hasKey+ternary pattern now established and proven in cronjob.yaml and hook.yaml
- Remaining templates (deployment.yaml, service.yaml, ingress.yaml, etc.) can follow the same pattern in subsequent plans
- BUG-04 (ingress service.enabled validation) and BUG-06 (name collision guard) remain for other plans in this phase

---
*Phase: 01-template-logic-audit-bug-fixes*
*Completed: 2026-03-17*
