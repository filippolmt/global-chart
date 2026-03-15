{{/*
Expand the name of the chart.
*/}}
{{- define "global-chart.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "global-chart.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "global-chart.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels (for non-deployment resources like Ingress)
*/}}
{{- define "global-chart.labels" -}}
helm.sh/chart: {{ include "global-chart.chart" . }}
{{ include "global-chart.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels (base, without component)
*/}}
{{- define "global-chart.selectorLabels" -}}
app.kubernetes.io/name: {{ include "global-chart.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create a deployment-specific fully qualified name.
Usage: {{ include "global-chart.deploymentFullname" (dict "root" . "deploymentName" $name) }}
*/}}
{{- define "global-chart.deploymentFullname" -}}
{{- $root := .root -}}
{{- $name := .deploymentName -}}
{{- $baseName := include "global-chart.fullname" $root -}}
{{- printf "%s-%s" $baseName $name | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/*
Selector labels for a specific deployment (includes deployment name for uniqueness).
Usage: {{ include "global-chart.deploymentSelectorLabels" (dict "root" . "deploymentName" $name) }}
*/}}
{{- define "global-chart.deploymentSelectorLabels" -}}
app.kubernetes.io/name: {{ include "global-chart.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .deploymentName }}
{{- end }}

{{/*
Common labels for a specific deployment.
Usage: {{ include "global-chart.deploymentLabels" (dict "root" . "deploymentName" $name) }}
*/}}
{{- define "global-chart.deploymentLabels" -}}
helm.sh/chart: {{ include "global-chart.chart" .root }}
{{ include "global-chart.deploymentSelectorLabels" . }}
app.kubernetes.io/version: {{ .root.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- end }}

{{/*
Check if a deployment is enabled. Defaults to true if the field is not set.
Usage: {{ include "global-chart.deploymentEnabled" (dict "deploy" $deploy) }}
Returns the string "true" or "false".
*/}}
{{- define "global-chart.deploymentEnabled" -}}
{{- ternary .deploy.enabled true (hasKey .deploy "enabled") -}}
{{- end }}

{{/*
Create the name of the service account for a specific deployment.
Usage: {{ include "global-chart.deploymentServiceAccountName" (dict "root" . "deploymentName" $name "deployment" $deploy) }}
*/}}
{{- define "global-chart.deploymentServiceAccountName" -}}
{{- $root := .root -}}
{{- $name := .deploymentName -}}
{{- $deploy := .deployment -}}
{{- $sa := default (dict) $deploy.serviceAccount -}}
{{- $create := ternary $sa.create true (hasKey $sa "create") -}}{{/* Default to create=true unless explicitly set to false */}}
{{- if $create -}}
{{- default (include "global-chart.deploymentFullname" (dict "root" $root "deploymentName" $name)) $sa.name -}}
{{- else -}}
{{- default "default" $sa.name -}}
{{- end -}}
{{- end }}

{{/*
Hook-specific labels: do not include selectorLabels so hooks don't match Deployment/HPA selectors.
Base labels without component (used when component is added separately).
*/}}
{{- define "global-chart.hookLabels" -}}
helm.sh/chart: {{ include "global-chart.chart" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Hook labels with component for root-level hooks.
*/}}
{{- define "global-chart.hookLabelsWithComponent" -}}
{{ include "global-chart.hookLabels" . }}
app.kubernetes.io/component: hook
{{- end }}

{{- define "global-chart.hookfullname" -}}
{{- $fullname := (include "global-chart.fullname" .) }}
{{- printf "%s-%s-%s" $fullname .hookname .jobname | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Render an image reference from either a plain string or a map with repository/tag/digest.
Supports two calling conventions:
  Legacy: {{ include "global-chart.imageString" $deploy.image }}
  New:    {{ include "global-chart.imageString" (dict "image" $deploy.image "global" $root.Values.global) }}
When global.imageRegistry is set, the registry is prepended to both string and map images
unless the first path segment already looks like a registry (contains "." or ":" or equals "localhost").
Examples: "nginx" → "registry/nginx", "myorg/myapp" → "registry/myorg/myapp", "ghcr.io/org/app" → unchanged.
*/}}
{{- define "global-chart.imageString" -}}
{{- $img := . -}}
{{- $globalRegistry := "" -}}
{{- if and (kindIs "map" .) (hasKey . "image") -}}
  {{- /* New dict format */ -}}
  {{- $img = .image -}}
  {{- $global := default (dict) .global -}}
  {{- $globalRegistry = default "" $global.imageRegistry -}}
{{- end -}}
{{- if kindIs "string" $img }}
  {{- $trimmed := $img | trim -}}
  {{- if $trimmed }}
    {{- $needsRegistry := true -}}
    {{- if contains "/" $trimmed -}}
      {{- $firstSegment := index (splitList "/" $trimmed) 0 -}}
      {{- if or (contains "." $firstSegment) (contains ":" $firstSegment) (eq $firstSegment "localhost") -}}
        {{- $needsRegistry = false -}}
      {{- end -}}
    {{- end -}}
    {{- if and $globalRegistry $needsRegistry }}
      {{- printf "%s/%s" $globalRegistry $trimmed -}}
    {{- else }}
      {{- $trimmed -}}
    {{- end }}
  {{- end }}
{{- else if and (kindIs "map" $img) $img.repository }}
  {{- $repo := $img.repository | trim -}}
  {{- $needsRegistry := true -}}
  {{- if contains "/" $repo -}}
    {{- $firstSegment := index (splitList "/" $repo) 0 -}}
    {{- if or (contains "." $firstSegment) (contains ":" $firstSegment) (eq $firstSegment "localhost") -}}
      {{- $needsRegistry = false -}}
    {{- end -}}
  {{- end -}}
  {{- if and $globalRegistry $needsRegistry }}
    {{- $repo = printf "%s/%s" $globalRegistry $repo -}}
  {{- end -}}
  {{- $digest := default "" $img.digest | trim -}}
  {{- $tag := default "" $img.tag | trim -}}
  {{- if $repo }}
    {{- if $digest }}
      {{- printf "%s@%s" $repo $digest -}}
    {{- else if $tag }}
      {{- printf "%s:%s" $repo $tag -}}
    {{- else }}
      {{- $repo -}}
    {{- end }}
  {{- end }}
{{- else if and (kindIs "map" $img) $img.digest }}
  {{- fail "image definitions that set a digest must also provide a repository (expected repository@digest)" -}}
{{- end }}
{{- end }}

{{/*
Render a single volume entry. Supports both:
- Legacy format: { name, type, secret/configMap/persistentVolumeClaim/emptyDir }
- Native format: { name, <any-k8s-volume-source> } (no .type field)
*/}}
{{- define "global-chart.renderVolume" -}}
{{- $vol := . -}}
- name: {{ $vol.name }}
{{- if hasKey $vol "type" }}
  {{- /* Legacy format: translate .type to native */ -}}
  {{- if eq $vol.type "emptyDir" }}
  emptyDir: {}
  {{- else if eq $vol.type "configMap" }}
  configMap:
    name: {{ $vol.configMap.name | quote }}
  {{- else if eq $vol.type "secret" }}
  secret:
    secretName: {{ default $vol.secret.secretName $vol.secret.name | quote }}
  {{- else if eq $vol.type "persistentVolumeClaim" }}
  persistentVolumeClaim:
    claimName: {{ default $vol.persistentVolumeClaim.claimName $vol.persistentVolumeClaim.name | quote }}
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
Resolve an image pull policy from optional overrides, image map values, and a fallback.
Priority: override > image.pullPolicy > fallback > IfNotPresent (default).
*/}}
{{- define "global-chart.imagePullPolicy" -}}
{{- $ctx := . -}}
{{- $policy := "" -}}
{{- if and (hasKey $ctx "override") (ne $ctx.override nil) }}
  {{- $policy = printf "%v" $ctx.override | trim -}}
{{- end }}
{{- if not $policy }}
  {{- if and (hasKey $ctx "image") (kindIs "map" $ctx.image) (hasKey $ctx.image "pullPolicy") (ne $ctx.image.pullPolicy nil) }}
    {{- $policy = printf "%v" $ctx.image.pullPolicy | trim -}}
  {{- end }}
{{- end }}
{{- if not $policy }}
  {{- if and (hasKey $ctx "fallback") (ne $ctx.fallback nil) }}
    {{- $policy = printf "%v" $ctx.fallback | trim -}}
  {{- end }}
{{- end }}
{{- if $policy -}}
{{- $policy -}}
{{- else -}}
IfNotPresent
{{- end -}}
{{- end }}

