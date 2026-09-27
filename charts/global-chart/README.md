# global-chart

![Version: 3.0.1](https://img.shields.io/badge/Version-3.0.1-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square)

Reusable Helm chart for multi-deployment Kubernetes applications—Deployments, Services, Ingress, CronJobs, Hooks, ExternalSecrets, RBAC, HPA, PDB, NetworkPolicy, and more.

**Homepage:** <https://github.com/filippolmt/global-chart>

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| Filippo Merante Caparrotta |  | <https://github.com/filippolmt> |

## Source Code

* <https://github.com/filippolmt/global-chart>

## Requirements

Kubernetes: `>=1.23.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| global | object | `{"commonAnnotations":{},"commonLabels":{},"imagePullSecrets":[],"imageRegistry":""}` | Global values shared across all deployments, cronJobs, and hooks |
| global.imageRegistry | string | `""` (no prefix) | Global image registry prefix (e.g., registry.example.com) |
| global.imagePullSecrets | list | `[]` | Global imagePullSecrets (used when deployment/cronJob/hook doesn't specify its own) |
| global.commonLabels | object | `{}` | Global labels applied to metadata.labels of ALL resources (not added to selector labels). A per-resource label of the same name wins; the chart's own `app.kubernetes.io/*` and `helm.sh/chart` labels win over both, since the selectors are built from them |
| global.commonAnnotations | object | `{}` | Global annotations applied to metadata.annotations of ALL resources (including pod templates). A per-resource annotation of the same name wins, empty string included. The `helm.sh/hook*` annotations the chart emits itself are ignored here |
| nameOverride | string | `""` | Override the chart name. Sets `app.kubernetes.io/name`, which is part of the Deployment's immutable `spec.selector`: decide it before the first install, or every existing Deployment has to be deleted and recreated to change it. |
| fullnameOverride | string | `""` | Override the chart fullname |
| deployments | object | `{}` (empty map) | Multiple deployments configuration (map of named deployments). Each deployment supports an `enabled` field (bool, default `true`) to skip rendering of the Deployment and all its sub-resources (Service, ConfigMap, Secret, ServiceAccount, HPA, mounted ConfigMaps, CronJobs, Hooks). An Ingress that references a disabled deployment will fail with a clear error. |
| ingress | object | `{"annotations":{},"className":"nginx","enabled":false,"hosts":[{"deployment":"","host":"chart-example.local","paths":[{"path":"/","pathType":"ImplementationSpecific"}],"service":{"name":""}}],"tls":[]}` | Ingress configuration |
| ingress.enabled | bool | `false` | Enable or disable Ingress |
| ingress.className | string | `"nginx"` | IngressClass to use (e.g., nginx) |
| ingress.annotations | object | `{}` | Annotations to add to the Ingress |
| ingress.tls | list | `[]` | TLS configuration for secure hosts |
| ingress.hosts | list | `[{"deployment":"","host":"chart-example.local","paths":[{"path":"/","pathType":"ImplementationSpecific"}],"service":{"name":""}}]` | Definitions for each host rule |
| ingress.hosts[0].deployment | string | `""` | Name of the deployment to route traffic to (required unless service.name is set) |
| ingress.hosts[0].service | object | `{"name":""}` | Service backend override (use instead of deployment for external services). Optional `port`, 1-65535: omitted, it is the deployment's service.port, or 80 for a service.name backend |
| ingress.hosts[0].service.name | string | `""` | Explicit service name (overrides deployment reference) |
| ingress.hosts[0].paths | list | `[{"path":"/","pathType":"ImplementationSpecific"}]` | HTTP path definitions for this host |
| httpRoute | object | `{"annotations":{},"enabled":false,"hostnames":[],"parentRefs":[],"rules":[]}` | HTTPRoute (Gateway API v1) — alternative to Ingress. The chart renders only the HTTPRoute resource; the referenced Gateway must be managed externally (e.g. by your platform team or a separate infra chart). Mutually exclusive with `ingress.enabled` — enabling both fails template render. |
| httpRoute.enabled | bool | `false` | Enable HTTPRoute rendering. Requires Gateway API v1 CRDs in the cluster. |
| httpRoute.annotations | object | `{}` | Annotations applied to the HTTPRoute resource. Like every annotations field, merged with global.commonAnnotations, this one winning |
| httpRoute.parentRefs | list | `[]` | References to existing Gateway resources. At least one is required when enabled. Each entry: { name, namespace?, sectionName?, port?, kind?, group? } |
| httpRoute.hostnames | list | `[]` | Hostnames the HTTPRoute responds to. Optional but typical for HTTP routing. |
| httpRoute.rules | list | `[]` | Routing rules. Each rule may declare matches, filters, backendRefs, timeouts. backendRefs accept either `deployment: <name>` (resolves to the chart-managed Service) or `service: { name, port }` for an external Service. |
| cronJobs | object | `{}` | CronJobs configuration (map of named cronJobs). Can also be defined inside deployments to inherit image, configMap, secret, SA. |
| hooks | object | `{}` | Hook jobs for chart lifecycle (install/upgrade). Can also be defined inside deployments to inherit image, configMap, secret, SA. |
| externalSecrets | object | `{}` | ExternalSecrets definitions for secret management. Each entry renders one ExternalSecret. The `remote` map (single-key form) and each `data[].remote` accept `key`, `property` (a gjson path selecting one key out of a JSON payload), `version` (string or number, quoted on render), `conversionStrategy`, `decodingStrategy` and `metadataPolicy`. `dataFrom` is rendered verbatim. Jobs and deployments read the produced Secret through their own `externalSecrets: [{name: <key>}]` list; for every key a pre-* (pre-delete excepted) or post-delete hook reads, the chart also renders a hook-prerequisite copy producing `<target>-hook`. |
| kedaTriggerAuthentications | object | `{}` | KEDA TriggerAuthentication definitions, shared by the triggers of any deployment. Rendered as `{release}-{chart}-{key}`; reference them from a trigger by their key here and the chart resolves the full name. |
| defaults | object | `{"resources":{"requests":{"cpu":"100m","memory":"128Mi"}}}` | Default resource settings for CronJobs and Hooks when not specified per-job |
| rbacs | object | `{"roles":[]}` | RBAC configuration: create multiple service accounts, roles and rolebindings |
| rbacs.roles | list | `[]` | Set serviceAccount.create to false to bind to an existing account without creating it. |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
