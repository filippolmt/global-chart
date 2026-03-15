# Project Research Summary

**Project:** global-chart Helm Chart Audit & Hardening
**Domain:** Helm chart quality, validation tooling, and Kubernetes security hardening
**Researched:** 2026-03-15
**Confidence:** HIGH

## Executive Summary

global-chart is a production-grade Helm 3 chart at v1.3.0 with a genuine differentiator: multi-deployment fan-out (frontend + backend + worker in a single `helm install`) combined with deployment-scoped Job/CronJob inheritance. The chart already has a solid foundation — 220 unit tests across 16 suites, kube-linter support, helm-docs, and extensive compile-time `fail` guards. The recommended approach is a phased audit-and-hardening effort rather than a rewrite, preserving the architectural strengths while closing four critical gaps: missing `values.schema.json`, a known CronJob SA inheritance asymmetry, absence of kubeconform in CI, and empty security context defaults.

The highest-leverage improvement is a `values.schema.json`. Without it, Helm silently ignores misspelled keys (`imagePullSecert` instead of `imagePullSecrets`) and wrong types, making the chart unsafe for multi-team or external use. The second most impactful change is adding kubeconform to CI — the chart generates manifests in CI today but never validates them against Kubernetes OpenAPI schemas, meaning a deprecated apiVersion or malformed resource structure would only be caught at `kubectl apply` time. These two additions together close the "looks tested but isn't" gap that affects 93% of Helm charts in the wild.

The main risk in hardening is backward compatibility. Security improvements like defaulting `automountServiceAccountToken` to `false` or adding `runAsNonRoot: true` as a default will break existing consumers. The mitigation is to treat default changes as major-version (v2.0.0) territory, using a `values-hardened.yaml` overlay and `NOTES.txt` warnings in the interim. Every fix PR must be evaluated against this constraint before merging.

## Key Findings

### Recommended Stack

The current stack (helm lint, helm-unittest, kube-linter, helm-docs) covers syntax, template logic, and best-practice checks but has two structural gaps: **schema validation** and **manifest conformance**. These are not redundant with existing tools — each layer catches distinct classes of bugs. The layered CI pipeline model is well-established: lint (syntax) → unit-test (logic) → kubeconform (K8s schema conformance) → kube-linter (best practices) → trivy (security misconfigs).

**Core technologies:**
- `values.schema.json` (Helm built-in): Input validation at `helm install/template` time — enforces types, enums, required fields. Single highest-impact quality improvement. Generate initial draft with `helm-values-schema-json` plugin (v1.7.2), then hand-tune.
- `kubeconform` (v0.7.0): Validates rendered YAML against Kubernetes OpenAPI schemas. Catches deprecated apiVersions, missing required fields, typos in resource kinds. Fast, Docker-compatible, CRD schema support via CRDs-catalog.
- `trivy config` (v0.69.3): Security misconfiguration scanning on rendered manifests. Complements kube-linter with 150+ checks covering privilege escalation, capabilities, seccomp. Run on `helm template` output.
- `polaris` (v10.1.1): Best-practice audit with numeric scoring. Run as advisory gate (`--set-exit-code-below-score 80`) to measure hardening progress.
- `chart-testing` (v3.14.0): Install/upgrade testing on real cluster. Valuable long-term but out of scope for this project's current phase (no cluster in CI).

**Tools NOT to use:** kubeval (deprecated, replaced by kubeconform), Datree SaaS (shut down 2023), helm-schema-gen by karuppiah7890 (unmaintained).

### Expected Features

The feature research distinguishes what already exists, what is broken, and what is missing. The chart's core differentiators (multi-deployment, job inheritance) are already implemented. The gap is in quality infrastructure and security posture.

**Must have (table stakes for v1.4.0):**
- `values.schema.json` — every serious Helm chart validates input; without it the chart is untrustworthy for multi-team use
- Fix CronJob SA inheritance asymmetry — known bug where CronJobs miss the `create: false` + `name` path that Hooks have; asymmetric behavior between equivalent features is a correctness defect
- Secure-by-default `securityContext` — clusters with PSS Restricted enforcement reject pods with empty security context; current `{}` defaults fail admission
- Configurable test-connection image — `busybox:1.36` is hardcoded; blocks air-gapped cluster adoption
- `hookType` and `restartPolicy` enum validation via `fail` — currently any string is accepted; wrong casing silently produces a non-functioning job

