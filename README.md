# Global Helm Chart

Reusable Helm chart providing configurable building blocks—Deployments, Services, Ingress, Jobs, ExternalSecrets, and more—for broadly adaptable Kubernetes applications.  
The chart is intentionally opinionated around a single `deployment` root while exposing switches to render only the pieces you need (for example: CronJobs or hook Jobs without a Deployment, or an Ingress that targets an external service).

## Chart scope at a glance

- **Deployment primitives**  
  Image can be a string (`nginx:1.25`) or a map (`repository/tag/digest`). Probes, resources, autoscaling (HPA), scheduling constraints, extra containers/init containers, pod recreation bumps, and ConfigMap/Secret `envFrom` are all configurable.
- **Networking**  
  First-class Service configuration plus optional Ingress with TLS, class annotations, and compatibility layers for older Kubernetes versions. DNS options and host aliases can be defined globally.
- **Configuration distribution**  
  Inline ConfigMap/Secret data, mounted config files (single file) or bundles (projected lists of files), and volume templates (configMap/secret/emptyDir/PVC) are supported.
- **Lifecycle and batch**  
  Helm hook jobs (`hooks.*`) and CronJobs (`cronJobs.*`) inherit settings from the main deployment by default but can opt out or override per-item (volumes, service account, envs, etc.).
- **Secret management**  
  ExternalSecret resources with required field validation to avoid silent misconfigurations.

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

## Local development

This repository ships with helper targets that exercise every supported scenario (deployment, mounted config files, hooks, cron jobs, external secrets, ingress variations).

```bash
# Run helm lint across all test value files
make lint-chart

# Render manifests for visual inspection in generated-manifests/
make generate-templates
```

CI runs the same commands through the `Helm CI` GitHub workflow to keep the chart healthy on each push/PR.

## Values deep dive

All configuration lives under `charts/global-chart/values.yaml`. Highlights:

- `deployment` – controls the core workload. Set `enabled: true` when you need a Deployment. When `enabled: false`, the chart can still render hooks, CronJobs, Ingress, or ExternalSecrets if those sections are populated.
  - `image` can be `{ repository, tag, digest, pullPolicy }` or a single string.
  - `mountedConfigFiles` has two modes: `files` (one ConfigMap per file) or `bundles` (projected sets of files). The main Deployment automatically mounts them when supplied.
  - `autoscaling.enabled` with CPU/memory targets generates an HPA (`templates/hpa.yaml`).
- `cronJobs` – map keyed by job name. Each job inherits volumes, envs, service account, mounted configs when desired (see `inheritFromDeployment` flags).
- `hooks` – map of hook types (post-install/pre-upgrade/etc.) to job definitions. Additional volumes/envs behave like cronJobs.
- `externalSecrets` – map keyed by logical name. Each entry must define `secretkey`, `remote.key`, and `secretstore.{kind,name}`.
- `ingress` – even if the deployment is disabled, you can target an external service via `hosts[].service` overrides.

See the `tests/` directory for concrete examples:

- `test01/values.01.yaml` – full kitchen-sink deployment (autoscaling, volumes, secrets, hooks, cron jobs, ingress, ExternalSecrets).
- `values.02.yaml` – deployment with existing service account and config-map volume.
- `values.03.yaml` – chart disabled (sanity check for no output).
- `mountedcm*.yaml` – rich mounted config scenarios.
- `cron-only.yaml`, `hook-only.yaml`, `externalsecret-only.yaml`, `ingress-custom.yaml`, `external-ingress.yaml` – isolated resources without a Deployment.

## Testing & CI

Run `make lint-chart` locally to execute `helm lint --strict` across every scenario.  
`make generate-templates` produces manifests in `generated-manifests/<scenario>/` for manual inspection.

The GitHub Action defined in `.github/workflows/helm-ci.yml` executes the same targets on pushes and pull requests, and uploads the generated manifests as an artifact for traceability.

## Useful references

- Core values: `charts/global-chart/values.yaml`
- Example scenarios: `tests/`
- Make targets: `Makefile`
- GitHub workflow: `.github/workflows/helm-ci.yml`
