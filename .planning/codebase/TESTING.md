# Testing Patterns

**Analysis Date:** 2026-03-17

## Test Framework

**Runner:**
- helm-unittest `3.19.0-1.0.3` (Docker image `helmunittest/helm-unittest:3.19.0-1.0.3`)
- Run via Docker — no local plugin installation required
- Config: no separate config file; test discovery is implicit (all `*_test.yaml` under `charts/global-chart/tests/`)

**Assertion Library:**
- helm-unittest built-in assertions (`equal`, `contains`, `isKind`, `hasDocuments`, `failedTemplate`, etc.)

**Run Commands:**
```bash
make unit-test              # Run all 220 unit tests via Docker
make lint-chart             # Lint all 16 test scenarios with helm lint --strict
make all                    # lint-chart + unit-test + generate-templates
make generate-templates     # Generate manifests to generated-manifests/ for visual inspection
make render VALUES=tests/test01/values.01.yaml TEMPLATE=deployment.yaml  # Render single template
```

## Test File Organization

**Location:**
- Unit test suites: `charts/global-chart/tests/` (co-located with chart)
- Lint value fixtures: `tests/` (root-level, separate from chart)

**Naming:**
- Unit test files: `{template-name}_test.yaml` (mirrors template file name)
  - `deployment_test.yaml` → tests `templates/deployment.yaml`
  - `mounted-configmap_test.yaml` → tests `templates/mounted-configmap.yaml`
- Lint fixture files: descriptive names (`cron-only.yaml`, `hooks-sa-inheritance.yaml`, `multi-deployment.yaml`)

**Structure:**
```
charts/global-chart/tests/
├── __snapshot__/                  # Auto-generated snapshot files (not manually edited)
├── deployment_test.yaml           # 16 suites × average ~14 tests = 220 total
├── cronjob_test.yaml
├── hook_test.yaml
├── hpa_test.yaml
├── ingress_test.yaml
├── service_test.yaml
├── serviceaccount_test.yaml
├── configmap_test.yaml
├── secret_test.yaml
├── mounted-configmap_test.yaml
├── externalsecret_test.yaml
├── rbac_test.yaml
├── helpers_test.yaml
├── pdb_test.yaml
├── networkpolicy_test.yaml
└── notes_test.yaml
```

## Test Structure

**Suite Organization:**
```yaml
suite: deployment template tests      # Human-readable suite name
templates:
  - templates/deployment.yaml         # Template(s) under test

tests:
  # ====== feature group comment ======
  - it: should render deployment when enabled is true   # Descriptive "it" statement
    set:                                                 # Override values inline
      deployments:
        main:
          enabled: true
          image: nginx:1.25
    asserts:
      - hasDocuments:
          count: 1
```

**Test naming convention:**
- "it" statements use `should` prefix: `should render X when Y`, `should not render X when Y`, `should fail when X`
- Feature groups separated by `# ====== group name ======` comments

**Release context:**
When testing naming patterns, `release.name` is set explicitly:
```yaml
- it: should name deployment correctly
  release:
    name: myrelease
  set:
    deployments:
      api:
        image: nginx:1.25
  asserts:
    - equal:
        path: metadata.name
        value: myrelease-global-chart-api
```

## Assertion Patterns

**Document count:**
```yaml
asserts:
  - hasDocuments:
      count: 0    # Nothing rendered
  - hasDocuments:
      count: 2    # Multiple resources (e.g., multiple deployments)
```

**Exact value:**
```yaml
asserts:
  - equal:
      path: spec.template.spec.containers[0].image
      value: "nginx@sha256:abc123"
  - equal:
      path: metadata.labels["app.kubernetes.io/version"]
      value: "1.3.0"
```

**Presence/absence:**
```yaml
asserts:
  - exists:
      path: spec.template.metadata.annotations.checksum/secret
  - notExists:
      path: spec.strategy
  - isNull:
      path: spec.template.spec.containers[0].securityContext
  - isNotNull:
      path: spec.template.spec.containers[0].envFrom
```

**Kind check:**
```yaml
asserts:
  - isKind:
      of: Job
    documentIndex: 1     # When template produces multiple documents
  - isKind:
      of: ServiceAccount
    documentIndex: 0
```

**List containment:**
```yaml
asserts:
  - contains:
      path: spec.template.spec.containers
      content:
        name: sidecar
        image: busybox:1.28
        command: ["sh", "-c", "echo sidecar"]
  - lengthEqual:
      path: spec.template.spec.containers[0].env
      count: 2
```

