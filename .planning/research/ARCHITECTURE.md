# Architecture Research

**Domain:** Helm chart quality audit and hardening
**Researched:** 2026-03-15
**Confidence:** HIGH

## Standard Architecture

### Audit System Overview

A Helm chart quality audit is structured as a multi-layer validation pipeline. Each layer catches a different class of defect, and findings from earlier layers inform what to look for in later ones.

```
┌─────────────────────────────────────────────────────────────────┐
│                    Layer 1: STATIC ANALYSIS                     │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐  ┌──────────────┐   │
│  │ helm lint│  │ yamllint │  │ Template  │  │ values.schema│   │
│  │ --strict │  │          │  │ Logic     │  │ .json        │   │
│  │          │  │          │  │ Review    │  │ Validation   │   │
│  └─────┬────┘  └─────┬────┘  └─────┬─────┘  └──────┬───────┘   │
│        │             │             │               │            │
├────────┴─────────────┴─────────────┴───────────────┴────────────┤
│                    Layer 2: RENDERED MANIFEST VALIDATION         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │
│  │ kubeconform  │  │ kube-linter  │  │ polaris / conftest   │   │
│  │ (K8s schema) │  │ (best pract.)│  │ (custom policies)    │   │
│  └──────┬───────┘  └──────┬───────┘  └──────────┬───────────┘   │
│         │                 │                      │              │
├─────────┴─────────────────┴──────────────────────┴──────────────┤
│                    Layer 3: UNIT TESTS                           │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │              helm-unittest (per-template suites)          │   │
│  │  Positive paths | Negative paths | Edge cases | Inherit  │   │
│  └──────────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────────┤
│                    Layer 4: INTEGRATION                          │
│  ┌──────────────────┐  ┌────────────────────────────────────┐   │
│  │ chart-testing(ct)│  │ helm test (in-cluster validation)  │   │
│  └──────────────────┘  └────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### Component Responsibilities

| Component | Responsibility | Typical Implementation |
|-----------|----------------|------------------------|
| Template Logic Audit | Verify nil safety, hasKey correctness, boolean handling, inheritance chains, fail guards | Manual code review against conventions document, guided by known anti-patterns |
| Values Schema Validation | Catch typos, wrong types, invalid enums at `helm install` time | `values.schema.json` (JSON Schema Draft 7), validated by Helm natively |
| Rendered Manifest Validation | Verify output YAML is valid Kubernetes against target K8s version | `kubeconform` with CRD schemas (ExternalSecret), run on `helm template` output |
| Security Best Practices Audit | Enforce security context, resource limits, SA token mounting, image pinning | `kube-linter` (already in Makefile), `polaris` for additional checks |
| Unit Test Coverage | Assert rendering correctness for all value combinations and edge cases | `helm-unittest` suites, one per template, testing all 7 categories (see below) |
| Integration Validation | Verify chart installs cleanly on a real cluster | `chart-testing` (ct) or manual `make install SCENARIO=...` |

## Recommended Audit Structure for This Project

### Phase-Ordered Audit Components

The audit should proceed in dependency order. Each component produces findings that feed the next.

```
Template Logic Audit ──────────────┐
                                   ├──> Fix Batch 1 (template bugs)
Test Coverage Gap Analysis ────────┘
         │
         v
K8s Best Practices Audit ─────────┐
                                   ├──> Fix Batch 2 (hardening)
values.schema.json Creation ───────┘
         │
         v
Feature Gap Analysis ─────────────────> Fix Batch 3 (new features)
         │
         v
