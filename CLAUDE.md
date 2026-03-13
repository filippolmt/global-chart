# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Global-chart is a reusable Helm chart providing configurable Kubernetes building blocks: Deployments, Services, Ingress, CronJobs, Hook Jobs, ExternalSecrets, and RBAC resources.

Supports multi-deployment: multiple independent deployments in a single release, each with its own resources (Service, ConfigMap, Secret, ServiceAccount, HPA, PDB, NetworkPolicy). Current version: **1.3.0**.

## Common Commands

```bash
# Show all available commands
make help

# Lint all test scenarios (runs helm lint --strict)
make lint-chart

# Run helm-unittest via Docker
make unit-test

# Generate manifests for visual inspection (outputs to generated-manifests/)
make generate-templates

# Run lint, unit tests and generate
make all

# Run kube-linter against generated manifests (requires Docker)
make kube-linter

# Generate helm-docs (requires Docker)
make generate-docs

# Package chart for distribution
make package

# Install test scenarios to a cluster
make install SCENARIO=test01   # Any scenario from TEST_CASES
make install SCENARIO=test02
make install SCENARIO=multi-deployment
make install-test01            # test01 with kubectl pre-step

# Render a single template for debugging
make render VALUES=tests/test01/values.01.yaml TEMPLATE=deployment.yaml

# Cleanup
make clean               # Remove generated files
make clean-all           # Clean + uninstall helm releases
```

## Architecture

### Chart Structure

```
charts/global-chart/
├── Chart.yaml              # Chart metadata (version 1.3.0)
├── values.yaml             # Default values with helm-docs annotations
├── templates/
│   ├── _helpers.tpl        # Template functions (see Helper Catalog below)
│   ├── deployment.yaml     # Deployments (iterates over deployments map)
│   ├── service.yaml        # Services (per-deployment, can be disabled)
│   ├── serviceaccount.yaml # ServiceAccounts (per-deployment)
│   ├── configmap.yaml      # ConfigMaps (per-deployment)
│   ├── secret.yaml         # Secrets (per-deployment)
│   ├── mounted-configmap.yaml  # Mounted ConfigMaps (per-deployment)
│   ├── hpa.yaml            # HPAs (per-deployment)
│   ├── pdb.yaml            # PodDisruptionBudgets (per-deployment)
│   ├── networkpolicy.yaml  # NetworkPolicies (per-deployment)
│   ├── ingress.yaml        # Ingress (routes to specific deployments)
│   ├── cronjob.yaml        # CronJobs (root-level or inside deployments)
│   ├── hook.yaml           # Helm hook Jobs (root-level or inside deployments)
│   ├── externalsecret.yaml # ExternalSecret CRDs
│   ├── rbac.yaml           # Roles and RoleBindings
│   ├── NOTES.txt           # Post-install notes
│   └── tests/
│       └── test-connection.yaml  # Helm test pod
├── tests/                  # helm-unittest test files (16 suites, 220 tests)
│   ├── deployment_test.yaml
│   ├── cronjob_test.yaml
│   ├── hook_test.yaml
│   ├── hpa_test.yaml
│   ├── ingress_test.yaml
│   ├── service_test.yaml
│   ├── serviceaccount_test.yaml
│   ├── configmap_test.yaml
│   ├── secret_test.yaml
│   ├── mounted-configmap_test.yaml
│   ├── externalsecret_test.yaml
│   ├── rbac_test.yaml
│   ├── helpers_test.yaml
│   ├── pdb_test.yaml
│   ├── networkpolicy_test.yaml
│   └── notes_test.yaml
```

### Multi-Deployment Schema (v1.0.0)

```yaml
# Multiple deployments with independent configurations
deployments:
  frontend:
    image: nginx:1.25
    replicaCount: 3
    service:
      enabled: true
      port: 80
    configMap:
      ENV: production
    serviceAccount:
      create: true

  backend:
    image: myapp:v2
    replicaCount: 2
    service:
      port: 3000
    autoscaling:
      enabled: true

  worker:
    image: myapp:v2
    service:
      enabled: false  # Workers don't need a service

# Ingress routes to specific deployments
ingress:
  enabled: true
  hosts:
    - host: example.com
      deployment: frontend  # Required: references a deployment
      paths:
        - path: /
    - host: api.example.com
      deployment: backend
      paths:
        - path: /api

# CronJobs/Hooks can be defined at root level (with fromDeployment for image)
cronJobs:
  backup:
    schedule: "0 2 * * *"
    fromDeployment: backend  # Copies image from backend
    command: ["./backup.sh"]

# OR inside deployments (inherit image, configMap, secret, SA, nodeSelector, tolerations, etc.)
deployments:
  backend:
    image: myapp:v2
    configMap:
      DB_HOST: postgres
    secret:
      DB_PASSWORD: secret123
    serviceAccount:
      create: true
    # Hooks inside deployment - inherit everything from parent
    hooks:
      pre-upgrade:
        migrate:
          command: ["./migrate.sh"]
          # Inherits: image, configMap, secret, serviceAccount, nodeSelector, tolerations
    # CronJobs inside deployment - inherit everything from parent
    cronJobs:
      cleanup:
        schedule: "0 4 * * *"
        command: ["./cleanup.sh"]
        # Inherits: image, configMap, secret, serviceAccount, nodeSelector, tolerations
```

