---
phase: 01-template-logic-audit-bug-fixes
plan: 02
subsystem: templates
tags: [helm, hasKey, ternary, falsy-safe, ingress-validation]

# Dependency graph
requires:
  - phase: 01-template-logic-audit-bug-fixes/01
    provides: hasKey pattern established in cronjob/hook templates
provides:
  - All scalar default usages converted to hasKey + ternary across deployment, service, ingress, hpa, rbac, externalsecret, test-connection
  - Ingress cross-resource validation for service.enabled: false
affects: [01-template-logic-audit-bug-fixes/03, testing]

# Tech tracking
tech-stack:
  added: []
  patterns: [hasKey + ternary for all scalar defaults, cross-resource validation with fail]

key-files:
  created: []
  modified:
    - charts/global-chart/templates/deployment.yaml
    - charts/global-chart/templates/service.yaml
    - charts/global-chart/templates/ingress.yaml
    - charts/global-chart/templates/hpa.yaml
    - charts/global-chart/templates/rbac.yaml
    - charts/global-chart/templates/externalsecret.yaml
    - charts/global-chart/templates/tests/test-connection.yaml
    - charts/global-chart/tests/deployment_test.yaml
    - charts/global-chart/tests/ingress_test.yaml

key-decisions:
  - "Preserved default (dict) nil-guards in ingress.yaml (lines 5, 52) as they are not scalar defaults"
  - "Moved $depSvc definition before service.enabled validation to avoid duplicate variable"

patterns-established:
  - "hasKey + ternary: canonical pattern for all scalar defaults in all templates"
  - "Cross-resource validation: ingress validates deployment service availability before rendering"

requirements-completed: [BUG-03, BUG-04]

# Metrics
duration: 6min
completed: 2026-03-17
---

# Phase 01 Plan 02: hasKey Audit + Ingress Validation Summary

**Complete hasKey + ternary conversion across 7 templates (24 scalar defaults) plus Ingress service.enabled: false cross-resource validation**

## Performance

- **Duration:** 6 min
- **Started:** 2026-03-17T12:28:36Z
- **Completed:** 2026-03-17T12:34:17Z
- **Tasks:** 2
- **Files modified:** 9

## Accomplishments
- Converted all 24 scalar `default` usages to `hasKey` + `ternary` across deployment, service, ingress, hpa, rbac, externalsecret, and test-connection templates
- Added Ingress validation that fails with actionable error when host references a deployment with `service.enabled: false`
- Added 4 new tests: replicaCount zero-value, ingress service.enabled false/true/absent
- All 246 existing + new tests pass

## Task Commits

Each task was committed atomically:

1. **Task 1: Convert all default -> hasKey (RED)** - `1027b13` (test)
2. **Task 1: Convert all default -> hasKey (GREEN)** - `06e8b31` (feat)
3. **Task 2: Ingress service.enabled validation (RED)** - `780edf1` (test)
4. **Task 2: Ingress service.enabled validation (GREEN)** - `6838417` (feat)

_TDD tasks have RED (test) + GREEN (feat) commits._

## Files Created/Modified
- `charts/global-chart/templates/deployment.yaml` - hasKey for replicaCount, portName, port, protocol
- `charts/global-chart/templates/service.yaml` - hasKey for type, port, targetPort, protocol, portName
- `charts/global-chart/templates/ingress.yaml` - hasKey for ports/pathType + service.enabled validation
- `charts/global-chart/templates/hpa.yaml` - hasKey for CPU/memory utilization percentages
- `charts/global-chart/templates/rbac.yaml` - hasKey for roleName, saName
- `charts/global-chart/templates/externalsecret.yaml` - hasKey for conversionStrategy, decodingStrategy, metadataPolicy, refreshInterval, creationPolicy, deletionPolicy, target name
- `charts/global-chart/templates/tests/test-connection.yaml` - hasKey for svc.port
- `charts/global-chart/tests/deployment_test.yaml` - New test for replicaCount: 0
- `charts/global-chart/tests/ingress_test.yaml` - 3 new tests for service.enabled validation

## Decisions Made
- Preserved `default (dict)` nil-guards in ingress.yaml as they protect against nil maps, not scalar defaults
- Moved `$depSvc` variable definition before the service.enabled check to avoid duplicate definition and keep variable reuse clean

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
- Pre-existing hook_test.yaml failures from plan 01-01 uncommitted work detected. Not caused by our changes. Logged to deferred-items.md.
- Pre-existing lint failure in hook.yaml (naming convention warnings). Not caused by our changes.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- All scalar defaults across all templates now use hasKey + ternary pattern
- Ingress cross-resource validation in place
- Ready for plan 01-03 (remaining template fixes)

---
*Phase: 01-template-logic-audit-bug-fixes*
*Completed: 2026-03-17*
