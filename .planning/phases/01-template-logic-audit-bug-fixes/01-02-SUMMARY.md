---
phase: 01-template-logic-audit-bug-fixes
plan: 02
subsystem: templates
tags: [helm, go-templates, hasKey, truncation, falsy-values, kubernetes]

requires:
  - phase: 01-01
    provides: Audit report identifying all falsy-value masking bugs, SA inheritance bug, and truncation gaps
provides:
  - Fixed falsy-value masking in cronjob, hook, and deployment templates using hasKey patterns
  - Fixed CronJob SA inheritance to match Hook SA inheritance (else if $deploySA.name)
  - Added truncation guards to mounted-configmap and externalsecret resource names
  - 13 regression tests covering all edge cases
affects: [01-03-refactor, test-coverage]

tech-stack:
  added: []
  patterns: [hasKey + if/else for integer defaults, hasKey + if/else for string defaults, printf + trunc 63 + trimSuffix for name construction]

key-files:
  created: []
  modified:
    - charts/global-chart/templates/cronjob.yaml
    - charts/global-chart/templates/hook.yaml
    - charts/global-chart/templates/deployment.yaml
    - charts/global-chart/templates/mounted-configmap.yaml
    - charts/global-chart/templates/externalsecret.yaml
    - charts/global-chart/tests/cronjob_test.yaml
    - charts/global-chart/tests/hook_test.yaml
    - charts/global-chart/tests/deployment_test.yaml
    - charts/global-chart/tests/mounted-configmap_test.yaml
    - charts/global-chart/tests/externalsecret_test.yaml

key-decisions:
  - "Used hasKey + if/else blocks (not ternary) for history limits and hook weights to match existing codebase patterns"
  - "Fixed whitespace trimming on automountServiceAccountToken block to avoid YAML concatenation with labels"

patterns-established:
  - "hasKey + if/else for integer fields where 0 is valid: successfulJobsHistoryLimit, failedJobsHistoryLimit, replicaCount"
  - "hasKey + if/else for string fields where '0' is valid: hook weight annotations"
  - "printf + trunc 63 + trimSuffix for all resource names that combine multiple user-provided segments"

requirements-completed: [TMPL-01, TMPL-02, TMPL-03]

duration: 4min
completed: 2026-03-15
---

# Phase 01 Plan 02: Template Fixes Summary

**Fixed 10 falsy-value masking bugs (automountServiceAccountToken, historyLimits, hook weight, replicaCount), CronJob SA inheritance from existing SA, and 5 missing truncation guards -- with 13 regression tests**

## Performance

- **Duration:** 4 min
- **Started:** 2026-03-15T20:21:15Z
- **Completed:** 2026-03-15T20:25:17Z
- **Tasks:** 2
- **Files modified:** 10

## Accomplishments
- All TMPL-01 falsy-value masking bugs fixed: `default true`, `default 2`, `default "5"/"10"` replaced with `hasKey` patterns in cronjob.yaml, hook.yaml, and deployment.yaml
- TMPL-02 CronJob SA inheritance bug fixed: added missing `else if $deploySA.name` branch to match hook.yaml behavior
- TMPL-03 truncation guards added to mounted-configmap (2 locations), deployment.yaml volume refs (2 locations), and externalsecret (1 location)
- 13 new regression tests: 6 for falsy-value masking, 4 for hook weights, 1 for CronJob SA inheritance, 2 for truncation boundaries
- All 239 tests pass, all lint scenarios clean

## Task Commits

Each task was committed atomically:

1. **Task 1: Fix falsy-value masking and CronJob SA inheritance** - `6720660` (fix)
2. **Task 2: Add truncation guards to mounted-configmap and externalsecret** - `72b0dab` (fix)

_Note: TDD tasks -- tests written first (RED), then fixes applied (GREEN)_

## Files Created/Modified
- `charts/global-chart/templates/cronjob.yaml` - hasKey patterns for automountServiceAccountToken, historyLimits; SA inheritance fix
- `charts/global-chart/templates/hook.yaml` - hasKey patterns for hook weight (4 locations: root SA/Job, deploy SA/Job)
- `charts/global-chart/templates/deployment.yaml` - hasKey for replicaCount; trunc 63 on mounted-configmap volume refs
- `charts/global-chart/templates/mounted-configmap.yaml` - trunc 63 on configmap names (files and bundles)
- `charts/global-chart/templates/externalsecret.yaml` - trunc 63 on $secretName
- `charts/global-chart/tests/cronjob_test.yaml` - 6 regression tests (automount false, historyLimit 0, SA inheritance)
- `charts/global-chart/tests/hook_test.yaml` - 4 regression tests (hook-weight 0 on root/deploy SA/Job)
- `charts/global-chart/tests/deployment_test.yaml` - 1 regression test (replicaCount 0)
- `charts/global-chart/tests/mounted-configmap_test.yaml` - 2 truncation boundary tests
- `charts/global-chart/tests/externalsecret_test.yaml` - 1 truncation boundary test

## Decisions Made
- Used `hasKey` + `if/else` blocks instead of `ternary` for integer/string defaults to maintain consistency with existing codebase patterns
- Fixed a YAML whitespace issue in root CronJob SA automountServiceAccountToken (leading `{{-` was eating the newline after labels, concatenating with last label line)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed YAML whitespace trimming on automountServiceAccountToken**
- **Found during:** Task 1 (GREEN phase)
- **Issue:** The `{{- end -}}` trim-right on the hasKey block ate the newline before `automountServiceAccountToken:`, concatenating it with the last label line
- **Fix:** Changed `{{- end -}}` to `{{- end }}` (removed trailing dash) to preserve the newline
- **Files modified:** charts/global-chart/templates/cronjob.yaml
- **Verification:** `make unit-test` passes, rendered output validated with `helm template --debug`
- **Committed in:** 6720660 (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** Necessary whitespace fix during template editing. No scope creep.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- All direct template fixes from the audit are complete
- Plan 01-03 (shared helper refactor) can proceed -- the fixed SA inheritance and hasKey patterns are now consistent between hook.yaml and cronjob.yaml, providing a solid foundation for extraction

---
*Phase: 01-template-logic-audit-bug-fixes*
*Completed: 2026-03-15*
