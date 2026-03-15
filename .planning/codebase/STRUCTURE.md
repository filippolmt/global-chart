# Codebase Structure

**Analysis Date:** 2026-03-15

## Directory Layout

```
global-chart/                          # Repository root
├── charts/
│   └── global-chart/                  # The Helm chart
│       ├── Chart.yaml                 # Chart metadata (version 1.3.0, kubeVersion >=1.19.0)
│       ├── values.yaml                # Default values with helm-docs annotations
│       └── templates/
│           ├── _helpers.tpl           # All named template helpers
│           ├── deployment.yaml        # Deployment resources (iterates deployments map)
│           ├── service.yaml           # Service resources (per-deployment)
│           ├── serviceaccount.yaml    # ServiceAccount resources (per-deployment)
│           ├── configmap.yaml         # ConfigMap resources (per-deployment env vars)
│           ├── secret.yaml            # Secret resources (per-deployment env vars)
│           ├── mounted-configmap.yaml # ConfigMaps for file-mounting
│           ├── hpa.yaml               # HorizontalPodAutoscaler (per-deployment)
│           ├── pdb.yaml               # PodDisruptionBudget (per-deployment)
│           ├── networkpolicy.yaml     # NetworkPolicy (per-deployment)
│           ├── ingress.yaml           # Ingress (single, release-scoped)
│           ├── cronjob.yaml           # CronJobs (root-level + deployment-scoped)
│           ├── hook.yaml              # Hook Jobs (root-level + deployment-scoped)
│           ├── externalsecret.yaml    # ExternalSecret CRDs
│           ├── rbac.yaml              # Roles, RoleBindings, ServiceAccounts
│           ├── NOTES.txt              # Post-install output
│           └── tests/
│               └── test-connection.yaml  # Helm test pod
├── charts/global-chart/tests/         # helm-unittest test suites (16 files, 220 tests)
│   ├── __snapshot__/                  # Auto-generated test snapshots
│   ├── deployment_test.yaml
│   ├── service_test.yaml
│   ├── serviceaccount_test.yaml
│   ├── configmap_test.yaml
│   ├── secret_test.yaml
│   ├── mounted-configmap_test.yaml
│   ├── hpa_test.yaml
│   ├── pdb_test.yaml
│   ├── networkpolicy_test.yaml
│   ├── ingress_test.yaml
│   ├── cronjob_test.yaml
│   ├── hook_test.yaml
│   ├── externalsecret_test.yaml
│   ├── rbac_test.yaml
│   ├── helpers_test.yaml
│   └── notes_test.yaml
├── tests/                             # Lint/integration value fixtures
│   ├── test01/
│   │   ├── values.01.yaml             # Kitchen-sink full scenario
│   │   └── test01.yaml                # Pre-install kubectl resource
│   ├── multi-deployment.yaml          # Multi-deployment scenario
│   ├── deployment-hooks-cronjobs.yaml # Hooks/CronJobs inside deployments
│   ├── hooks-sa-inheritance.yaml      # SA inheritance test
│   ├── cron-only.yaml                 # CronJobs without Deployment
│   ├── hook-only.yaml                 # Hooks without Deployment
│   ├── externalsecret-only.yaml       # ExternalSecrets only
│   ├── ingress-custom.yaml            # Ingress with deployment reference
│   ├── external-ingress.yaml          # Ingress to external service
│   ├── rbac.yaml                      # RBAC scenario
│   ├── service-disabled.yaml          # Deployment with service disabled
│   ├── raw-deployment.yaml            # Plain image string
│   ├── mountedcm1.yaml                # Mounted config files (files mode)
│   ├── mountedcm2.yaml                # Mounted config files (bundles mode)
│   ├── values.02.yaml                 # Existing ServiceAccount scenario
│   └── values.03.yaml                 # Chart disabled scenario
├── generated-manifests/               # Output of `make generate-templates` (gitignored)
├── baseline-manifests/                # Baseline rendered manifests for comparison
├── docs/                              # Documentation artifacts
├── .github/workflows/
│   ├── helm-ci.yml                    # CI: lint + unit-test + generate on push/PR
│   └── release.yml                    # Release: chart publishing
├── .planning/codebase/                # GSD codebase analysis documents
├── Makefile                           # All developer tasks (lint, test, generate, install)
├── Chart.yaml                         # (at charts/global-chart/Chart.yaml)
├── README.md                          # User-facing documentation
├── README.md.gotmpl                   # helm-docs source template for README
├── CHANGELOG.md                       # Version history
├── CLAUDE.md                          # AI assistant instructions
├── .kube-linter-config.yaml           # kube-linter rule configuration
├── coderabbit.yaml                    # CodeRabbit PR review configuration
└── renovate.json                      # Renovate dependency update config
```

## Directory Purposes

**`charts/global-chart/templates/`:**
- Purpose: All Helm templates that render to Kubernetes manifests
- Contains: One `.yaml` file per Kubernetes resource type, plus `_helpers.tpl` for shared functions
- Key files: `_helpers.tpl` (all reusable helpers), `deployment.yaml` (primary resource)

**`charts/global-chart/tests/`:**
- Purpose: helm-unittest test suites; run via `make unit-test` (Docker-based, no local plugin needed)
- Contains: One `*_test.yaml` per template file; one `__snapshot__/` directory for snapshot assertions
- Key files: `deployment_test.yaml`, `helpers_test.yaml`

