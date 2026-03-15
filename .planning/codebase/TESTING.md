# Testing Patterns

**Analysis Date:** 2026-03-15

## Test Framework

**Runner:**
- helm-unittest `3.19.0-1.0.3`
- Run via Docker: image `helmunittest/helm-unittest:3.19.0-1.0.3`
- Config: no separate config file; tests are discovered by convention from `charts/global-chart/tests/`

**Assertion Library:**
- helm-unittest built-in assertions (YAML-based)

**Run Commands:**
```bash
make unit-test          # Run all 220 unit tests via Docker
make lint-chart         # Helm lint --strict with all test value files
make generate-templates # Lint + render all scenarios to generated-manifests/
make all                # lint-chart + unit-test + generate-templates
make render VALUES=tests/test01/values.01.yaml TEMPLATE=deployment.yaml  # Debug single template
```

---

## Test File Organization

**Two separate test directories serve different purposes:**

- `charts/global-chart/tests/` — helm-unittest suites (unit tests, run by `make unit-test`)
- `tests/` — value files for lint scenarios and manual rendering (run by `make lint-chart`, `make generate-templates`)

**Naming convention for unit test files:**
- `{templateName}_test.yaml` matching the template filename exactly
- Examples: `deployment_test.yaml`, `hook_test.yaml`, `cronjob_test.yaml`
- Exception: `helpers_test.yaml` (tests helper logic via the deployment template)

**Every template file must have a corresponding test file in `charts/global-chart/tests/`.**

---

## Test File Structure

**Suite header:**
```yaml
suite: deployment template tests
templates:
  - templates/deployment.yaml
tests:
  # ====== <section name> ======
  - it: should <behavior description>
    set:
      ...
    asserts:
      - ...
```

**Key fields:**
- `suite`: Human-readable name shown in output
- `templates`: List of templates exercised (usually one)
- `it`: Test description in plain English using "should" convention
- `set`: Inline values override (dot-notation for nested keys)
- `release.name`: Override release name when naming tests need it
- `documentIndex`: Target a specific document when a template renders multiple resources

---

## Assertion Patterns

**Document count:**
```yaml
asserts:
  - hasDocuments:
      count: 1
  - hasDocuments:
      count: 0  # Nothing rendered
```

**Kind check:**
```yaml
asserts:
  - isKind:
      of: Deployment
    documentIndex: 0
  - isKind:
      of: Job
    documentIndex: 1
```

**Value equality:**
```yaml
asserts:
  - equal:
      path: spec.replicas
      value: 3
  - equal:
      path: metadata.name
      value: myrelease-global-chart-api
  - equal:
      path: spec.template.spec.containers[0].imagePullPolicy
      value: IfNotPresent
```

**Field existence:**
```yaml
asserts:
  - exists:
      path: spec.template.metadata.annotations.checksum/secret
  - notExists:
      path: spec.strategy
  - isNull:
      path: spec.template.spec.securityContext
  - isNotNull:
      path: spec.template.spec.affinity.nodeAffinity
```

**List membership:**
```yaml
asserts:
  - contains:
      path: spec.template.spec.containers
      content:
        name: sidecar
        image: busybox:1.28
  - contains:
      path: spec.policyTypes
      content: Ingress
```

**Subset check (partial match):**
```yaml
asserts:
  - isSubset:
      path: spec.selector.matchLabels
      content:
        app.kubernetes.io/component: web
```

**Length check:**
```yaml
asserts:
  - lengthEqual:
      path: spec.template.spec.containers[0].env
      count: 2
```

**Regex match:**
```yaml
asserts:
  - matchRegex:
      path: metadata.name
      pattern: "^.{1,52}$"
  - matchRegex:
      path: spec.template.spec.serviceAccountName
      pattern: ".*backend.*"
```

**Expected template failure:**
```yaml
asserts:
  - failedTemplate:
      errorMessage: "PDB for deployment 'main': minAvailable and maxUnavailable are mutually exclusive — set only one."
```

---

## Test Group Organization

Tests within a file are grouped with section header comments:

```yaml
  # ====== enabled flag ======
  - it: should not render deployment when enabled is false
    ...

  # ====== extraContainers (Bug Fix #1) ======
  - it: should render extraContainers as sidecar
    ...
```

This makes long test files navigable. Sections map to feature areas or edge cases.

---

## Test Value Patterns

**Minimal viable test (always used as base):**
```yaml
set:
  deployments:
    main:
      image: nginx:1.25
```

**Multi-document template tests (hooks/serviceaccounts):**

When a template renders 2+ documents (e.g., ServiceAccount + Job for root-level hooks), use `documentIndex` on each assertion:

```yaml
asserts:
  - isKind:
      of: ServiceAccount
    documentIndex: 0
  - isKind:
      of: Job
    documentIndex: 1
  - equal:
      path: metadata.annotations["helm.sh/hook"]
      value: post-install
    documentIndex: 1
```

