# Roadmap: Global Chart Quality Audit & Enhancement

## Overview

This roadmap takes global-chart from a mature but bug-carrying 1.3.0 to a hardened, deduplicated, fully-validated chart. The sequence is deliberate: fix correctness bugs first so tests document correct behavior, then close test gaps so refactoring is safe, then deduplicate templates while the test suite catches regressions, then enhance CI validation, and finally add input schema validation once the values structure is stable. New template features (probes, init containers, global labels) land alongside CI enhancement since the foundation is solid by that point.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Correctness Fixes** - Fix all falsy masking bugs and add missing validation guards
- [ ] **Phase 2: Test Coverage** - Close 23 untested fail-guard paths and add inheritance test suites
- [ ] **Phase 3: Template Deduplication** - Extract shared job pod spec helper and split helpers by domain
- [ ] **Phase 4: CI Pipeline & New Features** - Add kubeconform, promote kube-linter to CI, add probes/init containers/global labels
- [ ] **Phase 5: Values Schema** - Create values.schema.json for input validation and IDE autocomplete

## Phase Details

### Phase 1: Correctness Fixes
**Goal**: Chart produces correct manifests for all valid input combinations, including zero-values and explicit false
**Depends on**: Nothing (first phase)
**Requirements**: BUG-01, BUG-02, BUG-03, BUG-04, BUG-05, BUG-06
**Success Criteria** (what must be TRUE):
  1. Setting `successfulJobsHistoryLimit: 0` or `failedJobsHistoryLimit: 0` on a CronJob renders `0` in the manifest, not the default value
  2. Setting `automountServiceAccountToken: false` on a root-level CronJob renders `false`, not `true`
  3. `helm template` fails with a clear error when an Ingress host references a deployment that has `service.enabled: false`
  4. Pre-upgrade hooks that need ConfigMap/Secret data get hook-annotated copies with lower weight, ensuring correct ordering
  5. `helm template` fails with a clear error when truncated names would collide between different deployments, cronjobs, or hooks
**Plans:** 3 plans

Plans:
- [ ] 01-01-PLAN.md — Fix falsy masking in cronjob.yaml and hook.yaml, fix hook prerequisite weights
- [ ] 01-02-PLAN.md — Complete hasKey audit on remaining templates, add Ingress service.enabled validation
- [ ] 01-03-PLAN.md — Implement cross-kind name collision detection

### Phase 2: Test Coverage
**Goal**: Every fail-guard and inheritance path in the chart has a dedicated test proving it works
**Depends on**: Phase 1
**Requirements**: TEST-01, TEST-02, TEST-03, TEST-04
**Success Criteria** (what must be TRUE):
  1. All 30 `fail`/`required` paths have a corresponding `failedTemplate` test assertion that passes
  2. Deployment-level CronJob inheritance is tested across all seven categories (image, configMap, secret, SA, envFrom, scheduling, security)
  3. Deployment-level Hook inheritance is tested across all seven categories
  4. Deployment fields (strategy, probes, volumes, etc.) have dedicated coverage ensuring no regressions
  5. `make unit-test` passes with zero failures and test count is 243+
**Plans**: TBD

Plans:
- [ ] 02-01: TBD
- [ ] 02-02: TBD

### Phase 3: Template Deduplication
**Goal**: Hook and CronJob templates share a single pod spec helper, eliminating duplicated logic and reducing future maintenance to one location
**Depends on**: Phase 2
**Requirements**: REFAC-01, REFAC-02
**Success Criteria** (what must be TRUE):
  1. `_helpers.tpl` is split into domain-specific files (`_image-helpers.tpl`, `_job-helpers.tpl`, `_volume-helpers.tpl`) and all existing tests pass unchanged
  2. A shared `global-chart.jobPodSpec` helper renders the pod spec for both hooks and cronjobs
  3. `cronjob.yaml` and `hook.yaml` contain only orchestration logic (iteration, job-type-specific fields), not pod spec rendering
  4. All 243+ existing tests pass without modification after the refactor
**Plans**: TBD

Plans:
- [ ] 03-01: TBD
- [ ] 03-02: TBD

### Phase 4: CI Pipeline & New Features
**Goal**: CI catches schema violations and best-practice issues automatically; chart supports probes, init containers, and global labels
**Depends on**: Phase 3
**Requirements**: TEST-05, FEAT-01, FEAT-02, FEAT-03
**Success Criteria** (what must be TRUE):
  1. `make kubeconform` validates all test scenarios against K8s 1.29 schema and runs in CI on every PR
  2. `make kube-linter` runs in CI with pinned Docker image version and project-specific exclusions
  3. Users can configure liveness, readiness, and startup probes per deployment and they render correctly in the manifest
  4. Users can define a list of init containers per deployment that appear in the rendered pod spec
  5. Setting `global.commonLabels` or `global.commonAnnotations` applies them to every resource in the chart output
**Plans**: TBD

Plans:
- [ ] 04-01: TBD
- [ ] 04-02: TBD

### Phase 5: Values Schema
**Goal**: Chart consumers get immediate, descriptive validation errors for misconfigured values before any template rendering occurs
**Depends on**: Phase 4
**Requirements**: FEAT-04
**Success Criteria** (what must be TRUE):
  1. `helm lint` with an invalid values file (wrong type, missing required field) returns a clear error message referencing the offending field
  2. `values.schema.json` covers top-level keys, deployment required fields, and type constraints for the `deployments` map
  3. IDE autocomplete works for `values.yaml` when the schema is present (tested with VS Code YAML extension)
**Plans**: TBD

Plans:
- [ ] 05-01: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3 -> 4 -> 5

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Correctness Fixes | 0/3 | Planning complete | - |
| 2. Test Coverage | 0/? | Not started | - |
| 3. Template Deduplication | 0/? | Not started | - |
| 4. CI Pipeline & New Features | 0/? | Not started | - |
| 5. Values Schema | 0/? | Not started | - |