{{/*
Shared pod spec for deployment-level hooks and cronjobs.
Renders the pod-level fields (imagePullSecrets through tolerations) and the container spec.
This eliminates duplicated inheritance logic between hook.yaml and cronjob.yaml.

Parameters (passed as a dict):
  root             - Root context ($)
  deployName       - Deployment key name
  deploy           - Deployment values map
  jobName          - Job/cronjob name
  job              - Job values map (the hook command or cronjob)
  jobFullname      - Pre-computed full name of the job
  deployFullname   - Pre-computed deployment fullname
  hasDeployConfigMap - bool: whether deployment has a configMap
  hasDeploySecret    - bool: whether deployment has a secret
  includeDnsConfig   - bool: true for cronjobs (inherit from deploy), false for hooks
  saName           - Pre-resolved service account name
  includeInitContainers - bool: true for cronjobs, false for hooks

Returns: Rendered YAML string (pod-level fields + container), to be embedded via `include` + `nindent`.
Scope: Deployment-level only; root-level hooks/cronjobs do NOT use this helper.
*/}}
{{- define "global-chart.inheritedJobPodSpec" -}}
{{- $root := .root -}}
{{- $deploy := .deploy -}}
{{- $deployName := .deployName -}}
{{- $job := .job -}}
{{- $jobName := .jobName -}}
{{- $jobFullname := .jobFullname -}}
{{- $deployFullname := .deployFullname -}}
{{- $hasDeployConfigMap := .hasDeployConfigMap -}}
{{- $hasDeploySecret := .hasDeploySecret -}}
{{- $includeDnsConfig := .includeDnsConfig -}}
{{- $saName := .saName -}}
{{- $includeInitContainers := default false .includeInitContainers -}}
{{- /* ImagePullSecrets: explicit > inherited from deployment > global (hasKey distinguishes unset from empty) */ -}}
{{- $imagePullSecrets := list -}}
{{- if hasKey $job "imagePullSecrets" -}}
  {{- $imagePullSecrets = $job.imagePullSecrets -}}
{{- else if hasKey $deploy "imagePullSecrets" -}}
  {{- $imagePullSecrets = $deploy.imagePullSecrets -}}
{{- else -}}
  {{- $global := default (dict) $root.Values.global -}}
  {{- $imagePullSecrets = $global.imagePullSecrets -}}
{{- end -}}
{{- $renderedIPS := include "global-chart.renderImagePullSecrets" $imagePullSecrets -}}
{{- /* HostAliases: explicit > inherited from deployment */ -}}
{{- $hostAliases := ternary $job.hostAliases $deploy.hostAliases (hasKey $job "hostAliases") -}}
{{- /* PodSecurityContext: explicit > inherited from deployment */ -}}
{{- $podSecCtx := ternary $job.podSecurityContext $deploy.podSecurityContext (hasKey $job "podSecurityContext") -}}
{{- /* DnsConfig: explicit > inherited from deployment (cronjobs only) */ -}}
{{- $renderedDns := "" -}}
{{- if $includeDnsConfig -}}
{{- $dnsConfig := dict -}}
{{- if hasKey $job "dnsConfig" -}}
  {{- $dnsConfig = default (dict) $job.dnsConfig -}}
{{- else -}}
  {{- $dnsConfig = default (dict) $deploy.dnsConfig -}}
{{- end -}}
{{- $renderedDns = include "global-chart.renderDnsConfig" $dnsConfig -}}
{{- end -}}
{{- with $renderedIPS }}
{{ . }}
{{- end }}
{{- with $hostAliases }}
hostAliases:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $podSecCtx }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $renderedDns }}
{{ . }}
{{- end }}
{{- if and $includeInitContainers $job.initContainers }}
initContainers:
  {{- toYaml $job.initContainers | nindent 2 }}
{{- end }}
containers:
- name: {{ $jobName }}
  image: {{ .imageRef | quote }}
  imagePullPolicy: {{ include "global-chart.imagePullPolicy" (dict "override" $job.imagePullPolicy "image" (default $deploy.image $job.image)) | quote }}
  {{- if $job.command }}
  command:
    {{- toYaml $job.command | nindent 4 }}
  {{- end }}
  {{- if $job.args }}
  args:
    {{- toYaml $job.args | nindent 4 }}
  {{- end }}
  {{- /* Container securityContext: explicit > inherited from deployment */ -}}
  {{- $secCtx := ternary $job.securityContext $deploy.securityContext (hasKey $job "securityContext") -}}
  {{- with $secCtx }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with (include "global-chart.renderResources" (dict "resources" $job.resources "hasResources" (hasKey $job "resources") "defaults" $root.Values.defaults)) }}
{{ . | indent 2 }}
  {{- end }}
  {{- /* EnvFrom: deployment's configMap/secret + deployment's external refs + job's external refs */ -}}
  {{- $hasEnvFrom := or $hasDeployConfigMap $hasDeploySecret $job.envFromConfigMaps $job.envFromSecrets $deploy.envFromConfigMaps $deploy.envFromSecrets -}}
  {{- if $hasEnvFrom }}
  envFrom:
    {{- /* Deployment's generated ConfigMap */ -}}
    {{- if $hasDeployConfigMap }}
    - configMapRef:
        name: {{ $deployFullname | quote }}
    {{- end }}
    {{- /* Deployment's generated Secret */ -}}
    {{- if $hasDeploySecret }}
    - secretRef:
        name: {{ $deployFullname | quote }}
    {{- end }}
    {{- /* Deployment's external ConfigMaps */ -}}
    {{- range $cm := $deploy.envFromConfigMaps }}
    - configMapRef:
        name: {{ $cm | quote }}
    {{- end }}
    {{- /* Deployment's external Secrets */ -}}
    {{- range $sec := $deploy.envFromSecrets }}
    - secretRef:
        name: {{ $sec | quote }}
    {{- end }}
    {{- /* Job's explicit external ConfigMaps */ -}}
    {{- range $cm := $job.envFromConfigMaps }}
    - configMapRef:
        name: {{ $cm | quote }}
    {{- end }}
    {{- /* Job's explicit external Secrets */ -}}
    {{- range $sec := $job.envFromSecrets }}
    - secretRef:
        name: {{ $sec | quote }}
    {{- end }}
  {{- end }}
  {{- /* Env: deployment's additionalEnvs + job's env */ -}}
  {{- $envVars := list -}}
  {{- if $deploy.additionalEnvs -}}
    {{- $envVars = $deploy.additionalEnvs -}}
  {{- end -}}
  {{- if $job.env -}}
    {{- $envVars = concat $envVars $job.env -}}
  {{- end -}}
  {{- if $envVars }}
  env:
    {{- toYaml $envVars | nindent 4 }}
  {{- end }}
  {{- with $job.volumeMounts }}
  volumeMounts:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- with $job.volumes }}
volumes:
  {{- range . }}
  {{- include "global-chart.renderVolume" . | nindent 2 }}
  {{- end }}
{{- end }}
serviceAccountName: {{ $saName | quote }}
{{- /* NodeSelector: explicit > inherited from deployment */ -}}
{{- $nodeSelector := ternary $job.nodeSelector $deploy.nodeSelector (hasKey $job "nodeSelector") -}}
{{- with $nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- /* Affinity: explicit > inherited from deployment */ -}}
{{- $affinity := ternary $job.affinity $deploy.affinity (hasKey $job "affinity") -}}
{{- with $affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- /* Tolerations: explicit > inherited from deployment */ -}}
{{- $tolerations := ternary $job.tolerations $deploy.tolerations (hasKey $job "tolerations") -}}
{{- with $tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
restartPolicy: {{ default "Never" $job.restartPolicy | quote }}
{{- end }}