CI Pipeline Hardening ────────────────> Final integration
```

**Rationale for this order:**

1. **Template logic first** because bugs in template logic invalidate test results. Fix the templates before adding tests that assert on broken behavior.
2. **Test coverage second** because it validates the template fixes and catches regressions. Gap analysis runs in parallel with template audit since it reads the same code.
3. **K8s best practices third** because these are configuration-level changes (security contexts, resource defaults) that layer on top of correct templates. Schema creation accompanies this because it codifies the corrected value interface.
4. **Feature gaps last** because new features should be added to an already-hardened, well-tested base.

### Component Boundaries

| Audit Component | Scope | Independent? | Feeds Into |
|-----------------|-------|--------------|------------|
| Template Logic Audit | All 13 template files + `_helpers.tpl` | Yes | Fix Batch 1, Test Coverage |
| Test Coverage Gap Analysis | All 16 test suites vs template code paths | Yes | Fix Batch 1 (regression tests) |
| K8s Best Practices Audit | Rendered manifests security + reliability | After Fix Batch 1 | Fix Batch 2 |
| `values.schema.json` Creation | All values.yaml fields | After Fix Batch 1 | Fix Batch 2 |
| Feature Gap Analysis | Missing enterprise features | After Fix Batch 2 | Fix Batch 3 |
| CI Pipeline Hardening | `.github/workflows/*.yml`, Makefile | After all fixes | Final deliverable |

## Architectural Patterns

### Pattern 1: Seven-Category Test Coverage

**What:** Every template feature should have tests in seven categories: default (absent), enabled, disabled, inheritance, override, explicit-empty-blocks-inheritance, and failure.

**When to use:** Every time a new field or behavior is added or audited in this chart.

**Trade-offs:** Thorough but verbose. For a chart with ~20 inheritable fields across hooks and cronjobs, this produces ~140 test cases for inheritance alone. Worth it because inheritance bugs are the highest-risk defect class in this chart.

**Example (test structure for one inheritable field):**
```yaml
# 1. Default: field absent on both parent and job
- it: should not render nodeSelector when absent everywhere
# 2. Enabled: field on deployment, job inherits
- it: should inherit nodeSelector from deployment
# 3. Disabled: field absent on deployment, absent on job
- it: should not render nodeSelector when deployment has none
# 4. Inheritance: deployment has value, job does not
- it: should use deployment nodeSelector for cronjob
# 5. Override: job overrides deployment value
- it: should override nodeSelector on cronjob
# 6. Explicit empty: job sets {} to suppress inheritance
- it: should not inherit nodeSelector when cronjob sets empty map
# 7. Failure: invalid value causes fail (if applicable)
- it: should fail when nodeSelector is not a map
```

### Pattern 2: Layered Validation Pipeline in CI

**What:** CI runs validation in layers of increasing cost: lint (fast, no cluster) then unit tests (fast, no cluster) then schema validation (fast, no cluster) then security scan (fast, no cluster) then integration (slow, needs cluster).

**When to use:** Always. The current CI already does lint + unit-test + generate-templates. The audit should add kubeconform and expand kube-linter from optional to required.

**Trade-offs:** Adding kubeconform and kube-linter to CI increases build time by ~10-20 seconds but catches an entire class of defects (invalid K8s API versions, missing required fields, security misconfigs) that unit tests cannot.

**Recommended CI flow:**
```
helm lint --strict (all scenarios)
    |
helm-unittest (all suites)
    |
helm template (all scenarios) -> generated-manifests/
    |
kubeconform --kubernetes-version 1.29.0 (all manifests)
    |
kube-linter lint (all manifests)
    |
Upload artifacts
```

### Pattern 3: Schema-First Validation

**What:** A `values.schema.json` file validates user input before template rendering begins. This catches typos (e.g., `imagePullSecert`), wrong types (string where int expected), and invalid enums (e.g., `restartPolicy: Sometimes`) at `helm install` time with clear error messages.

**When to use:** For any chart consumed by multiple teams or external users. This chart is described as reusable across the team.

**Trade-offs:** Schema maintenance cost is real -- every new field requires a schema update. But the payoff is substantial: silent misconfiguration is the most common source of production incidents with Helm charts. The schema also serves as machine-readable documentation and enables IDE autocompletion.

**Structure for this chart:**
```json
{
  "$schema": "https://json-schema.org/draft-07/schema#",
  "type": "object",
  "properties": {
    "global": { ... },
    "deployments": {
      "type": "object",
      "additionalProperties": { "$ref": "#/definitions/deployment" }
    },
    "cronJobs": { ... },
    "hooks": { ... },
    "ingress": { ... },
    "externalSecrets": { ... },
    "rbacs": { ... }
  },
  "definitions": {
    "deployment": { ... },
    "service": { ... },
    "image": { "oneOf": [{"type": "string"}, {"type": "object", ...}] }
  }
}
```

### Pattern 4: Shared Job Pod Spec Helper (Refactoring Pattern)

**What:** Extract the duplicated inheritance logic from `hook.yaml` and `cronjob.yaml` into a shared `_helpers.tpl` named template. Both templates call the same helper, eliminating the divergence risk documented in CONCERNS.md.

**When to use:** When fixing the CronJob SA inheritance asymmetry (the most critical bug identified in the codebase analysis).

**Trade-offs:** Medium refactoring effort. The shared helper must accept a context dict with the job, deployment, and root scope. Testing becomes simpler because the inheritance logic only needs to be tested once. Risk: a bug in the shared helper affects both hooks and cronjobs simultaneously. Mitigation: the existing test suites for both templates serve as regression safety nets.

## Data Flow

### Audit Findings Flow

```
Codebase Analysis (.planning/codebase/*.md)
    |
    v
Template Logic Audit ──> Findings Report (categorized by severity)
    |                         |
    v                         v
Test Coverage Gap     Fix decisions (user approval)
Analysis                      |
    |                         v
    v                    Template Fixes
Test Gap Report              |
    |                        v
    v                  New/Updated Tests (regression)
K8s Best Practices           |
Audit                        v
    |                  Schema Creation
    v                        |
Security Findings            v
    |                  CI Pipeline Updates
    v                        |
Feature Gap Report           v
    |                  Final Validation (all green)
    v
Prioritized Backlog
```

### Key Data Flows

1. **Audit to Fix:** Each audit component produces a categorized findings list. The user reviews and approves before fixes are applied. This "report first, fix after" pattern (per PROJECT.md decision) prevents unwanted changes.

2. **Fix to Test:** Every template fix must be accompanied by a regression test. The test is written AFTER the fix to assert on correct behavior, not on the pre-fix broken behavior.

3. **Schema to CI:** The `values.schema.json` file is validated by Helm natively during `helm lint` and `helm install`. No additional CI step is needed -- it integrates into the existing `make lint-chart` target automatically.

4. **kube-linter Config to Audit:** The existing `.kube-linter-config.yaml` defines which checks are enabled/disabled. The audit should review this config to ensure it matches the chart's security posture goals.

## Scaling Considerations

| Concern | Current (1 chart, 1 team) | Growth (5+ charts, 3+ teams) | Enterprise (chart library) |
|---------|---------------------------|------------------------------|---------------------------|
| Test execution time | ~10s (220 tests) | ~30s (add scenarios) | Use parallel test runners |
| Schema maintenance | Manual | Auto-generate from values.yaml annotations | Use helm-schema plugin |
| Security policy | kube-linter config | Shared conftest policies | OPA/Gatekeeper cluster-wide |
| CI pipeline | Single workflow | Reusable workflow templates | Centralized chart-testing infra |

### Scaling Priorities

1. **First bottleneck: schema maintenance.** As the chart grows, keeping `values.schema.json` in sync with `values.yaml` manually is error-prone. Use the `helm schema` plugin or `helm-docs`-style annotations to auto-generate.
2. **Second bottleneck: test verbosity.** With 7 test categories per inheritable field and ~20 fields, test files become long. Mitigate by extracting inheritance tests into a dedicated `inheritance_test.yaml` suite rather than spreading across `hook_test.yaml` and `cronjob_test.yaml`.

## Anti-Patterns

### Anti-Pattern 1: Testing After All Fixes

**What people do:** Complete all template fixes first, then write tests.
**Why it is wrong:** Without tests, you cannot verify fixes are correct. You also risk introducing new bugs while fixing old ones, with no safety net.
**Do this instead:** Write the failing test first (or immediately after the fix), then verify it passes. Fix and test in pairs.

### Anti-Pattern 2: Over-Broad kube-linter Exclusions

**What people do:** Disable kube-linter checks that fail on the chart's rendered output (e.g., disable "no-read-only-root-fs" globally).
**Why it is wrong:** Exclusions hide real issues. The chart should support the security feature and let users opt in/out via values.
**Do this instead:** Add the missing values support (e.g., `readOnlyRootFilesystem` in securityContext defaults), then configure kube-linter to check the feature is available, not that it is always on.

### Anti-Pattern 3: Schema That Mirrors Code Instead of Constraining It

**What people do:** Write a `values.schema.json` that accepts everything the templates can technically process.
**Why it is wrong:** The schema's purpose is to constrain input to valid combinations. Accepting everything provides no protection.
**Do this instead:** Use `enum` for fields with known valid values (`restartPolicy`, `concurrencyPolicy`, `hookType`), `required` for mandatory fields, and `additionalProperties: false` at leaf objects where unexpected keys are always wrong.

### Anti-Pattern 4: Auditing Templates Without Reading Conventions First

**What people do:** Audit template code against general Helm best practices.
**Why it is wrong:** This chart has project-specific conventions (hasKey + ternary for booleans, explicit empty blocks suppress inheritance, trim-right on helpers). Auditing without knowing these conventions produces false positives.
**Do this instead:** The conventions document (`.planning/codebase/CONVENTIONS.md`) is the primary reference for template correctness in this codebase. Audit against it first, then against general Helm best practices second.

## Integration Points

### External Tools

| Tool | Integration Pattern | Notes |
|------|---------------------|-------|
| kubeconform | Run on `helm template` output in CI | Needs `--skip` for CRDs (ExternalSecret) or custom schema registry |
| kube-linter | Already in Makefile (`make kube-linter`) | Review `.kube-linter-config.yaml` exclusions as part of audit |
| helm-docs | Already in Makefile (`make generate-docs`) | Schema and docs should stay in sync |
| helm schema plugin | Generate `values.schema.json` from annotated `values.yaml` | Consider for initial schema bootstrap |

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| Template logic <-> Test suites | Tests set values, assert on rendered YAML | Tests must match template conventions exactly |
| `_helpers.tpl` <-> Resource templates | Named templates called via `include` | Shared helpers return strings; callers use `with` to handle empty |
| `values.schema.json` <-> `values.yaml` | Schema validates against defaults file | Schema must be updated when values change |
| CI workflow <-> Makefile | Workflow calls Make targets | New validation steps should be Make targets first, then CI steps |

## Build Order Implications for Roadmap

Based on dependency analysis, the audit phases should be ordered as:

1. **Phase: Template Logic + Test Gap Analysis** (parallel, no dependencies)
   - Audit all 13 templates + helpers against conventions
   - Identify untested code paths in all 16 test suites
   - Output: categorized findings report

2. **Phase: Template Fixes + Regression Tests** (depends on Phase 1 approval)
   - Fix bugs found in Phase 1 (CronJob SA asymmetry, nil safety, etc.)
   - Add regression tests for each fix
   - Refactor shared job pod spec if approved

3. **Phase: K8s Best Practices + Schema** (depends on Phase 2)
   - Add security context defaults, resource limit guidance
   - Create `values.schema.json` for input validation
   - Review and tighten kube-linter configuration

4. **Phase: Feature Gaps + CI Hardening** (depends on Phase 3)
   - Multi-key ExternalSecrets, ClusterRole support, etc.
   - Add kubeconform to CI pipeline
   - Ensure all new Make targets are CI-integrated

## Sources

- [Helm Best Practices (official)](https://helm.sh/docs/chart_best_practices/)
- [Helm Chart Testing In Production: Layers, Tools, And A Minimum CI Pipeline](https://alexandre-vazquez.com/helm-chart-testing-best-practices/)
- [The Real State of Helm Chart Reliability (2025)](https://www.prequel.dev/blog-post/the-real-state-of-helm-chart-reliability-2025-hidden-risks-in-100-open-source-charts)
- [KubeLinter documentation](https://docs.kubelinter.io/)
- [Polaris - Kubernetes best practices validation](https://github.com/FairwindsOps/polaris)
- [kubeconform - Kubernetes manifest validator](https://github.com/yannh/kubeconform)
- [Validating Helm Chart Values with JSON Schemas](https://www.arthurkoziel.com/validate-helm-chart-values-with-json-schemas/)
- [helm-unittest documentation](https://github.com/helm-unittest/helm-unittest/blob/main/DOCUMENT.md)
- [Quality Gate for Helm Charts](https://medium.com/@michamarszaek/quality-gate-for-helm-charts-f260f5742198)
- [How to Validate Helm Charts Before Deployment](https://oneuptime.com/blog/post/2026-01-17-helm-validate-charts-kubeval-polaris/view)

---
*Architecture research for: Helm chart quality audit and hardening*
*Researched: 2026-03-15*
