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
Render the annotations of one resource: global.commonAnnotations merged with the
resource's own, the resource's own winning on a shared key.
Usage: {{- with (include "global-chart.renderAnnotations" (dict "root" $root "extra" $sa.annotations)) }}
Returns the "key: value" lines at indent 0, or empty string when both sides are
empty; the caller owns the "annotations:" key and its nindent.
The merge is the point, not a convenience: emitting the two sources as two
concatenated blocks puts a shared key in the manifest twice. Helm's parser is not
strict and takes the last one, so the precedence happens to come out right, but
kubeconform -strict rejects the manifest outright. Never concatenate.
*/}}
{{- define "global-chart.renderAnnotations" -}}
{{- $common := default (dict) (default (dict) .root.Values.global).commonAnnotations -}}
{{- with merge (deepCopy (default (dict) .extra)) $common -}}
{{- toYaml . -}}
{{- end -}}
{{- end }}

{{/*
Render the body of a ConfigMap "data:" block: one "key: value" line per entry, at
indent 0. The caller owns the "data:" key and applies its own nindent 2.
Usage: {{- include "global-chart.renderConfigMapData" $deploy.configMap | nindent 2 }}
Map/slice values are serialized with toYaml into a block scalar, everything else
stringified and quoted: ConfigMap.data is map[string]string, so every value has to
render as a YAML string or the API server rejects the manifest.
Returns empty string on an empty map; callers guard on the map being non-empty.
Built by joining lines rather than by literal text + whitespace control, unlike the
block helpers above: those own their block key and so start on literal text, while a
body-only helper written as a literal range emits a leading newline, which the
caller's nindent turns into a line of bare spaces.
*/}}
{{- define "global-chart.renderConfigMapData" -}}
{{- $lines := list -}}
{{- range $key, $value := . -}}
{{- if or (kindIs "map" $value) (kindIs "slice" $value) -}}
{{- $lines = append $lines (printf "%s: |-\n%s" $key (toYaml $value | indent 2)) -}}
{{- else -}}
{{- $lines = append $lines (printf "%s: %s" $key (toString $value | quote)) -}}
{{- end -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end }}

{{/*
Render the body of a Secret "data:" block: one "key: <base64>" line per entry, at
indent 0. The caller owns the "data:" key and applies its own nindent 2.
Usage: {{- include "global-chart.renderSecretData" $deploy.secret | nindent 2 }}
Strings are base64-encoded as-is, everything else through toYaml first.
Returns empty string on an empty map; callers guard on the map being non-empty.
*/}}
{{- define "global-chart.renderSecretData" -}}
{{- $lines := list -}}
{{- range $key, $value := . -}}
{{- if kindIs "string" $value -}}
{{- $lines = append $lines (printf "%s: %s" $key ($value | b64enc | quote)) -}}
{{- else -}}
{{- $lines = append $lines (printf "%s: %s" $key (toYaml $value | b64enc | quote)) -}}
{{- end -}}
{{- end -}}
{{- join "\n" $lines -}}
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

{{- /* Priority 1: Explicit service override.
       This 80 is deliberately NOT servicePrimaryPort's: ref.service is an
       arbitrary Service in the cluster, with only name/port — no portName, no
       targetPort. Its default merely coincides with the chart's primary port;
       sharing a home would couple a deployment's primary port to a foreign
       Service's. */ -}}
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
  {{- if ne (include "global-chart.deploymentEnabled" $deploy) "true" -}}
    {{- fail (printf "%s '%s' references deployment '%s' which has enabled: false (its Service will not be created)" $sourceKind $ident $depName) -}}
  {{- end -}}
  {{- $depSvc := default (dict) $deploy.service -}}
  {{- if ne (include "global-chart.serviceEnabled" $depSvc) "true" -}}
    {{- fail (printf "%s '%s' references deployment '%s' which has service.enabled: false. Enable the service or remove the %s." $sourceKindCapital $ident $depName $ruleNoun) -}}
  {{- end -}}
  {{- $svcName = include "global-chart.deploymentFullname" (dict "root" $root "deploymentName" $depName) -}}
  {{- $svcPort = (include "global-chart.servicePrimaryPort" $depSvc | fromJson).port -}}
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

Entries are deduplicated by name and by number+protocol. A numeric targetPort
reaches a pod port whether or not the container declares it, so re-declaring an
already-declared port would buy nothing and risk a duplicate name, which the API
server rejects. The protocol is part of the key because the same number under
two protocols is a distinct port — TCP and UDP on 53 is the ordinary DNS shape.
Usage: {{ include "global-chart.containerPorts" $svc | fromJsonArray }}
*/}}
{{- define "global-chart.containerPorts" -}}
{{- $svc := . -}}
{{- $primary := include "global-chart.servicePrimaryPort" $svc | fromJson -}}
{{- $portName := $primary.name -}}
{{- $targetPort := $primary.targetPort -}}
{{- $containerPort := kindIs "string" $targetPort | ternary $primary.port $targetPort -}}
{{- $protocol := $primary.protocol -}}
{{- $ports := list (dict "name" $portName "containerPort" $containerPort "protocol" $protocol) -}}
{{- $names := dict $portName true -}}
{{- $numbers := dict (printf "%s/%s" (toString $containerPort) $protocol) true -}}
{{- range (default (list) $svc.extraPorts) -}}
  {{- if not (kindIs "string" .targetPort) -}}
    {{- $extraProtocol := default "TCP" .protocol | upper -}}
    {{- $key := printf "%s/%s" (toString .targetPort) $extraProtocol -}}
    {{- if and (not (hasKey $names .name)) (not (hasKey $numbers $key)) -}}
      {{- $ports = append $ports (dict "name" .name "containerPort" .targetPort "protocol" $extraProtocol) -}}
      {{- $_ := set $names .name true -}}
      {{- $_ := set $numbers $key true -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $ports | toJson -}}
{{- end }}

{{/*
The primary port of a deployment's Service: the single home of its four
defaults (`port` 80, `name` "http", `protocol` TCP, `targetPort` following the
name). Consumed by service.yaml, containerPorts, validateServiceTargetPorts,
resolveBackend and the connection test — every place that used to carry its own
copy of one of them.

The default targetPort follows the port's name, not the literal "http": with a
custom portName and no targetPort, "http" would name a port nothing declares.

Only the primary port is here. extraPorts entries have name/port/targetPort all
required by the schema, so they share no default worth a home.
Usage: {{ $primary := include "global-chart.servicePrimaryPort" $svc | fromJson }}
Input: the deployment's service map, already defaulted to (dict) by the caller.
Output: JSON of the form {"port":80,"name":"http","protocol":"TCP","targetPort":"http"}
*/}}
{{- define "global-chart.servicePrimaryPort" -}}
{{- $svc := . -}}
{{- $name := ternary $svc.portName "http" (hasKey $svc "portName") -}}
{{- dict
      "port" (ternary $svc.port 80 (hasKey $svc "port"))
      "name" $name
      "protocol" (ternary $svc.protocol "TCP" (hasKey $svc "protocol") | upper)
      "targetPort" (ternary $svc.targetPort $name (hasKey $svc "targetPort"))
    | toJson -}}
{{- end }}