**`tests/` (root level):**
- Purpose: Values files used for `helm lint --strict` and `helm template` validation; also `make install` targets
- Contains: Scenario-named value files covering every supported feature combination
- Key files: `test01/values.01.yaml` (comprehensive), `multi-deployment.yaml`

**`generated-manifests/`:**
- Purpose: Output directory for `make generate-templates`; one subdirectory per lint scenario
- Generated: Yes
- Committed: No (listed in `.gitignore`)

**`baseline-manifests/`:**
- Purpose: Reference rendered manifests for regression comparison
- Generated: No
- Committed: Yes

## Key File Locations

**Entry Points:**
- `charts/global-chart/Chart.yaml`: Chart identity and Kubernetes version requirement
- `charts/global-chart/values.yaml`: Full default values with embedded documentation
- `charts/global-chart/templates/deployment.yaml`: Primary resource template, defines multi-deployment iteration pattern

**Configuration:**
- `Makefile`: All developer workflows; defines `TEST_CASES` list used by lint, generate, and install targets
- `.kube-linter-config.yaml`: Static analysis rules applied to generated manifests
- `.github/workflows/helm-ci.yml`: CI pipeline (lint → unit-test → generate → artifact upload)
- `renovate.json`: Automated dependency update configuration

**Core Logic:**
- `charts/global-chart/templates/_helpers.tpl`: All named helpers; must be updated when adding new shared rendering logic
- `charts/global-chart/templates/cronjob.yaml`: Two-part template (root-level Part 1, deployment-scoped Part 2 with inheritance)
- `charts/global-chart/templates/hook.yaml`: Same two-part pattern as cronjob.yaml

**Testing:**
- `charts/global-chart/tests/*_test.yaml`: Unit tests per resource type
- `tests/*.yaml`: Integration/lint value fixtures

## Naming Conventions

**Files:**
- Template files: lowercase resource type name + `.yaml` (e.g., `deployment.yaml`, `networkpolicy.yaml`)
- Test suites: resource type name + `_test.yaml` (e.g., `deployment_test.yaml`)
- Lint fixtures: descriptive scenario name + `.yaml` (e.g., `multi-deployment.yaml`, `hooks-sa-inheritance.yaml`)
- Helper file: `_helpers.tpl` (underscore prefix signals no direct manifest output)

**Kubernetes Resource Names (runtime):**
- Deployment, Service, SA, ConfigMap, Secret, HPA, PDB, NetworkPolicy: `{release}-{chart}-{deploymentName}` (max 63 chars)
- Mounted ConfigMap: `{release}-{chart}-{deploymentName}-md-cm-{name}` (max 63 chars)
- Ingress: `{release}-{chart}` (no deployment suffix; max 63 chars)
- Root-level CronJob: `{release}-{chart}-{cronjobName}` (max 52 chars)
- Deployment-scoped CronJob: `{release}-{chart}-{deploymentName}-{cronjobName}` (max 52 chars)
- Root-level Hook Job: `{release}-{chart}-{hookType}-{jobName}` (max 63 chars)
- Deployment-scoped Hook Job: `{release}-{chart}-{deploymentName}-{hookType}-{jobName}` (max 63 chars)

**Go Template Helpers:**
- Prefix: `global-chart.` (e.g., `global-chart.deploymentFullname`)
- Named with camelCase after the prefix

## Where to Add New Code

**New Kubernetes resource type:**
- Template: `charts/global-chart/templates/<resourcetype>.yaml`
- Unit tests: `charts/global-chart/tests/<resourcetype>_test.yaml` (required)
- Values: Add stanza to `charts/global-chart/values.yaml` with helm-docs `# --` annotations
- Lint fixture: Add or update a file in `tests/` and add it to `TEST_CASES` in `Makefile`

**New per-deployment sub-resource:**
- Follow the pattern in `charts/global-chart/templates/hpa.yaml` or `pdb.yaml`: open with `{{- range $name, $deploy := .Values.deployments }}`, guard with `deploymentEnabled` check, use `global-chart.deploymentFullname` and `global-chart.deploymentLabels`

**New shared rendering helper:**
- Add to `charts/global-chart/templates/_helpers.tpl`
- Must return empty string when no content to render (callers use `{{- with (include ...) }}`)
- Use `-}}` trim on conditional lines before literal YAML to avoid leading newlines
- Add tests to `charts/global-chart/tests/helpers_test.yaml`

**New values field on deployments:**
- Add commented example inside the `deployments:` block in `charts/global-chart/values.yaml`
- Reference in the relevant template file using `default (dict) $deploy.field` for optional map fields

**Utilities:**
- Shared template logic: `charts/global-chart/templates/_helpers.tpl`
- No shared Bash/scripting utilities; all developer tooling is in `Makefile`

## Special Directories

**`.planning/`:**
- Purpose: GSD AI assistant planning documents and codebase analysis
- Generated: No
- Committed: Yes

**`generated-manifests/`:**
- Purpose: `helm template` output for all test scenarios (used by kube-linter and artifact upload in CI)
- Generated: Yes (`make generate-templates`)
- Committed: No

**`baseline-manifests/`:**
- Purpose: Known-good rendered manifests for regression checking
- Generated: No (manually maintained)
- Committed: Yes

**`charts/global-chart/tests/__snapshot__/`:**
- Purpose: Snapshot files auto-created by helm-unittest for snapshot assertion tests
- Generated: Yes (on first test run or explicit update)
- Committed: Yes (tracks expected output)

---

*Structure analysis: 2026-03-15*
