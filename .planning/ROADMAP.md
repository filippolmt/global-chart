# Roadmap: Global Chart Quality Audit & Hardening

## Overview

A four-phase audit and hardening of the global-chart Helm chart, progressing in strict dependency order: fix template correctness first (the foundation everything else depends on), then harden test coverage (locks in fixes and catches regressions), then add schema validation and K8s best practices (hardens the user-facing interface), and finally strengthen the CI pipeline (validates the entire hardened chart automatically). Each phase delivers a coherent, verifiable quality improvement. The constraint throughout is backward compatibility -- no breaking changes to existing consumers.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Template Logic Audit & Bug Fixes** - Fix all template correctness issues: falsy-value masking, CronJob SA inheritance, truncation guards, and shared helper extraction (completed 2026-03-15)
- [ ] **Phase 2: Test Coverage Hardening** - Achieve comprehensive test coverage with regression tests, negative tests, seven-category patterns, and boundary tests
- [ ] **Phase 3: Schema & K8s Best Practices** - Add values.schema.json for input validation, secure security context defaults, multi-key ExternalSecret support, and automountServiceAccountToken hardening
- [ ] **Phase 4: CI Pipeline Hardening** - Integrate kubeconform, promote kube-linter to required gate, add Trivy advisory scanning, and multi-K8s-version matrix testing

## Phase Details

### Phase 1: Template Logic Audit & Bug Fixes
**Goal**: Every template renders correctly for all valid input combinations, and known bugs (CronJob SA inheritance, falsy-value masking) are fixed with regression tests
**Depends on**: Nothing (first phase)
**Requirements**: TMPL-01, TMPL-02, TMPL-03, TMPL-04
**Success Criteria** (what must be TRUE):
  1. Running `helm template` with `false`, `0`, or `""` as explicit values produces manifests that preserve those values (no silent replacement by defaults)
  2. CronJob SA inheritance behaves identically to Hook SA inheritance -- both support `create: true`, `create: false` with `name`, and per-job `serviceAccountName` override
  3. Resource names at the truncation boundary (63 and 52 chars) render correctly without silent truncation errors
  4. Hook and CronJob templates share a common inheritance helper -- changes to inheritance logic in one are reflected in the other
**Plans:** 3/3 plans complete

Plans:
- [ ] 01-01-PLAN.md — Audit report: catalog all template correctness findings for user approval
- [ ] 01-02-PLAN.md — Apply targeted fixes: falsy-value masking, CronJob SA inheritance, truncation guards
- [ ] 01-03-PLAN.md — Extract shared inheritance helper from hook.yaml/cronjob.yaml

### Phase 2: Test Coverage Hardening
**Goal**: Every template code path is tested, including failure paths, so that future changes to templates are caught by the test suite before they reach production
**Depends on**: Phase 1
**Requirements**: TEST-01, TEST-02, TEST-03, TEST-04
**Success Criteria** (what must be TRUE):
  1. Every bug fixed in Phase 1 has a corresponding regression test that fails if the fix is reverted
  2. Every `fail` and `required` call in templates has a negative test asserting the exact error message
  3. Each resource type with inheritance (Deployment, CronJob, Hook) has tests covering all seven categories: default, enabled, disabled, inheritance, override, explicit-empty, and failure
  4. `make unit-test` includes test cases with names at exactly 63 and 52 character limits, verifying correct truncation behavior
**Plans:** 3 plans

Plans:
- [ ] 02-01-PLAN.md — CronJob negative tests and seven-category inheritance coverage
- [ ] 02-02-PLAN.md — Hook and Deployment negative tests and seven-category coverage
- [ ] 02-03-PLAN.md — Simpler resource negative tests, boundary tests, edge cases, Phase 1 regression verification

### Phase 3: Schema & K8s Best Practices
**Goal**: Invalid or misspelled values are rejected at `helm install/template` time with clear error messages, and the chart provides secure defaults compatible with Pod Security Standards Restricted
**Depends on**: Phase 2
**Requirements**: K8S-01, K8S-02, K8S-03, K8S-04
**Success Criteria** (what must be TRUE):
  1. Running `helm template` with a misspelled key (e.g., `imagePullSecert`) fails with a schema validation error instead of silently ignoring it
  2. The default security context in values.yaml satisfies Pod Security Standards Restricted profile -- pods render with `runAsNonRoot`, `readOnlyRootFilesystem`, and dropped capabilities without the user specifying them
  3. A single ExternalSecret resource can map multiple keys from one secret store, reducing the number of ExternalSecret objects needed
  4. All pods default to `automountServiceAccountToken: false` unless explicitly overridden, preventing unnecessary API server access
**Plans**: TBD

Plans:
- [ ] 03-01: TBD
- [ ] 03-02: TBD

### Phase 4: CI Pipeline Hardening
**Goal**: The CI pipeline automatically validates rendered manifests against Kubernetes schemas, enforces best practices as a gate, and scans for security misconfigurations across multiple K8s versions
**Depends on**: Phase 3
**Requirements**: CI-01, CI-02, CI-03, CI-04
**Success Criteria** (what must be TRUE):
  1. `make kubeconform` validates all generated manifests against Kubernetes OpenAPI schemas and fails CI on schema violations (deprecated apiVersions, missing required fields)
  2. kube-linter runs as a required CI step (not optional) -- PR merges are blocked if kube-linter reports violations above the configured threshold
  3. `make trivy` scans rendered manifests for security misconfigurations and reports findings in CI output (advisory, not blocking initially)
  4. CI runs manifest validation against at least 3 Kubernetes versions (e.g., 1.28, 1.29, 1.30) to verify forward and backward compatibility
**Plans**: TBD

Plans:
- [ ] 04-01: TBD
- [ ] 04-02: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3 -> 4

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Template Logic Audit & Bug Fixes | 3/3 | Complete    | 2026-03-15 |
| 2. Test Coverage Hardening | 0/3 | Planned | - |
| 3. Schema & K8s Best Practices | 0/0 | Not started | - |
| 4. CI Pipeline Hardening | 0/0 | Not started | - |
