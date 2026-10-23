# global-chart

![Version: 4.0.0](https://img.shields.io/badge/Version-4.0.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square)

Reusable Helm chart for multi-workload Kubernetes applications—Deployments, StatefulSets, Services, Ingress, CronJobs, Hooks, ExternalSecrets, RBAC, HPA, PDB, NetworkPolicy, and more.

**Homepage:** <https://github.com/filippolmt/global-chart>

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| Filippo Merante Caparrotta |  | <https://github.com/filippolmt> |

## Source Code

* <https://github.com/filippolmt/global-chart>

## Requirements

Kubernetes: `>=1.27.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| global | object | `{"commonAnnotations":{},"commonLabels":{},"imagePullSecrets":[],"imageRegistry":""}` | Global values shared across all workloads, cronJobs, and hooks |
| global.imageRegistry | string | `""` (no prefix) | Global image registry prefix (e.g., registry.example.com) |
| global.imagePullSecrets | list | `[]` | Global imagePullSecrets (used when workload/cronJob/hook doesn't specify its own) |
| global.commonLabels | object | `{}` | Global labels applied to metadata.labels of ALL resources (not added to selector labels). The chart's own `app.kubernetes.io/*` and `helm.sh/chart` labels win over them, since the selectors are built from them; a per-resource label (podLabels) wins over both |
| global.commonAnnotations | object | `{}` | Global annotations applied to metadata.annotations of ALL resources (including pod templates). A per-resource annotation of the same name wins, empty string included. The `helm.sh/hook*` annotations the chart emits itself are ignored here |
| nameOverride | string | `""` | Override the chart name. Sets `app.kubernetes.io/name`, which is part of the workload's immutable `spec.selector`: decide it before the first install, or every existing workload has to be deleted and recreated to change it. |
| fullnameOverride | string | `""` | Override the chart fullname |
| workloads | object | `{}` (empty map) | The workloads of the release (map of named entries, each a Deployment or a StatefulSet by `kind`). Each entry supports an `enabled` field (bool, default `true`) to skip rendering of the workload and all its sub-resources (Service, ConfigMap, Secret, ServiceAccount, HPA, mounted ConfigMaps, CronJobs, Hooks). An Ingress that references a disabled entry will fail with a clear error. |
| ingress | object | `{"annotations":{},"className":"nginx","enabled":false,"hosts":[{"host":"chart-example.local","paths":[{"path":"/","pathType":"ImplementationSpecific"}],"service":{"name":""},"workload":""}],"tls":[]}` | Ingress configuration |
| ingress.enabled | bool | `false` | Enable or disable Ingress |
| ingress.className | string | `"nginx"` | IngressClass to use (e.g., nginx) |
| ingress.annotations | object | `{}` | Annotations to add to the Ingress |
| ingress.tls | list | `[]` | TLS configuration for secure hosts |
| ingress.hosts | list | `[{"host":"chart-example.local","paths":[{"path":"/","pathType":"ImplementationSpecific"}],"service":{"name":""},"workload":""}]` | Definitions for each host rule |
| ingress.hosts[0].workload | string | `""` | Name of the workload to route traffic to (required unless service.name is set). An optional `portName` next to it picks a TCP port of its Service by name (service.portName or a service.extraPorts[].name); omitted, the primary port |
| ingress.hosts[0].service | object | `{"name":""}` | Service backend override (use instead of workload for external services). Optional `port`, 1-65535: omitted, it is the workload's service.port, or 80 for a service.name backend |
| ingress.hosts[0].service.name | string | `""` | Explicit service name (overrides workload reference) |
| ingress.hosts[0].paths | list | `[{"path":"/","pathType":"ImplementationSpecific"}]` | HTTP path definitions for this host |
| httpRoute | object | `{"annotations":{},"basicAuth":{"enabled":false,"username":"admin"},"enabled":false,"hostnames":[],"parentRefs":[],"rules":[]}` | HTTPRoute (Gateway API v1) — alternative to Ingress. The chart renders HTTPRoutes and optional Envoy Basic Auth resources; the referenced Gateway must be managed externally (e.g. by your platform team or a separate infra chart). Mutually exclusive with `ingress.enabled` — enabling both fails template render. |
| httpRoute.enabled | bool | `false` | Enable HTTPRoute rendering. The render fails unless the cluster serves gateway.networking.k8s.io/v1 HTTPRoute (Gateway API v1.0.0 or later); an offline render needs `--api-versions gateway.networking.k8s.io/v1/HTTPRoute`. |
| httpRoute.annotations | object | `{}` | Annotations applied to the HTTPRoute resource. Like every annotations field, merged with global.commonAnnotations, this one winning |
| httpRoute.basicAuth | object | `{"enabled":false,"username":"admin"}` | Envoy Gateway Basic Auth for every rule of this route. Requires HTTPS and the SecurityPolicy CRD. With Argo CD, ignore /data of the generated Secret and enable RespectIgnoreDifferences=true BEFORE the first sync; otherwise every render generates new credentials. See the repository README. |
| httpRoute.basicAuth.enabled | bool | `false` | Generate a random credentials Secret and an Envoy SecurityPolicy. |
| httpRoute.basicAuth.username | string | `"admin"` | Basic Auth username; letters, digits, underscores and hyphens only. Defaults to admin in httpRoutes entries too. Existing Secret data is preserved by Argo CD, so editing this does not rotate credentials. |
| httpRoute.parentRefs | list | `[]` | References to existing Gateway resources. At least one is required when enabled. Each entry: { name, namespace?, sectionName?, port?, kind?, group? } |
| httpRoute.hostnames | list | `[]` | Hostnames the HTTPRoute responds to. Optional but typical for HTTP routing. |
| httpRoute.rules | list | `[]` | Routing rules. Each rule may declare matches, filters, backendRefs, timeouts. backendRefs accept either `workload: <name>` (resolves to the chart-managed Service; an optional `portName` picks service.portName or a service.extraPorts[].name, which must be TCP — omitted, the primary port) or `service: { name, port }` for an external Service. |
| httpRoutes | object | `{}` | HTTPRoutes, one per entry, named `<fullname>-<key>` (issue #195): for a release whose hostnames reach different workloads, or attach to different Gateways. Each entry has the fields of `httpRoute` without `enabled`: an entry present is a route rendered, so `parentRefs` and `rules` are required. They coexist with `httpRoute`, the single-route shorthand: together they are the HTTP routing layer, which excludes `ingress`. |
| tcpRoutes | object | `{}` | TCPRoutes (gateway.networking.k8s.io/v1, Gateway API v1.6.0 or later), one per entry, named `<fullname>-<key>`: raw TCP ports on an existing Gateway listener, for the protocols that are not HTTP. An entry present is a route rendered. They coexist with `ingress` / `httpRoute`, and may attach to different Gateways. The render fails unless the cluster serves gateway.networking.k8s.io/v1 TCPRoute; an offline render needs `--api-versions gateway.networking.k8s.io/v1/TCPRoute`. Each entry: { annotations?, parentRefs (>= 1), rules (>= 1) }; each rule: { name?, backendRefs (>= 1) }; each backendRef: `workload: <name>` with an optional `portName` (service.portName or a service.extraPorts[].name; omitted, the primary port), or `service: { name, port }`, plus an optional `weight`. The port picked must be TCP. |
| udpRoutes | object | `{}` | UDPRoutes (gateway.networking.k8s.io/v1, Gateway API v1.6.0 or later): the same shape as `tcpRoutes`, one per entry, named `<fullname>-<key>`. The port a backendRef picks must be UDP. An offline render needs `--api-versions gateway.networking.k8s.io/v1/UDPRoute`. |
| cronJobs | object | `{}` | CronJobs configuration (map of named cronJobs). Can also be defined inside workloads to inherit image, configMap, secret, SA. |
| hooks | object | `{}` | Hook jobs for chart lifecycle (install/upgrade). Can also be defined inside workloads to inherit image, configMap, secret, SA. |
| externalSecrets | object | `{}` | ExternalSecrets definitions for secret management. Each entry renders one ExternalSecret. The `remote` map (single-key form) and each `data[].remote` accept `key`, `property` (a gjson path selecting one key out of a JSON payload), `version` (string or number, quoted on render), `conversionStrategy`, `decodingStrategy` and `metadataPolicy`. `dataFrom` is rendered verbatim. Jobs and workloads read the produced Secret through their own `externalSecrets: [{name: <key>}]` list; for every key a pre-* (pre-delete excepted) or post-delete hook reads, the chart also renders a hook-prerequisite copy producing `<target>-hook`. |
| kedaTriggerAuthentications | object | `{}` | KEDA TriggerAuthentication definitions, shared by the triggers of any workload. Rendered as `{release}-{chart}-{key}`; reference them from a trigger by their key here and the chart resolves the full name. |
| defaults | object | `{"resources":{"requests":{"cpu":"100m","memory":"128Mi"}}}` | Default resource settings for CronJobs and Hooks when not specified per-job |
| rbacs | object | `{"roles":[]}` | RBAC configuration: create multiple service accounts, roles and rolebindings |
| rbacs.roles | list | `[]` | Set serviceAccount.create to false to bind to an existing account without creating it. |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
