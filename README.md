# Global Helm Chart

Reusable Helm chart providing configurable building blocks—Deployments, Services, Ingress, Jobs, ExternalSecrets, and more—for broadly adaptable Kubernetes applications.
The chart supports **multiple deployments** in a single release, each with independent configuration. CronJobs and Hooks can be defined at root level or inside deployments to inherit their configuration.

## Chart scope at a glance

- **Multi-deployment support**
  Define multiple independent deployments under `deployments.*`. Each gets its own Service, ConfigMap, Secret, ServiceAccount, and HPA.
- **Deployment primitives**
  Image can be a string (`nginx:1.25`) or a map (`repository/tag/digest`). Probes, resources, autoscaling (HPA), scheduling constraints, extra containers/init containers, pod recreation bumps, and ConfigMap/Secret `envFrom` are all configurable.
- **Networking**
  First-class Service configuration plus optional Ingress with TLS, class annotations, and routes to specific deployments. DNS options and host aliases can be defined per-deployment.
- **Configuration distribution**
  Inline ConfigMap/Secret data, mounted config files (single file) or bundles (projected lists of files), and volume templates (configMap/secret/emptyDir/PVC) are supported.
- **Lifecycle and batch**
  Helm hook jobs and CronJobs can be defined in two ways:
  - **Root level** (`hooks.*`, `cronJobs.*`): Standalone, use `fromDeployment` to copy image from a deployment
  - **Inside deployments** (`deployments.*.hooks`, `deployments.*.cronJobs`): Inherit image, configMap, secret, serviceAccount, nodeSelector, tolerations, affinity, and more from the parent deployment
- **Secret management**
  ExternalSecret resources with required field validation to avoid silent misconfigurations.
- **RBAC**
  Create Roles, ServiceAccounts, and RoleBindings for fine-grained access control.

## Prerequisites

- Helm 3.x
- Kubernetes 1.19 or newer

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

This repository ships with helper targets that exercise every supported scenario (multi-deployment, mounted config files, hooks, cron jobs, external secrets, ingress variations).

```bash
# Run helm lint across all test value files
make lint-chart

# Render manifests for visual inspection in generated-manifests/
make generate-templates
```

CI runs the same commands through the `Helm CI` GitHub workflow to keep the chart healthy on each push/PR.

## Values deep dive

All configuration lives under `charts/global-chart/values.yaml`. Highlights:

- `deployments` – map of named deployments. Each deployment generates its own Deployment, Service, ConfigMap, Secret, ServiceAccount, and HPA.
  - `image` can be `{ repository, tag, digest, pullPolicy }` or a single string.
  - `service.enabled: false` skips Service creation (useful for workers).
  - `hooks` and `cronJobs` defined inside a deployment inherit image, configMap, secret, serviceAccount, and scheduling constraints.
- `cronJobs` – root-level map keyed by job name. Use `fromDeployment` to copy image from a deployment, or specify `image` explicitly.
- `hooks` – root-level map of hook types (post-install/pre-upgrade/etc.) to job definitions. Use `fromDeployment` or `image`.
- `externalSecrets` – map keyed by logical name. Each entry must define `secretkey`, `remote.key`, and `secretstore.{kind,name}`.
- `ingress` – routes to specific deployments via `hosts[].deployment`, or to external services via `hosts[].service`.
- `rbacs` – create Roles, ServiceAccounts, and RoleBindings.

## Test scenarios

See the `tests/` directory for concrete examples:

| File                             | Description                                                                               |
| -------------------------------- | ----------------------------------------------------------------------------------------- |
| `test01/values.01.yaml`          | Full kitchen-sink (autoscaling, volumes, secrets, hooks, crons, ingress, ExternalSecrets) |
| `values.02.yaml`                 | Deployment with existing service account                                                  |
| `values.03.yaml`                 | Chart disabled (no output)                                                                |
| `multi-deployment.yaml`          | Multi-deployment test (frontend, backend, worker, minimal)                                |
| `deployment-hooks-cronjobs.yaml` | Hooks/CronJobs inside deployments (inheritance test)                                      |
| `mountedcm*.yaml`                | Mounted config file scenarios                                                             |
| `cron-only.yaml`                 | CronJobs without Deployment                                                               |
| `hook-only.yaml`                 | Hooks without Deployment                                                                  |
| `externalsecret-only.yaml`       | ExternalSecrets only                                                                      |
| `ingress-custom.yaml`            | Ingress with deployment reference                                                         |
| `external-ingress.yaml`          | Ingress pointing to external service                                                      |
| `rbac.yaml`                      | RBAC with roles and service accounts                                                      |
| `service-disabled.yaml`          | Deployment with service disabled                                                          |
| `raw-deployment.yaml`            | Deployment with raw image string                                                          |

## Testing & CI

Run `make lint-chart` locally to execute `helm lint --strict` across every scenario.
`make generate-templates` produces manifests in `generated-manifests/<scenario>/` for manual inspection.

The GitHub Action defined in `.github/workflows/helm-ci.yml` executes the same targets on pushes and pull requests, and uploads the generated manifests as an artifact for traceability.

## Useful references

- Core values: `charts/global-chart/values.yaml`
- Example scenarios: `tests/`
- Make targets: `Makefile`
- GitHub workflow: `.github/workflows/helm-ci.yml`