**Subset check (for labels):**
```yaml
asserts:
  - isSubset:
      path: spec.selector.matchLabels
      content:
        app.kubernetes.io/component: web
```

**Pattern match (for NOTES.txt and name truncation):**
```yaml
asserts:
  - matchRegexRaw:
      pattern: "Deployments created:"
  - notMatchRegexRaw:
      pattern: "main"
  - matchRegex:
      path: metadata.name
      pattern: "^.{1,52}$"
```

**Expected failures:**
```yaml
asserts:
  - failedTemplate:
      errorMessage: "PDB for deployment 'main': minAvailable and maxUnavailable are mutually exclusive — set only one."
```

## Multi-Document Tests

When a template renders multiple Kubernetes resources (e.g., hook.yaml renders ServiceAccount + Job), use `documentIndex`:
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

## Mocking / Value Injection

**No external mocking framework.** All test isolation is achieved by injecting minimal `set:` values.

**Minimal values pattern** — only set what the test needs:
```yaml
set:
  deployments:
    main:
      image: nginx:1.25    # Always required; minimal case
```

**Cross-reference testing** — when testing `fromDeployment` or `deployment` references in Ingress/Hooks/CronJobs, both the referencing resource and the referenced deployment must be set:
```yaml
set:
  deployments:
    backend:
      image: myapp:v2
  hooks:
    post-upgrade:
      migrate:
        fromDeployment: backend
        command: ["./migrate.sh"]
```

**Negative/override tests** — use explicit empty to verify inheritance blocking:
```yaml
set:
  deployments:
    backend:
      image: myapp:v1
      hostAliases:
        - ip: "127.0.0.1"
          hostnames: ["foo.local"]
      cronJobs:
        cleanup:
          schedule: "0 4 * * *"
          command: ["./cleanup.sh"]
          hostAliases: []    # Explicit empty — must NOT inherit
```

## Lint Test Scenarios

The `tests/` root directory contains value fixtures for `make lint-chart` (runs `helm lint --strict`). These exercise full chart rendering paths not covered by unit tests:

| File | Coverage |
|------|----------|
| `tests/test01/values.01.yaml` | Full kitchen-sink: autoscaling, volumes, secrets, hooks, crons, ingress, ExternalSecrets |
| `tests/values.02.yaml` | Deployment with existing ServiceAccount |
| `tests/values.03.yaml` | Chart disabled entirely |
| `tests/multi-deployment.yaml` | Multiple independent deployments |
| `tests/cron-only.yaml` | CronJobs without Deployment |
| `tests/hook-only.yaml` | Hooks without Deployment |
| `tests/externalsecret-only.yaml` | ExternalSecrets only |
| `tests/deployment-hooks-cronjobs.yaml` | Hooks/CronJobs inside deployments (inheritance) |
| `tests/hooks-sa-inheritance.yaml` | Hooks SA inheritance edge cases |

New lint scenarios must be added to `TEST_CASES` in `Makefile` with format `values_file:namespace:slug`.

## CI Pipeline

GitHub Actions (`.github/workflows/helm-ci.yml`) runs on push/PR to `main`:
1. `make lint-chart` — strict lint all test scenarios
2. `make unit-test` — all 220 helm-unittest tests via Docker
3. `make generate-templates` — renders all scenarios to `generated-manifests/`
4. Uploads `generated-manifests/` as artifact for visual inspection

## Coverage

**Requirements:** No numeric coverage threshold enforced. Coverage is by convention: every template file must have a corresponding `*_test.yaml`.

**Current coverage:**
- 16 template files → 16 test suites
- 220 total test cases
- Coverage tracked by feature: enabled/disabled flags, naming, inheritance, error paths, defaults, multi-deployment

**Gaps to watch:** Snapshot tests exist (the `__snapshot__/` directory is present but empty — no snapshot assertions are currently used).

## Test Types

**Unit Tests (primary):**
- Scope: individual template rendering with injected values
- Tool: helm-unittest
- Location: `charts/global-chart/tests/`

**Lint Tests (secondary):**
- Scope: full chart lint with realistic value combinations
- Tool: `helm lint --strict`
- Location: `tests/` (root)

**Visual Inspection:**
- `make generate-templates` renders to `generated-manifests/` for manual review
- Not automated — requires human inspection

**Cluster Integration Tests:**
- `make install SCENARIO=<slug>` installs to a live cluster
- Not automated in CI

**E2E/Helm Tests:**
- `helm test <release>` runs `templates/tests/test-connection.yaml` (a connection test pod)
- Tests the first enabled service

---

*Testing analysis: 2026-03-17*