**Should have (v1.5.0 quality gate):**
- kubeconform in CI — manifests are generated but never schema-validated
- Negative test coverage for all `fail`/`required` paths — 220 tests exist but most are happy-path only
- Multi-key ExternalSecret support — current single-key design requires N ExternalSecret objects for N keys from one store
- Template deduplication (shared job pod spec helper) — eliminate hook.yaml / cronjob.yaml inheritance logic duplication to prevent future drift

**Defer to v2.0.0 (breaking changes):**
- `automountServiceAccountToken` default → `false` — security best practice but breaks IRSA/GCP Workload Identity users
- Remove legacy volume `.type` format — tech debt cleanup, backward compatibility concern
- RBAC positional naming fix — requires explicit `name` per role, changes current index-based naming

**Anti-features to avoid:** library chart rearchitecture (massive rewrite, no user value), StatefulSet/DaemonSet support (scope creep, doubles template complexity), `global.env` (implicit inheritance causes confusing debugging).

### Architecture Approach

The audit should proceed as a multi-layer validation pipeline applied in dependency order: template logic correctness first (bugs in templates invalidate test assertions), then test coverage (validates fixes and catches regressions), then K8s best practices and schema (configuration-level hardening on a correct base), then feature gaps and CI hardening (new capabilities added to a solid foundation). This order prevents the anti-pattern of writing tests against broken behavior or adding features to templates that have unresolved correctness issues.

**Major components:**
1. **Template Logic Audit** — systematic review of all 13 templates + `_helpers.tpl` against project conventions (hasKey+ternary for booleans, `default (dict)` for optional maps, trim-right on shared helpers). Output: categorized findings for user approval before any fixes.
2. **Test Coverage Gap Analysis** — map all code paths in 16 test suites, identify missing negative tests, inheritance edge cases, and long-name truncation tests. Run in parallel with Template Logic Audit.
3. **Schema + Best Practices Layer** — create `values.schema.json` with enum constraints, required fields, and `additionalProperties: false` at critical levels. Add secure security context guidance in values.yaml. Review kube-linter config exclusions.
4. **CI Pipeline Hardening** — integrate kubeconform and promote kube-linter from optional to required in GitHub Actions workflow. Add kubeconform Makefile target that runs against `generated-manifests/`.

### Critical Pitfalls

1. **`default` silently swallows `false`, `0`, and `""`** — Go's `default` replaces any falsy value (including explicit `false`). Use `hasKey` + `ternary` instead: `ternary $val true (hasKey $map "field")`. Every `default true` or `default false` call in templates must be audited. This is the most common silent misconfiguration source in Helm charts.

2. **No `values.schema.json` means typos pass silently** — `imagePullSecert` is accepted without error; the deployment runs without pull secrets and fails with `ImagePullBackOff` in the cluster. `helm lint --strict` does not catch this. Only a schema catches it at render time.

3. **Hook/CronJob logic drift from copy-paste** — inheritance logic is duplicated ~200 lines each across `hook.yaml` and `cronjob.yaml`. The existing CronJob SA asymmetry bug proves drift is already happening. Fix the immediate bug; plan extraction to shared helper to prevent recurrence.

4. **Breaking backward compatibility during hardening** — changing defaults (securityContext, automountServiceAccountToken) is a breaking change disguised as a best practice. Never change defaults in a minor/patch release. Use `values-hardened.yaml` overlays and `NOTES.txt` warnings until v2.0.0.

5. **Test false confidence from 220 passing tests** — helm-unittest cannot validate Kubernetes API correctness (`restartPolicy: Sometimes` passes tests but fails `kubectl apply`), cannot check multi-resource relationships (Service selector vs Deployment labels), and cannot test upgrade paths. Layer kubeconform and kube-linter on top of unit tests.

## Implications for Roadmap

Based on combined research, the audit and hardening work should be structured as four phases in strict dependency order.

### Phase 1: Template Logic Audit and Bug Fixes

**Rationale:** Template correctness is the foundation. All subsequent work (tests, schema, CI) depends on templates being correct. An audit without fixes first would be writing tests against broken behavior. The existing CronJob SA inheritance bug is a concrete known defect that must be fixed before coverage gaps can be meaningfully addressed.

**Delivers:** Categorized findings report (audit output), then a fix batch with regression tests for each fix. Templates verified against project conventions (CONVENTIONS.md). Immediate bug fixes: CronJob SA inheritance asymmetry, configurable test-connection image, hookType/restartPolicy enum validation, any `default` calls masking falsy values, any missing `default (dict)` nil guards.

**Addresses from FEATURES.md:** Fix CronJob SA inheritance, hookType enum validation, configurable test image — all P1 items.