### Key Design Patterns

1. **Multi-deployment iteration**: Templates iterate over `deployments` map using `range $name, $deploy := .Values.deployments`. Each deployment generates its own resources.

2. **Deployment-specific naming**: Resources are named `{release}-{chart}-{deploymentName}` using the `global-chart.deploymentFullname` helper.

3. **Selector labels with component**: Each deployment gets unique selector labels including `app.kubernetes.io/component: {deploymentName}` to ensure pods don't overlap.

4. **Image specification**: The `image` field accepts either a string (`nginx:1.25`) or a map (`{repository, tag, digest, pullPolicy}`). Helper `global-chart.imageString` handles both. Supports `global.imageRegistry` to prepend a shared registry prefix.

5. **ServiceAccount default**: Each deployment creates a ServiceAccount by default (`serviceAccount.create` defaults to `true`). To use an existing SA or the Kubernetes `default` SA, explicitly set `serviceAccount.create: false` with an optional `name`.

6. **Hooks/CronJobs inheritance**: Two placement options:
   - **Root level** (`hooks:`, `cronJobs:`): Standalone, use `fromDeployment` to copy image only
   - **Inside deployments** (`deployments.*.hooks`, `deployments.*.cronJobs`): Inherit image, configMap, secret, serviceAccount, envFromConfigMaps, envFromSecrets, additionalEnvs, imagePullSecrets, hostAliases, podSecurityContext, securityContext, dnsConfig (deployment-level cronjobs only), nodeSelector, tolerations, affinity from parent deployment
   - **Root-level dnsConfig**: Both root-level cronJobs and hooks accept `dnsConfig` directly (no inheritance, standalone only)
   - **ServiceAccount inheritance**: Hooks inherit SA from deployment in two cases:
     - `serviceAccount.create: true` (or not specified) - uses the generated SA name
     - `serviceAccount.create: false` with `name: xxx` - uses the existing SA name
   - **Override SA per hook**: Use `serviceAccountName: "custom-sa"` in the hook to override inheritance

7. **Service can be disabled**: Set `service.enabled: false` on a deployment to skip Service creation (useful for workers/background jobs).

8. **Mounted config files**: Two modes exist:
   - `files`: Individual ConfigMaps, one per file
   - `bundles`: Projected sets of multiple files in one ConfigMap

9. **Global values**: `global.imageRegistry` prepends a shared registry prefix to all images. `global.imagePullSecrets` provides default pull secrets when not set at deployment/job level.

10. **PodDisruptionBudget**: Set `pdb.enabled: true` with `minAvailable` or `maxUnavailable` per deployment.

11. **NetworkPolicy**: Set `networkPolicy.enabled: true` per deployment with ingress/egress rules and policyTypes.

12. **Deployment strategy**: `strategy` (RollingUpdate/Recreate), `revisionHistoryLimit`, `progressDeadlineSeconds`, `topologySpreadConstraints` per deployment.

13. **Volume spec**: Supports both native Kubernetes volume spec (recommended) and legacy `.type` format for backward compatibility. Helper `global-chart.renderVolume` handles both.

14. **Default resources**: CronJobs and Hooks use `defaults.resources` from values.yaml when no per-job resources are specified.

15. **Helm test**: `helm test <release>` runs a connection test against the first enabled service.

### Helper Catalog (`_helpers.tpl`)

| Helper | Purpose |
|--------|---------|
| `name`, `fullname`, `chart` | Standard Helm naming |
| `labels`, `selectorLabels` | Common labels for non-deployment resources (Ingress, ExternalSecret, RBAC) |
| `deploymentFullname` | `{release}-{chart}-{deploymentName}` (trunc 63) |
| `deploymentLabels`, `deploymentSelectorLabels` | Labels with `component` for per-deployment resources |
| `deploymentEnabled` | Returns `"true"`/`"false"` string; defaults to true |
| `deploymentServiceAccountName` | Resolves SA name: explicit > generated > `"default"` |
| `hookLabels`, `hookLabelsWithComponent`, `hookfullname` | Hook-specific labels (no selectorLabels to avoid HPA matching) |
| `imageString` | Image ref from string or `{repository, tag, digest}`; supports `global.imageRegistry` |
| `imagePullPolicy` | Resolves policy: override > image map > fallback > `IfNotPresent` |
| `renderVolume` | Renders a volume entry; supports both native K8s spec and legacy `.type` format |
| `renderImagePullSecrets` | Shared: renders `imagePullSecrets:` block from a resolved list; returns empty if nil |
| `renderDnsConfig` | Shared: renders `dnsConfig:` block from a dict; returns empty if no fields set |
| `renderResources` | Shared: renders `resources:` with fallback to `defaults.resources`; returns empty if both nil |

