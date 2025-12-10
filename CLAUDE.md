# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Global-chart is a reusable Helm chart providing configurable Kubernetes building blocks: Deployments, Services, Ingress, CronJobs, Hook Jobs, ExternalSecrets, and RBAC resources.

**Version 1.0.0** introduced multi-deployment support, allowing multiple independent deployments in a single release. Each deployment gets its own resources (Service, ConfigMap, Secret, ServiceAccount, HPA).

## Common Commands

```bash
# Show all available commands
make help

# Lint all test scenarios (runs helm lint --strict)
make lint-chart

# Generate manifests for visual inspection (outputs to generated-manifests/)
make generate-templates

# Run both lint and generate
make all

# Run kube-linter against generated manifests (requires Docker)
make kube-linter

# Generate helm-docs (requires Docker)
make generate-docs

# Package chart for distribution
make package

# Install test scenarios to a cluster
make install-test01      # Full kitchen-sink test
make install-test02      # Deployment with existing SA
make install-multi       # Multi-deployment test
make install-mountedcm1  # Mounted config files test

# Cleanup
make clean               # Remove generated files
make clean-all           # Clean + uninstall helm releases
```

## Architecture

### Chart Structure

```
charts/global-chart/
├── Chart.yaml              # Chart metadata (version 1.0.0)
├── values.yaml             # Default values with helm-docs annotations
├── templates/
│   ├── _helpers.tpl        # Template functions (fullname, labels, imageString, etc.)
│   ├── deployment.yaml     # Deployments (iterates over deployments map)
│   ├── service.yaml        # Services (per-deployment, can be disabled)
│   ├── serviceaccount.yaml # ServiceAccounts (per-deployment)
│   ├── configmap.yaml      # ConfigMaps (per-deployment)
│   ├── secret.yaml         # Secrets (per-deployment)
│   ├── mounted-configmap.yaml  # Mounted ConfigMaps (per-deployment)
│   ├── hpa.yaml            # HPAs (per-deployment)
│   ├── ingress.yaml        # Ingress (routes to specific deployments)
│   ├── cronjob.yaml        # CronJobs (root-level or inside deployments)
│   ├── hooks.yaml          # Helm hook Jobs (root-level or inside deployments)
│   ├── externalsecret.yaml # ExternalSecret CRDs
│   └── rbac.yaml           # Roles and RoleBindings
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

4. **Image specification**: The `image` field accepts either a string (`nginx:1.25`) or a map (`{repository, tag, digest, pullPolicy}`). Helper `global-chart.imageString` handles both.

5. **Hooks/CronJobs inheritance**: Two placement options:
   - **Root level** (`hooks:`, `cronJobs:`): Standalone, use `fromDeployment` to copy image only
   - **Inside deployments** (`deployments.*.hooks`, `deployments.*.cronJobs`): Inherit image, configMap, secret, serviceAccount, envFromConfigMaps, envFromSecrets, additionalEnvs, imagePullSecrets, hostAliases, nodeSelector, tolerations, affinity from parent deployment

6. **Service can be disabled**: Set `service.enabled: false` on a deployment to skip Service creation (useful for workers/background jobs).

7. **Mounted config files**: Two modes exist:
   - `files`: Individual ConfigMaps, one per file
   - `bundles`: Projected sets of multiple files in one ConfigMap

### Resource Naming Convention

| Resource | Pattern |
|----------|---------|
| Deployment, Service, SA, ConfigMap, Secret, HPA | `{release}-{chart}-{deploymentName}` |
| Mounted ConfigMap | `{release}-{chart}-{deploymentName}-md-cm-{name}` |
| Ingress | `{release}-{chart}` |
| CronJob (root level) | `{release}-{chart}-{cronjobName}` |
| CronJob (inside deployment) | `{release}-{chart}-{deploymentName}-{cronjobName}` |
| Hook Job (root level) | `{release}-{chart}-{hookType}-{jobName}` |
| Hook Job (inside deployment) | `{release}-{chart}-{deploymentName}-{hookType}-{jobName}` |

### Test Scenarios

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

## CI/CD

GitHub Actions workflow (`.github/workflows/helm-ci.yml`) runs on push/PR:
1. `make lint-chart` - Lints all test scenarios
2. `make generate-templates` - Generates manifests
3. Uploads `generated-manifests/` as artifact

Release workflow (`.github/workflows/release.yml`) handles chart publishing.

## Working with This Codebase

- Always run `make lint-chart` after modifying templates or values
- Use `make generate-templates` to inspect rendered output before committing
- Add new test scenarios to `tests/` and update `TEST_CASES` in Makefile
- When adding new template helpers, place them in `templates/_helpers.tpl`
- README auto-generation uses helm-docs; run `make generate-docs` after changing value annotations
- When accessing nested optional fields in templates, use `$var := default (dict) $parent.field` to avoid nil pointer errors
- Ricordati sempre di modificare CLOUDE.md quando cambia qualcosa