**Avoids from PITFALLS.md:** `default` masking falsy values (systematic grep + replacement), nil pointer panics (audit every nested map access), hook/CronJob logic drift (fix SA bug now, plan shared helper).

**Note:** This phase should follow a "report first, fix after user approval" pattern per the project's own decision in PROJECT.md.

### Phase 2: Test Coverage Hardening

**Rationale:** Template fixes from Phase 1 need regression tests to prevent recurrence. The seven-category test model (default/enabled/disabled/inheritance/override/explicit-empty/failure) is the industry-standard for charts with inheritance logic. Negative tests (testing `failedTemplate`) must be added for every `fail`/`required` path to prove validation actually works.

**Delivers:** Comprehensive test coverage for all inheritance chains (per-field, seven categories), negative tests for all `fail` paths, long-name truncation edge cases. Measurably higher confidence in template correctness.

**Uses from STACK.md:** helm-unittest (already in CI), expanded to cover `failedTemplate` assertions.

**Avoids from PITFALLS.md:** Test false confidence, name truncation collisions (add long-name test cases).

**Research flag:** Standard patterns — helm-unittest negative test patterns are well-documented. No additional research needed.

### Phase 3: Schema Creation and K8s Best Practices

**Rationale:** With correct templates and comprehensive tests, this phase hardens the user-facing interface. `values.schema.json` is the single highest-impact quality improvement for a reusable chart — it prevents the silent typo class of bugs entirely. Security context guidance addresses PSS Restricted cluster compatibility without breaking existing consumers.

**Delivers:** `values.schema.json` with enum constraints for restartPolicy/concurrencyPolicy/hookType/strategy.type, required field markers for image, type constraints, additionalProperties checks at critical levels. Secure-by-default security context values in values.yaml (as documented recommendations, not enforced defaults — backward compat). Review and tighten kube-linter config exclusions. Multi-key ExternalSecret support.

**Uses from STACK.md:** `helm-values-schema-json` plugin (v1.7.2) to bootstrap schema from values.yaml annotations; manual refinement for complex conditionals.

**Addresses from FEATURES.md:** values.schema.json (P1), multi-key ExternalSecret (P2), template deduplication shared helper (P2).

**Avoids from PITFALLS.md:** Missing schema / silent typos (direct fix), backward-compat breaking changes (add as documentation and overlays, not as default changes).

**Research flag:** Schema creation for a complex chart with `additionalProperties: { "$ref": ... }` patterns for the deployments map may benefit from a targeted research session during planning, specifically for JSON Schema Draft 7 `oneOf` patterns for the image field (string or map).

### Phase 4: CI Pipeline Hardening and Feature Gaps

**Rationale:** By Phase 4 the chart is correct, well-tested, and has input validation. Adding CI tools at this point validates the entire hardened chart rather than adding tools before fixes are in place. kubeconform and kube-linter in CI become mandatory gates, not advisory tools.

**Delivers:** kubeconform integrated into GitHub Actions workflow and Makefile (`make kubeconform` target using Docker image `ghcr.io/yannh/kubeconform:v0.7.0`). kube-linter promoted from optional to required CI step. Trivy config scan added (advisory initially). Multi-Kubernetes-version schema matrix (1.27–1.30) for forward/backward compatibility. CHANGELOG automation for ArtifactHub compliance.

**Uses from STACK.md:** kubeconform v0.7.0 with CRDs-catalog schema source for ExternalSecret validation; trivy v0.69.3; polaris v10.1.1 (advisory score gate).

**Addresses from FEATURES.md:** Kubeconform in CI (P1), multi-K8s-version matrix (P2), CHANGELOG (P2).

**Avoids from PITFALLS.md:** kube-linter not in CI (direct fix), kubeconform absent (direct fix), test false confidence (layered validation closes the gap).

**Research flag:** Standard patterns — CI pipeline integration for kubeconform and kube-linter are well-documented. No additional research needed.

### Phase Ordering Rationale

- **Templates before tests** because tests assert on rendered output; asserting on broken output locks in incorrect behavior.
- **Tests before schema** because schema creation requires knowing the actual valid value combinations, which only systematic testing reveals.
- **Schema before CI tools** because kubeconform validates manifests rendered from values that may include schema-invalid inputs; schema must exist first so CI tools validate a coherent surface.
- **Backward compatibility is cross-cutting** and must be evaluated at every phase before merging any PR that changes template behavior or defaults.

### Research Flags

Phases needing deeper research during planning:
- **Phase 3:** JSON Schema Draft 7 patterns for the `deployments` map (`additionalProperties` with `$ref` for complex nested objects) and the `image` field (`oneOf` for string/map). The chart's schema surface area is large and the multi-deployment map pattern is not commonly documented. Consider a targeted research session during phase planning.