### Resource Naming Convention

| Resource | Pattern | Max Length |
|----------|---------|------------|
| Deployment, Service, SA, ConfigMap, Secret, HPA | `{release}-{chart}-{deploymentName}` | 63 chars |
| Mounted ConfigMap | `{release}-{chart}-{deploymentName}-md-cm-{name}` | 63 chars |
| Ingress | `{release}-{chart}` | 63 chars |
| CronJob (root level) | `{release}-{chart}-{cronjobName}` | **52 chars** |
| CronJob (inside deployment) | `{release}-{chart}-{deploymentName}-{cronjobName}` | **52 chars** |
| Hook Job (root level) | `{release}-{chart}-{hookType}-{jobName}` | 63 chars |
| Hook Job (inside deployment) | `{release}-{chart}-{deploymentName}-{hookType}-{jobName}` | 63 chars |

> **Note**: CronJob names are limited to 52 characters because Kubernetes appends an 11-character timestamp suffix when creating Jobs from CronJobs (total Job name limit is 63 characters).

### Test Structure

Two separate test directories exist:
- **`tests/`** (root) - Value files for lint scenarios and manual template rendering (used by `make lint-chart`)
- **`charts/global-chart/tests/`** - helm-unittest test suites (used by `make unit-test`)

### Test Scenarios (Lint Values)

The `tests/` directory contains value files covering all supported configurations:

| File | Description |
|------|-------------|
| `test01/values.01.yaml` | Full kitchen-sink (autoscaling, volumes, secrets, hooks, crons, ingress, ExternalSecrets) |
| `values.02.yaml` | Deployment with existing service account |
| `values.03.yaml` | Chart disabled (no output) |
| `multi-deployment.yaml` | **Multi-deployment test** (frontend, backend, worker, minimal) |
| `mountedcm*.yaml` | Mounted config file scenarios |
| `cron-only.yaml` | CronJobs without Deployment |
| `hook-only.yaml` | Hooks without Deployment |
| `externalsecret-only.yaml` | ExternalSecrets only |
| `ingress-custom.yaml` | Ingress with deployment reference |
| `external-ingress.yaml` | Ingress pointing to external service |
| `rbac.yaml` | RBAC with roles and service accounts |
| `service-disabled.yaml` | Deployment with service disabled |
| `raw-deployment.yaml` | Deployment with raw image string |
| `deployment-hooks-cronjobs.yaml` | **Hooks/CronJobs inside deployments** (inheritance test) |
| `hooks-sa-inheritance.yaml` | **Hooks SA inheritance** (existing SA, explicit override) |

## CI/CD

GitHub Actions workflow (`.github/workflows/helm-ci.yml`) runs on push/PR:
1. `make lint-chart` - Lints all test scenarios
2. `make unit-test` - Runs helm-unittest suite (220 tests across 16 suites) via Docker
3. `make generate-templates` - Generates manifests
4. Uploads `generated-manifests/` as artifact

Release workflow (`.github/workflows/release.yml`) handles chart publishing.

## Working with This Codebase

- Always run `make lint-chart` and `make unit-test` after modifying templates or values
- Use `make generate-templates` to inspect rendered output before committing
- Unit tests are in `charts/global-chart/tests/` using helm-unittest framework (Docker-based, no local plugin needed)
- Add new test scenarios to `tests/` and update `TEST_CASES` in Makefile
- When adding new template helpers, place them in `templates/_helpers.tpl`
- README auto-generation uses helm-docs; run `make generate-docs` after changing value annotations
- When accessing nested optional fields in templates, use `$var := default (dict) $parent.field` to avoid nil pointer errors
- For boolean fields with `default`, never use `default true $var` — Go templates treat `false` as falsy and replace it with the default. Use `hasKey` + `ternary` instead: `hasKey $map "field" | ternary $map.field true`
- Never mutate `.Values` during rendering (e.g., `set $ing.annotations`). Use `deepCopy` to create a local copy first
- Every template must have a corresponding `*_test.yaml` in `charts/global-chart/tests/`
- When adding inheritance to deployment-level hooks/cronjobs, use `hasKey` to distinguish "not set" from "set but empty": `ternary $job.field $deploy.field (hasKey $job "field")`. Never use `if not $job.field` as it treats `{}` and `[]` as falsy and incorrectly inherits
- When calling shared helpers that can return empty (`renderImagePullSecrets`, `renderDnsConfig`, `renderResources`), always wrap with `{{- with }}` and use `nindent` to avoid blank lines: `{{- with (include "global-chart.renderFoo" $arg) }}{{- . | nindent N }}{{- end }}`
- Shared helpers must use `-}}` (trim-right) on the conditional/with line before literal content (e.g., `{{- with . -}}\nimagePullSecrets:`) to avoid a leading newline in the output that `nindent` would turn into a blank line
- Always update CLAUDE.md when architecture, commands, or key patterns change