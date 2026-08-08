{{/*
Rendering helpers for global-chart.
*/}}

{{/*
Render a single volume entry. Supports both:
- Legacy format: { name, type, secret/configMap/persistentVolumeClaim/emptyDir }
- Native format: { name, <any-k8s-volume-source> } (no .type field)
*/}}
{{- define "global-chart.renderVolume" -}}
{{- $vol := . -}}
- name: {{ required "renderVolume: every volume entry must have a 'name' field" $vol.name }}
{{- if hasKey $vol "type" }}
  {{- /* Legacy format: translate .type to native */ -}}
  {{- if eq $vol.type "emptyDir" }}
  emptyDir: {}
  {{- else if eq $vol.type "configMap" }}
  configMap:
    name: {{ $vol.configMap.name | quote }}
  {{- else if eq $vol.type "secret" }}
  secret:
    secretName: {{ default $vol.secret.name $vol.secret.secretName | quote }}
  {{- else if eq $vol.type "persistentVolumeClaim" }}
  persistentVolumeClaim:
    claimName: {{ default $vol.persistentVolumeClaim.name $vol.persistentVolumeClaim.claimName | quote }}
  {{- else }}
  {{- fail (printf "renderVolume: unknown legacy volume type '%s' for volume '%s'. Supported types: emptyDir, configMap, secret, persistentVolumeClaim. For other volume types, use native Kubernetes volume spec (omit .type)." $vol.type $vol.name) }}
  {{- end }}
{{- else }}
  {{- /* Native format: render everything except name deterministically */ -}}
  {{- $native := omit $vol "name" -}}
  {{- toYaml $native | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Render imagePullSecrets block. Accepts a list of strings or objects with "name" key.
Usage: {{ include "global-chart.renderImagePullSecrets" $listOrNil }}
Returns empty string if list is nil/empty.
*/}}
{{- define "global-chart.renderImagePullSecrets" -}}
{{- with . -}}
imagePullSecrets:
  {{- range . }}
    {{- if kindIs "string" . }}
  - name: {{ . | quote }}
    {{- else if hasKey . "name" }}
  - name: {{ .name | quote }}
    {{- else }}
  {{ fail "imagePullSecrets must be a list of strings or objects with a 'name' key." }}
    {{- end }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Render dnsConfig block from a dnsConfig dict.
Usage: {{ include "global-chart.renderDnsConfig" $dnsConfigDict }}
Returns empty string if no nameservers/searches/options are set.
*/}}
{{- define "global-chart.renderDnsConfig" -}}
{{- $dnsConfig := default (dict) . -}}
{{- if or $dnsConfig.nameservers $dnsConfig.searches $dnsConfig.options -}}
dnsConfig:
  {{- if $dnsConfig.nameservers }}
  nameservers:
    {{- range $dnsConfig.nameservers }}
    - {{ . | quote }}
    {{- end }}
  {{- end }}
  {{- if $dnsConfig.searches }}
  searches:
    {{- range $dnsConfig.searches }}
    - {{ . | quote }}
    {{- end }}
  {{- end }}
  {{- if $dnsConfig.options }}
  options:
    {{- range $dnsConfig.options }}
    - name: {{ .name }}
      {{- if .value }}
      value: {{ .value | quote }}
      {{- end }}
    {{- end }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Render resources block with defaults fallback.
Usage: {{ include "global-chart.renderResources" (dict "resources" $job.resources "hasResources" (hasKey $job "resources") "defaults" $root.Values.defaults) }}
When hasResources is true and resources is empty ({}), no resources block is rendered (explicit override to clear defaults).
When hasResources is false (key absent), defaults.resources is used as fallback.
*/}}
{{- define "global-chart.renderResources" -}}
{{- if .resources -}}
resources:
  {{- toYaml .resources | nindent 2 }}
{{- else if not (default false .hasResources) }}
{{- $defaultRes := default (dict) (default (dict) .defaults).resources -}}
{{- with $defaultRes -}}
resources:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Render global.commonAnnotations block.
Usage: {{ include "global-chart.renderCommonAnnotations" . }}
Accepts root context (.). Returns toYaml of global.commonAnnotations, or empty string if not set.
*/}}
{{- define "global-chart.renderCommonAnnotations" -}}
{{- $global := default (dict) .Values.global -}}
{{- with $global.commonAnnotations -}}
{{- toYaml . -}}
{{- end -}}
{{- end }}