Phases with standard patterns (skip research-phase):
- **Phase 1:** Template audit patterns and `hasKey`+`ternary` corrections are fully documented in CONVENTIONS.md and the project's existing codebase.
- **Phase 2:** helm-unittest negative test patterns (`failedTemplate`, `matchErrorRegex`) are well-documented in the helm-unittest docs.
- **Phase 4:** kubeconform Makefile/CI integration is straightforward and documented in the tool's README.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Versions verified via GitHub releases pages. kubeconform, trivy, polaris, kube-linter all confirmed current. kubeval/Datree deprecations verified. |
| Features | HIGH | Grounded in codebase analysis of actual v1.3.0 code + competitor chart comparison (Bitnami, bjw-s, Stakater). Feature gaps are concrete, not speculative. |
| Architecture | HIGH | Multi-layer audit pipeline is an established pattern. Phase ordering is based on dependency analysis of the actual codebase. Seven-category test model is documented best practice. |
| Pitfalls | HIGH | Pitfalls grounded in codebase analysis (CONCERNS.md, CONVENTIONS.md) plus verified community patterns. CronJob SA asymmetry is a confirmed existing bug, not a hypothetical. |

**Overall confidence:** HIGH

### Gaps to Address

- **Schema complexity for multi-deployment map:** The `deployments` map uses `additionalProperties` with arbitrarily nested objects. Generating a schema that is both strict enough to catch typos and flexible enough not to reject valid advanced configs (e.g., arbitrary `podAnnotations`) requires careful tuning. Plan for manual iteration after the generated baseline.
- **kube-linter config baseline:** The existing `.kube-linter-config.yaml` exclusions have not been reviewed as part of this research. Some exclusions may be hiding real issues (anti-pattern 2 from ARCHITECTURE.md). This review is a Phase 3 deliverable.
- **Backward-compat surface area unknown:** The full set of external consumers and their values files is unknown. Default changes in Phase 3 (security contexts) should be opt-in with a hardened overlay rather than changing values.yaml defaults until a breaking-change version is planned.

## Sources

### Primary (HIGH confidence)
- [Helm JSON Schema validation](https://www.arthurkoziel.com/validate-helm-chart-values-with-json-schemas/) — schema creation patterns, native Helm enforcement behavior
- [kubeconform GitHub](https://github.com/yannh/kubeconform) — v0.7.0 confirmed, CRD schema location patterns
- [Trivy Helm coverage](https://trivy.dev/docs/latest/coverage/iac/helm/) — v0.69.3, chart auto-detection
- [Polaris GitHub](https://github.com/FairwindsOps/polaris) — v10.1.1, `--helm-chart` flag behavior
- [kube-linter releases](https://github.com/stackrox/kube-linter/releases) — v0.8.1 confirmed
- [Pod Security Standards (Kubernetes official)](https://kubernetes.io/docs/concepts/security/pod-security-standards/) — restricted profile requirements
- [helm-unittest documentation](https://github.com/helm-unittest/helm-unittest/blob/main/DOCUMENT.md) — failedTemplate assertions
- Codebase analysis: `.planning/codebase/CONCERNS.md`, `.planning/codebase/CONVENTIONS.md`

### Secondary (MEDIUM confidence)
- [The Real State of Helm Chart Reliability (2025)](https://www.prequel.dev/blog-post/the-real-state-of-helm-chart-reliability-2025-hidden-risks-in-100-open-source-charts) — 93% overprivileged SA finding, audit of 100+ charts
- [Helm Chart Testing Best Practices](https://alexandre-vazquez.com/helm-chart-testing-best-practices/) — layered pipeline model
- [Quality Gate for Helm Charts](https://medium.com/@michamarszaek/quality-gate-for-helm-charts-f260f5742198) — polaris scoring approach
- [helm-values-schema-json GitHub](https://github.com/losisin/helm-values-schema-json) — v1.7.2, generation from annotations
- [Bitnami Best Practices for Hardening Helm Charts](https://docs.bitnami.com/tutorials/bitnami-best-practices-hardening-charts) — secure defaults, automountServiceAccountToken

### Tertiary (LOW confidence)
- [chart-testing GitHub](https://github.com/helm/chart-testing) — v3.14.0, install/upgrade testing (out of scope for current phase; no cluster in CI)
- [Kubescape GitHub](https://github.com/kubescape/kubescape) — multi-framework compliance (excluded as overkill for this project's scope)

---
*Research completed: 2026-03-15*
*Ready for roadmap: yes*
