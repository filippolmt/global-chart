# global-chart

![Version: 0.11.1](https://img.shields.io/badge/Version-0.11.1-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square)

Reusable Helm chart providing common building blocks—Deployments, Services, Ingress, Jobs, and more—for broadly adaptable Kubernetes applications.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| deployment | object | `{"additionalEnvs":[],"affinity":{},"autoscaling":{"behavior":{"scaleDown":{},"scaleUp":{}},"enabled":false,"maxReplicas":10,"minReplicas":2,"targetCPUUtilizationPercentage":"","targetMemoryUtilizationPercentage":""},"configMap":{},"dnsConfig":{"nameservers":[],"options":[],"searches":[]},"enabled":false,"envFromConfigMaps":[],"envFromSecrets":[],"extraContainers":[],"extraInitContainers":[],"fullnameOverride":"","hostAliases":[],"image":{"pullPolicy":"IfNotPresent","repository":"","tag":""},"imagePullSecrets":[],"livenessProbe":{},"mountedConfigFiles":{"bundles":[],"files":[]},"nameOverride":"","nodeSelector":{},"podAnnotations":{},"podLabels":{},"podRecreation":{"enabled":false},"podSecurityContext":{},"readinessProbe":{},"replicaCount":2,"resources":{"requests":{"cpu":"100m","memory":"64Mi"}},"secret":{},"securityContext":{},"service":{"port":80,"portName":"http","protocol":"TCP","targetPort":"http","type":"ClusterIP"},"serviceAccount":{"annotations":{},"automount":true,"create":true,"name":""},"tolerations":[],"volumeMounts":[],"volumes":[]}` | Deployment configuration |
| deployment.enabled | bool | `false` | Enable/disable the deployment of the application |
| deployment.replicaCount | int | `2` | Number of replicas to deploy, default is 2 |
| deployment.image | object | `{"pullPolicy":"IfNotPresent","repository":"","tag":""}` | Image configuration |
| deployment.image.repository | string | `""` | Image repository (e.g., nginx) |
| deployment.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy: Always, IfNotPresent, or Never |
| deployment.image.tag | string | `""` | Image tag (e.g., "1.23.3") |
| deployment.imagePullSecrets | list | `[]` | List of imagePullSecrets for private registries |
| deployment.nameOverride | string | `""` | Override the chart name |
| deployment.fullnameOverride | string | `""` | Override the chart fullname |
| deployment.serviceAccount | object | `{"annotations":{},"automount":true,"create":true,"name":""}` | ServiceAccount creation and mounting |
| deployment.serviceAccount.create | bool | `true` | Create a ServiceAccount |
| deployment.serviceAccount.automount | bool | `true` | Automount the ServiceAccount credentials |
| deployment.serviceAccount.annotations | object | `{}` | Annotations to add to the ServiceAccount |
| deployment.serviceAccount.name | string | `""` | Use an existing ServiceAccount name |
| deployment.podAnnotations | object | `{}` | Pod annotations |
| deployment.podLabels | object | `{}` | Pod labels |
| deployment.podSecurityContext | object | `{}` | Pod-level security context (e.g., fsGroup) |
| deployment.securityContext | object | `{}` | Container-level security context (e.g., runAsUser) |
| deployment.service | object | `{"port":80,"portName":"http","protocol":"TCP","targetPort":"http","type":"ClusterIP"}` | Service that front-ends the Deployment |
| deployment.service.portName | string | `"http"` | Service port name |
| deployment.service.type | string | `"ClusterIP"` | Service type: ClusterIP, NodePort, or LoadBalancer |
| deployment.service.port | int | `80` | Port exposed by the Service |
| deployment.service.targetPort | string | `"http"` | Target port on the pod |
| deployment.service.protocol | string | `"TCP"` | Protocol for the service port (TCP|UDP) |
| deployment.resources | object | `{"requests":{"cpu":"100m","memory":"64Mi"}}` | Resource requests & limits for pods |
| deployment.resources.requests.memory | string | `"64Mi"` | Memory request |
| deployment.resources.requests.cpu | string | `"100m"` | CPU request |
| deployment.livenessProbe | object | `{}` | Liveness probe configuration |
| deployment.readinessProbe | object | `{}` | Readiness probe configuration |
| deployment.autoscaling | object | `{"behavior":{"scaleDown":{},"scaleUp":{}},"enabled":false,"maxReplicas":10,"minReplicas":2,"targetCPUUtilizationPercentage":"","targetMemoryUtilizationPercentage":""}` | Horizontal Pod Autoscaling configuration |
| deployment.autoscaling.enabled | bool | `false` | Enable HPA (only when at least one target metric is set) |
| deployment.autoscaling.minReplicas | int | `2` | Minimum replicas for HPA |
| deployment.autoscaling.maxReplicas | int | `10` | Maximum replicas for HPA |
| deployment.autoscaling.targetCPUUtilizationPercentage | string | `""` | Target average CPU utilization (%) (optional) |
| deployment.autoscaling.targetMemoryUtilizationPercentage | string | `""` | Target average memory utilization (%) (optional) |
| deployment.autoscaling.behavior | object | `{"scaleDown":{},"scaleUp":{}}` | Optional HPA behavior settings |
| deployment.autoscaling.behavior.scaleUp | object | `{}` | scaleUp parameters passed through directly to HPA.behavior.scaleUp |
| deployment.autoscaling.behavior.scaleDown | object | `{}` | scaleDown parameters passed through directly to HPA.behavior.scaleDown |
| deployment.volumes | list | `[]` | Pod volumes: Secret, ConfigMap, PVC, etc. |
| deployment.volumeMounts | list | `[]` | Container volumeMounts for the above volumes |
| deployment.nodeSelector | object | `{}` | Node selector constraints for pod placement |
| deployment.tolerations | list | `[]` | Pod tolerations |
| deployment.affinity | object | `{}` | Pod affinity/anti-affinity rules |
| deployment.secret | object | `{}` | Global Secret key/value for envFrom injection |
| deployment.configMap | object | `{}` | Global ConfigMap key/value for envFrom injection |
| deployment.hostAliases | list | `[]` | hostAliases entries for pods |
| deployment.dnsConfig | object | `{"nameservers":[],"options":[],"searches":[]}` | DNS settings for pods |
| deployment.dnsConfig.nameservers | list | `[]` | Custom nameservers |
| deployment.dnsConfig.searches | list | `[]` | DNS search domains |
| deployment.dnsConfig.options | list | `[]` | DNS options (name/value) |
| deployment.envFromConfigMaps | list | `[]` | Import existing ConfigMaps as envFrom |
| deployment.envFromSecrets | list | `[]` | Import existing Secrets as envFrom |
| deployment.additionalEnvs | list | `[]` | Additional environment variables |
| deployment.extraInitContainers | list | `[]` | Extra initContainers |
| deployment.extraContainers | list | `[]` | Extra sidecar containers |
| deployment.podRecreation | object | `{"enabled":false}` | Recreate pods on config change (with pullPolicy=Always) |
| deployment.mountedConfigFiles | object | `{"bundles":[],"files":[]}` | Dynamic ConfigMaps to create from inline content or file bundles |
| deployment.mountedConfigFiles.files | list | `[]` | List of individual config files to create as ConfigMaps |
| deployment.mountedConfigFiles.bundles | list | `[]` | List of config file bundles (multiple files in one ConfigMap) |
| ingress | object | `{"annotations":{},"className":"nginx","enabled":false,"hosts":[{"host":"chart-example.local","paths":[{"path":"/","pathType":"ImplementationSpecific"}],"service":{"name":"","port":0}}],"tls":[]}` | Ingress configuration |
| ingress.enabled | bool | `false` | Enable or disable Ingress |
| ingress.className | string | `"nginx"` | IngressClass to use (e.g., nginx) |
| ingress.annotations | object | `{}` | Annotations to add to the Ingress |
| ingress.tls | list | `[]` | TLS configuration for secure hosts |
| ingress.hosts | list | `[{"host":"chart-example.local","paths":[{"path":"/","pathType":"ImplementationSpecific"}],"service":{"name":"","port":0}}]` | Definitions for each host rule |
| ingress.hosts[0].service | object | `{"name":"","port":0}` | Service backend name (default: chart fullname) |
| ingress.hosts[0].service.port | int | `0` | Service backend port (default: deployment.service.port) |
| ingress.hosts[0].paths | list | `[{"path":"/","pathType":"ImplementationSpecific"}]` | HTTP path definitions for this host |
| cronJobs | object | `{}` | CronJobs configuration (map of named cronJobs) |
| hooks | object | `{}` | Hook jobs for chart lifecycle (install/upgrade) |
| externalSecrets | object | `{}` | ExternalSecrets definitions for secret management |
| rbacs.roles | string | `nil` | Set serviceAccount.create to false to bind to an existing account without creating it. |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