{{/*
Resolve a backend reference to a {name, port} dict, emitted as JSON for the caller to parse via fromJson.
Usage:
  {{- $b := include "global-chart.resolveBackend" (dict "root" $root "ref" $hostEntry "sourceKind" "ingress host") | fromJson -}}
  {{- $svcName := $b.name -}}
  {{- $svcPort := $b.port -}}

Inputs (dict):
  - root        (required) — Helm root context (the chart "." passed in)
  - ref         (required) — host entry (ingress) or backendRef (httpRoute) map; supports .service.name/.port and .deployment
  - sourceKind  (required) — caller-supplied noun phrase used to prefix fail messages
                             (e.g. "ingress host", "httpRoute rule"). Capitalize per existing wording —
                             this string flows verbatim into "%s '%s' references deployment ..." messages.
  - identifier  (optional) — human-readable identifier for fail messages.
                             Falls back to ref.host (ingress entries have one), else "<unknown>".
  - ruleNoun    (optional) — noun used in the "remove the X" suffix of the service.enabled:false message.
                             Defaults to "rule". Ingress passes "ingress rule" to preserve historical wording.

Resolution priority (mirrors the historical inline ingress logic):
  1. Explicit service override: ref.service.name set      → {name=ref.service.name, port=ref.service.port|80}
  2. Deployment reference:      ref.deployment set        → {name=deploymentFullname, port=deploy.service.port|80}
                                with validations: deployment exists, enabled, service.enabled != false
  3. Otherwise: fail with actionable message.

Output: JSON string of the form {"name":"<svc>","port":<int>}
*/}}
{{- define "global-chart.resolveBackend" -}}
{{- $root := .root -}}
{{- $ref := .ref -}}
{{- $sourceKind := .sourceKind -}}
{{- /* sourceKindCapital: same noun phrase with its first word capitalized.
       Used only in the "service.enabled: false" message to preserve the
       historical "Ingress host '...'" sentence-start wording. Defaults to
       $sourceKind if not provided. */ -}}
{{- $sourceKindCapital := default $sourceKind .sourceKindCapital -}}
{{- /* ruleNoun: noun used in the "remove the X" suffix. Defaults to "rule".
       Ingress passes "ingress rule" to preserve historical wording. */ -}}
{{- $ruleNoun := default "rule" .ruleNoun -}}
{{- /* Identifier: prefer explicit .identifier, else ref.host (ingress), else "<unknown>" */ -}}
{{- $ident := "<unknown>" -}}
{{- if .identifier -}}{{- $ident = .identifier -}}
{{- else if and (kindIs "map" $ref) (hasKey $ref "host") $ref.host -}}{{- $ident = $ref.host -}}
{{- end -}}
{{- $svcName := "" -}}
{{- $svcPort := 80 -}}

{{- /* Priority 1: Explicit service override */ -}}
{{- if and (hasKey $ref "service") $ref.service $ref.service.name -}}
  {{- $svcName = $ref.service.name -}}
  {{- $svcPort = ternary $ref.service.port 80 (hasKey $ref.service "port") -}}
{{- /* Priority 2: Deployment reference */ -}}
{{- else if $ref.deployment -}}
  {{- $depName := $ref.deployment -}}
  {{- $deploy := index $root.Values.deployments $depName -}}
  {{- if not $deploy -}}
    {{- fail (printf "%s '%s' references deployment '%s' which does not exist in .Values.deployments" $sourceKind $ident $depName) -}}
  {{- end -}}
  {{- if ne (include "global-chart.deploymentEnabled" (dict "deploy" $deploy)) "true" -}}
    {{- fail (printf "%s '%s' references deployment '%s' which has enabled: false (its Service will not be created)" $sourceKind $ident $depName) -}}
  {{- end -}}
  {{- $depSvc := default (dict) $deploy.service -}}
  {{- if and (hasKey $depSvc "enabled") (not $depSvc.enabled) -}}
    {{- fail (printf "%s '%s' references deployment '%s' which has service.enabled: false. Enable the service or remove the %s." $sourceKindCapital $ident $depName $ruleNoun) -}}
  {{- end -}}
  {{- $svcName = include "global-chart.deploymentFullname" (dict "root" $root "deploymentName" $depName) -}}
  {{- $svcPort = ternary $depSvc.port 80 (hasKey $depSvc "port") -}}
{{- /* Priority 3: Error - must specify deployment or service */ -}}
{{- else -}}
  {{- fail (printf "%s '%s' must specify either 'deployment' (name of a deployment) or 'service.name' (explicit service name)" $sourceKind $ident) -}}
{{- end -}}

