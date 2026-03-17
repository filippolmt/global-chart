# Global Helm Chart

Reusable Helm chart providing configurable building blocks—Deployments, Services, Ingress, Jobs, ExternalSecrets, and more—for broadly adaptable Kubernetes applications.
The chart supports **multiple deployments** in a single release, each with independent configuration. CronJobs and Hooks can be defined at root level or inside deployments to inherit their configuration.

## Chart scope at a glance

- **Multi-deployment support**
  Define multiple independent deployments under `deployments.*`. Each gets its own Service, ConfigMap, Secret, ServiceAccount, HPA, PDB, and NetworkPolicy.
- **Deployment primitives**
  Image can be a string (`nginx:1.25`) or a map (`repository/tag/digest`). Probes, resources, autoscaling (HPA), scheduling constraints, extra containers/init containers, pod recreation bumps, and ConfigMap/Secret `envFrom` are all configurable.
- **Networking**
  First-class Service configuration (with per-service annotations) plus optional Ingress with TLS, class annotations, and routes to specific deployments. DNS options and host aliases can be defined per-deployment.
- **Configuration distribution**
  Inline ConfigMap/Secret data, mounted config files (single file) or bundles (projected lists of files), and volume templates (configMap/secret/emptyDir/PVC or native K8s spec) are supported.
- **Lifecycle and batch**
  Helm hook jobs and CronJobs can be defined in two ways:
  - **Root level** (`hooks.*`, `cronJobs.*`): Standalone, use `fromDeployment` to copy image from a deployment
  - **Inside deployments** (`deployments.*.hooks`, `deployments.*.cronJobs`): Inherit image, configMap, secret, serviceAccount, hostAliases, podSecurityContext, securityContext, dnsConfig (cronJobs), nodeSelector, tolerations, affinity, and more from the parent deployment
  - Hook prerequisite ConfigMap/Secret are created automatically with correct weight ordering
- **Secret management**
  ExternalSecret resources with required field validation to avoid silent misconfigurations.
- **RBAC**
  Create Roles, ServiceAccounts, and RoleBindings for fine-grained access control.
- **Global values**
  `global.imageRegistry`, `global.imagePullSecrets`, `global.commonLabels`, `global.commonAnnotations` apply across all resources.
- **Validation**
  JSON Schema Draft 7 (`values.schema.json`) for input validation and IDE autocomplete. Name collision detection at render time.

## Prerequisites

- Helm 3.x
- Kubernetes 1.19 or newer
- Docker (for unit tests, kubeconform, kube-linter, helm-docs)

## Quick start

```bash
# Add the chart repository
helm repo add global-chart https://filippolmt.github.io/global-chart
helm repo update

# Install with your values
helm upgrade --install my-release global-chart/global-chart \
  --namespace my-namespace \
  --create-namespace \
  --values path/to/values.yaml
```

## Example: Multi-deployment with inherited hooks/cronJobs

```yaml
deployments:
  backend:
    image: myapp/backend:v2.0
    replicaCount: 2
    configMap:
      DB_HOST: postgres.db.svc
    secret:
      DB_PASSWORD: supersecret
    serviceAccount:
      create: true
    # Hooks inside deployment - inherit image, configMap, secret, SA
    hooks:
      pre-upgrade:
        migrate:
          command: ["./migrate.sh"]
    # CronJobs inside deployment - inherit everything from parent
    cronJobs:
      backup:
        schedule: "0 2 * * *"
        command: ["./backup.sh"]

  worker:
    image: myapp/worker:v2.0
    service:
      enabled: false # Workers don't need a service

# Root-level hooks (standalone, must specify image or fromDeployment)
hooks:
  post-upgrade:
    notify:
      image: curlimages/curl:latest
      command: ["curl", "-X", "POST", "https://hooks.slack.com/..."]

# Ingress routes to specific deployments
ingress:
  enabled: true
  hosts:
    - host: api.example.com
      deployment: backend
      paths:
        - path: /
```

## Local development

```bash
# Show all available commands
make help

# Run full pipeline: lint, unit tests, bad-values, generate, kubeconform, kube-linter
make all

# Individual targets
make lint-chart            # Lint all 17 test scenarios
make unit-test             # Run 312 helm-unittest tests via Docker
make validate-bad-values   # Verify schema rejects invalid values
make generate-templates    # Render manifests for visual inspection
make kubeconform           # Validate manifests against K8s 1.29
make kube-linter           # Lint manifests (addAllBuiltIn)
make generate-docs         # Regenerate helm-docs

# Install a test scenario to a cluster
make install SCENARIO=test01

# Render a single template for debugging
make render VALUES=tests/test01/values.01.yaml TEMPLATE=deployment.yaml
```

## Testing & CI

The chart has multiple layers of testing:

- **Lint scenarios** (`make lint-chart`): Runs `helm lint --strict` across 17 value files in `tests/`.
- **Unit tests** (`make unit-test`): 312 helm-unittest tests across 17 suites in `charts/global-chart/tests/`, including negative `failedTemplate` tests.
- **Schema validation** (`make validate-bad-values`): Verifies schema correctly rejects 3 invalid value files.
- **Manifest validation** (`make kubeconform`): Validates 161 generated resources against K8s 1.29 schema.
- **Best practices** (`make kube-linter`): Lints manifests with `addAllBuiltIn: true` and 28 documented exclusions.

The GitHub Action (`.github/workflows/helm-ci.yml`) executes all steps on pushes and pull requests, pre-pulling Docker images with retry for resilience.

## Test scenarios

See the `tests/` directory for concrete examples:

| File                             | Description                                                                               |
| -------------------------------- | ----------------------------------------------------------------------------------------- |
| `test01/values.01.yaml`          | Full kitchen-sink (autoscaling, volumes, secrets, hooks, crons, ingress, ExternalSecrets) |
| `values.02.yaml`                 | Deployment with existing service account                                                  |
| `values.03.yaml`                 | Chart disabled (no output)                                                                |
| `multi-deployment.yaml`          | Multi-deployment test (frontend, backend, worker, minimal)                                |
| `deployment-hooks-cronjobs.yaml` | Hooks/CronJobs inside deployments (inheritance test)                                      |
| `hooks-sa-inheritance.yaml`      | Hooks SA inheritance (existing SA, explicit override)                                     |
| `mountedcm*.yaml`                | Mounted config file scenarios                                                             |
| `cron-only.yaml`                 | CronJobs without Deployment                                                               |
| `hook-only.yaml`                 | Hooks without Deployment                                                                  |
| `externalsecret-only.yaml`       | ExternalSecrets only                                                                      |
| `ingress-custom.yaml`            | Ingress with deployment reference                                                         |
| `external-ingress.yaml`          | Ingress pointing to external service                                                      |
| `rbac.yaml`                      | RBAC with roles and service accounts                                                      |
| `service-disabled.yaml`          | Deployment with service disabled                                                          |
| `raw-deployment.yaml`            | Deployment with raw image string                                                          |
| `name-collision.yaml`            | Name collision detection test                                                             |
| `bad-values/*.yaml`              | Schema rejection tests                                                                    |

## Values reference

All configuration lives under `charts/global-chart/values.yaml`. See `charts/global-chart/README.md` for the auto-generated values table.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history, breaking changes, and migration guides.

## Useful references

- Core values: `charts/global-chart/values.yaml`
- JSON Schema: `charts/global-chart/values.schema.json`
- Example scenarios: `tests/`
- Make targets: `Makefile`
- GitHub workflow: `.github/workflows/helm-ci.yml`