**Override + inheritance tests always come in pairs:**
```yaml
# Test: inherit from deployment
- it: should inherit nodeSelector from deployment
  set:
    deployments:
      backend:
        ...
        nodeSelector:
          node-type: backend
        hooks:
          post-upgrade:
            migrate:
              command: ["./migrate.sh"]
  asserts:
    - equal:
        path: spec.template.spec.nodeSelector.node-type
        value: backend

# Test: override inherited value
- it: should allow deployment-level hook to override nodeSelector
  set:
    deployments:
      backend:
        ...
        nodeSelector:
          node-type: backend
        hooks:
          post-upgrade:
            migrate:
              command: ["./migrate.sh"]
              nodeSelector:
                node-type: hook-node
  asserts:
    - equal:
        path: spec.template.spec.nodeSelector.node-type
        value: hook-node
```

**Explicit empty = no inheritance (must also be tested):**
```yaml
- it: should not inherit hostAliases when hook sets empty list
  set:
    deployments:
      backend:
        image: myapp:v1
        hostAliases:
          - ip: "127.0.0.1"
            hostnames: ["foo.local"]
        hooks:
          post-install:
            migrate:
              command: ["./migrate.sh"]
              hostAliases: []   # explicit empty
  asserts:
    - isNull:
        path: spec.template.spec.hostAliases
      documentIndex: 1
```

---

## Lint Test Scenarios

**Location:** `tests/` directory (root, not `charts/`)

**Registration:** All scenarios must be listed in `TEST_CASES` in `Makefile` with format `values_file:namespace:slug`.

**Current test scenarios (16 total):**

| Slug | File | Purpose |
|------|------|---------|
| `test01` | `tests/test01/values.01.yaml` | Full kitchen-sink |
| `test02` | `tests/values.02.yaml` | Existing service account |
| `test03` | `tests/values.03.yaml` | Chart disabled |
| `multi-deployment` | `tests/multi-deployment.yaml` | Multiple deployments |
| `mountedcm1` | `tests/mountedcm1.yaml` | Mounted config files |
| `mountedcm2` | `tests/mountedcm2.yaml` | Mounted config bundles |
| `cron` | `tests/cron-only.yaml` | CronJobs only |
| `hooks` | `tests/hook-only.yaml` | Hooks only |
| `externalsecret` | `tests/externalsecret-only.yaml` | ExternalSecrets only |
| `ingress` | `tests/ingress-custom.yaml` | Custom ingress |
| `external-ingress` | `tests/external-ingress.yaml` | Ingress to external service |
| `rbac` | `tests/rbac.yaml` | RBAC resources |
| `service-disabled` | `tests/service-disabled.yaml` | Service.enabled: false |
| `raw-deployment` | `tests/raw-deployment.yaml` | Raw image string |
| `deployment-hooks-cronjobs` | `tests/deployment-hooks-cronjobs.yaml` | Hooks/CronJobs inside deployments |
| `hooks-sa-inheritance` | `tests/hooks-sa-inheritance.yaml` | SA inheritance edge cases |

---

## Coverage

**Requirements:** No numeric coverage threshold enforced; coverage is enforced by convention: every template file must have a `*_test.yaml`.

**Test suites:** 16 (one per template file, plus `helpers_test.yaml`)
**Total tests:** 220

**View test results:**
```bash
make unit-test
```

---

## Test Types

**Unit Tests (`charts/global-chart/tests/`):**
- Template rendering tests using helm-unittest
- Each test sets specific values and asserts on rendered YAML structure
- No cluster required; fully offline

**Lint Tests (`make lint-chart`):**
- `helm lint --strict` with each scenario values file
- Catches YAML schema errors and Helm rendering failures
- Uses realistic combined value files (not minimal unit test values)

**Generated Manifest Review (`make generate-templates`):**
- Renders all scenarios to `generated-manifests/`
- Uploaded as CI artifact for manual inspection
- Used for visual validation before merge

**Static Analysis (`make kube-linter`):**
- Runs `kube-linter` on generated manifests
- Config at `.kube-linter-config.yaml`
- Requires Docker

---

## What to Test

When adding a new field or behavior, write tests for:
1. **Default case** (field absent → expected default behavior)
2. **Enabled case** (field present → expected output)
3. **Disabled case** (field explicitly `false`/`0`/`[]` → nothing rendered)
4. **Inheritance case** (deployment-level → hook/cronjob inherits)
5. **Override case** (hook/cronjob overrides inherited value)
6. **Explicit empty blocks inheritance** (`field: {}` or `field: []` must NOT inherit)
7. **Failure case** (invalid combination → `failedTemplate` assert)

---

## Common Test Anti-Patterns to Avoid

- Do not use `if not $var` in templates to check inheritance — use `hasKey`
- Do not rely on `default true $boolVar` for boolean fields — use `hasKey` + `ternary`
- Do not skip failure cases for mutually exclusive options (like PDB `minAvailable`/`maxUnavailable`)

---

*Testing analysis: 2026-03-15*