{{- dict "name" $svcName "port" $svcPort | toJson -}}
{{- end }}

{{/*
Render an ExternalSecret remoteRef block, shared by both the data-list and
single-key branches of externalsecret.yaml so their defaults can never drift.
`property` and `version` carry no chart-side default — ESO defaults them at the
CRD level — so they are emitted only when the key is present, keyed on `hasKey`
rather than truthiness: an explicit empty string is the user's input and is
passed through, not silently dropped. `version` goes through `quote` because the
schema accepts a number for it (`version: 3`) while the CRD wants a string.
Usage: {{- include "global-chart.renderExternalSecretRemoteRef" (dict "remote" $remote "keyError" (printf "externalSecrets.%s.remote.key is mandatory" $name)) | nindent 8 }}
Inputs (dict):
  - remote    (required) — the remote map (key + optional conversion/decoding/metadata strategies, property, version)
  - keyError  (required) — fail message when remote.key is missing (caller supplies the exact path)
*/}}
{{- define "global-chart.renderExternalSecretRemoteRef" -}}
{{- $remote := .remote -}}
conversionStrategy: {{ ternary $remote.conversionStrategy "Default" (hasKey $remote "conversionStrategy") | quote }}
decodingStrategy: {{ ternary $remote.decodingStrategy "None" (hasKey $remote "decodingStrategy") | quote }}
key: {{ required .keyError $remote.key | quote }}
metadataPolicy: {{ ternary $remote.metadataPolicy "None" (hasKey $remote "metadataPolicy") | quote }}
{{- if hasKey $remote "property" }}
property: {{ $remote.property | quote }}
{{- end }}
{{- if hasKey $remote "version" }}
version: {{ $remote.version | quote }}
{{- end }}
{{- end }}

{{/*
Container ports for a deployment's pod spec, derived from its Service definition.
Single source of truth for the pod side of the Service: deployment.yaml renders
this list, and validateServiceTargetPorts checks named targetPorts against it,
so the two can never drift — that drift is what made service.targetPort unusable
(issue #82).

The Service's targetPort decides the pod's port: a number IS the port, a name has
to resolve to one of these entries. Every numeric targetPort under extraPorts is
therefore declared here as well, named after its Service port, so that a named
targetPort has something to bind to.

Entries are deduplicated by name and by number. A numeric targetPort reaches a
pod port whether or not the container declares it, so a second declaration of an
already-declared port would buy nothing and risk a duplicate name, which the API
server rejects.
Usage: {{ include "global-chart.containerPorts" $svc | fromJsonArray }}
*/}}
{{- define "global-chart.containerPorts" -}}
{{- $svc := . -}}
{{- $portName := ternary $svc.portName "http" (hasKey $svc "portName") -}}
{{- $port := ternary $svc.port 80 (hasKey $svc "port") -}}
{{- /* The default targetPort follows portName, not the literal "http": with a custom
       portName and no targetPort, "http" would name a port nothing declares. */ -}}
{{- $targetPort := ternary $svc.targetPort $portName (hasKey $svc "targetPort") -}}
{{- $containerPort := kindIs "string" $targetPort | ternary $port $targetPort -}}
{{- $protocol := ternary $svc.protocol "TCP" (hasKey $svc "protocol") | upper -}}
{{- $ports := list (dict "name" $portName "containerPort" $containerPort "protocol" $protocol) -}}
{{- $names := dict $portName true -}}
{{- $numbers := dict (toString $containerPort) true -}}
{{- range (default (list) $svc.extraPorts) -}}
  {{- if not (kindIs "string" .targetPort) -}}
    {{- if and (not (hasKey $names .name)) (not (hasKey $numbers (toString .targetPort))) -}}
      {{- $ports = append $ports (dict "name" .name "containerPort" .targetPort "protocol" (default "TCP" .protocol | upper)) -}}
      {{- $_ := set $names .name true -}}
      {{- $_ := set $numbers (toString .targetPort) true -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $ports | toJson -}}
{{- end }}

{{/*
The effective targetPort of a Service's primary port: explicit when set,
otherwise the port's own name. Shared by service.yaml and the validator so the
default cannot drift from the name deployment.yaml gives the container port.
Usage: {{ include "global-chart.serviceTargetPort" $svc }}
*/}}
{{- define "global-chart.serviceTargetPort" -}}
{{- $svc := . -}}
{{- ternary $svc.targetPort (ternary $svc.portName "http" (hasKey $svc "portName")) (hasKey $svc "targetPort") -}}
{{- end }}
