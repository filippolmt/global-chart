# global-chart

![Version: 2.0.0](https://img.shields.io/badge/Version-2.0.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square)

Reusable Helm chart providing common building blocks—Deployments, Services, Ingress, Jobs, and more—for broadly adaptable Kubernetes applications.

**Homepage:** <https://github.com/filippomerante/global-chart>

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| Filippo Merante Caparrotta |  | <https://github.com/filippomerante> |

## Source Code

* <https://github.com/filippomerante/global-chart>

## Requirements

Kubernetes: `>=1.19.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| global | object | `{"commonAnnotations":{},"commonLabels":{},"imagePullSecrets":[],"imageRegistry":""}` | Global values shared across all deployments, cronJobs, and hooks |
| global.imageRegistry | string | `""` (no prefix) | Global image registry prefix (e.g., registry.example.com) |
| global.imagePullSecrets | list | `[]` | Global imagePullSecrets (used when deployment/cronJob/hook doesn't specify its own) |
| global.commonLabels | object | `{}` | Global labels applied to metadata.labels of ALL resources (not added to selector labels) |
| global.commonAnnotations | object | `{}` | Global annotations applied to metadata.annotations of ALL resources (including pod templates) |
| nameOverride | string | `""` | Override the chart name |
| fullnameOverride | string | `""` | Override the chart fullname |
| deployments | object | `{}` (empty map) | Multiple deployments configuration (map of named deployments). Each deployment supports an `enabled` field (bool, default `true`) to skip rendering of the Deployment and all its sub-resources (Service, ConfigMap, Secret, ServiceAccount, HPA, mounted ConfigMaps, CronJobs, Hooks). An Ingress that references a disabled deployment will fail with a clear error. |
| ingress | object | `{"annotations":{},"className":"nginx","enabled":false,"hosts":[{"deployment":"","host":"chart-example.local","paths":[{"path":"/","pathType":"ImplementationSpecific"}],"service":{"name":"","port":0}}],"tls":[]}` | Ingress configuration |
| ingress.enabled | bool | `false` | Enable or disable Ingress |
| ingress.className | string | `"nginx"` | IngressClass to use (e.g., nginx) |
| ingress.annotations | object | `{}` | Annotations to add to the Ingress |
| ingress.tls | list | `[]` | TLS configuration for secure hosts |
| ingress.hosts | list | `[{"deployment":"","host":"chart-example.local","paths":[{"path":"/","pathType":"ImplementationSpecific"}],"service":{"name":"","port":0}}]` | Definitions for each host rule |
| ingress.hosts[0].deployment | string | `""` | Name of the deployment to route traffic to (required unless service.name is set) |
| ingress.hosts[0].service | object | `{"name":"","port":0}` | Service backend override (use instead of deployment for external services) |
| ingress.hosts[0].service.name | string | `""` | Explicit service name (overrides deployment reference) |
| ingress.hosts[0].service.port | int | `0` | Service port (default: deployment's service.port or 80) |
| ingress.hosts[0].paths | list | `[{"path":"/","pathType":"ImplementationSpecific"}]` | HTTP path definitions for this host |
| httpRoute | object | `{"annotations":{},"enabled":false,"hostnames":[],"parentRefs":[],"rules":[]}` | HTTPRoute (Gateway API v1) — alternative to Ingress. The chart renders only the HTTPRoute resource; the referenced Gateway must be managed externally (e.g. by your platform team or a separate infra chart). Mutually exclusive with `ingress.enabled` — enabling both fails template render. |
| httpRoute.enabled | bool | `false` | Enable HTTPRoute rendering. Requires Gateway API v1 CRDs in the cluster. |
| httpRoute.annotations | object | `{}` | Annotations applied to the HTTPRoute resource (merged with global.commonAnnotations). |
| httpRoute.parentRefs | list | `[]` | References to existing Gateway resources. At least one is required when enabled. Each entry: { name, namespace?, sectionName?, port?, kind?, group? } |
| httpRoute.hostnames | list | `[]` | Hostnames the HTTPRoute responds to. Optional but typical for HTTP routing. |
| httpRoute.rules | list | `[]` | Routing rules. Each rule may declare matches, filters, backendRefs, timeouts. backendRefs accept either `deployment: <name>` (resolves to the chart-managed Service) or `service: { name, port }` for an external Service. |
| cronJobs | object | `{}` | CronJobs configuration (map of named cronJobs). Can also be defined inside deployments to inherit image, configMap, secret, SA. |
| hooks | object | `{}` | Hook jobs for chart lifecycle (install/upgrade). Can also be defined inside deployments to inherit image, configMap, secret, SA. |
| externalSecrets | object | `{}` | ExternalSecrets definitions for secret management |
| defaults | object | `{"resources":{"requests":{"cpu":"100m","memory":"128Mi"}}}` | Default resource settings for CronJobs and Hooks when not specified per-job |
| rbacs | object | `{"roles":[]}` | RBAC configuration: create multiple service accounts, roles and rolebindings |
| rbacs.roles | list | `[]` | Set serviceAccount.create to false to bind to an existing account without creating it. |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
