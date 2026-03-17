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
Validate that all generated resource names are unique after truncation.
Checks within each resource kind: Deployments, CronJobs, Jobs (hooks),
ConfigMaps (including hook prerequisites), and Secrets (including hook prerequisites).
Called from validate.yaml.
*/}}
{{- define "global-chart.validateNameCollisions" -}}
{{- $root := . -}}
{{- $fullname := include "global-chart.fullname" $root -}}
{{- $deployNames := dict -}}
{{- $cronNames := dict -}}
{{- $hookNames := dict -}}
{{- $cmNames := dict -}}
{{- $secretNames := dict -}}

{{- /* 1. Deployment resource names (trunc 63) */ -}}
{{- range $name, $deploy := .Values.deployments -}}
  {{- if $deploy -}}
  {{- if eq (include "global-chart.deploymentEnabled" (dict "deploy" $deploy)) "true" -}}
    {{- $depFullname := include "global-chart.deploymentFullname" (dict "root" $root "deploymentName" $name) -}}
    {{- if hasKey $deployNames $depFullname -}}
      {{- fail (printf "Name collision: Deployment '%s' generated by deployment '%s' conflicts with %s" $depFullname $name (index $deployNames $depFullname)) -}}
    {{- end -}}
    {{- $_ := set $deployNames $depFullname (printf "deployment '%s'" $name) -}}

    {{- /* 1a. Deployment-level CronJob names (trunc 52) — matches cronjob.yaml naming */ -}}
    {{- range $jobName, $job := $deploy.cronJobs -}}
      {{- if $job -}}
        {{- $jobFullname := printf "%s-%s-%s" $fullname $name $jobName | trunc 52 | trimSuffix "-" -}}
        {{- if hasKey $cronNames $jobFullname -}}
          {{- fail (printf "Name collision: CronJob '%s' generated by cronJob '%s' in deployment '%s' conflicts with %s" $jobFullname $jobName $name (index $cronNames $jobFullname)) -}}
        {{- end -}}
        {{- $_ := set $cronNames $jobFullname (printf "cronJob '%s' in deployment '%s'" $jobName $name) -}}
      {{- end -}}
    {{- end -}}

    {{- /* 1b. Deployment-level Hook names (trunc 63) + prerequisite ConfigMap/Secret */ -}}
    {{- if $deploy.hooks -}}
      {{- /* Hook prerequisite ConfigMap (trunc 63) */ -}}
      {{- $hasDeployConfigMap := and $deploy.configMap (gt (len $deploy.configMap) 0) -}}
      {{- if $hasDeployConfigMap -}}
        {{- $hookConfigName := printf "%s-hook-config" $depFullname | trunc 63 | trimSuffix "-" -}}
        {{- if hasKey $cmNames $hookConfigName -}}
          {{- fail (printf "Name collision: ConfigMap '%s' generated by hook prerequisite for deployment '%s' conflicts with %s" $hookConfigName $name (index $cmNames $hookConfigName)) -}}
        {{- end -}}
        {{- $_ := set $cmNames $hookConfigName (printf "hook prerequisite ConfigMap for deployment '%s'" $name) -}}
      {{- end -}}

      {{- /* Hook prerequisite Secret (trunc 63) */ -}}
      {{- $hasDeploySecret := and $deploy.secret (gt (len $deploy.secret) 0) -}}
      {{- if $hasDeploySecret -}}
        {{- $hookSecretName := printf "%s-hook-secret" $depFullname | trunc 63 | trimSuffix "-" -}}
        {{- if hasKey $secretNames $hookSecretName -}}
          {{- fail (printf "Name collision: Secret '%s' generated by hook prerequisite for deployment '%s' conflicts with %s" $hookSecretName $name (index $secretNames $hookSecretName)) -}}
        {{- end -}}
        {{- $_ := set $secretNames $hookSecretName (printf "hook prerequisite Secret for deployment '%s'" $name) -}}
      {{- end -}}

      {{- range $hookType, $jobs := $deploy.hooks -}}
        {{- range $jobName, $command := $jobs -}}
          {{- if $command -}}
            {{- $hookFullname := printf "%s-%s-%s" $depFullname $hookType $jobName | trunc 63 | trimSuffix "-" -}}
            {{- if hasKey $hookNames $hookFullname -}}
              {{- fail (printf "Name collision: Job '%s' generated by hook '%s/%s' in deployment '%s' conflicts with %s" $hookFullname $hookType $jobName $name (index $hookNames $hookFullname)) -}}
            {{- end -}}
            {{- $_ := set $hookNames $hookFullname (printf "hook '%s/%s' in deployment '%s'" $hookType $jobName $name) -}}
          {{- end -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}

  {{- end -}}
  {{- end -}}
{{- end -}}

{{- /* 2. Root-level CronJob names (trunc 52) */ -}}
{{- range $name, $job := .Values.cronJobs -}}
  {{- if $job -}}
    {{- $jobFullname := printf "%s-%s" $fullname $name | trunc 52 | trimSuffix "-" -}}
    {{- if hasKey $cronNames $jobFullname -}}
      {{- fail (printf "Name collision: CronJob '%s' generated by root cronJob '%s' conflicts with %s" $jobFullname $name (index $cronNames $jobFullname)) -}}
    {{- end -}}
    {{- $_ := set $cronNames $jobFullname (printf "root cronJob '%s'" $name) -}}
  {{- end -}}
{{- end -}}

{{- /* 3. Root-level Hook names (trunc 63) */ -}}
{{- range $hookType, $jobs := .Values.hooks -}}
  {{- range $name, $command := $jobs -}}
    {{- if $command -}}
      {{- $hookFullname := include "global-chart.hookfullname" (merge (dict "hookname" $hookType "jobname" $name) $root) -}}
      {{- if hasKey $hookNames $hookFullname -}}
        {{- fail (printf "Name collision: Job '%s' generated by root hook '%s/%s' conflicts with %s" $hookFullname $hookType $name (index $hookNames $hookFullname)) -}}
      {{- end -}}
      {{- $_ := set $hookNames $hookFullname (printf "root hook '%s/%s'" $hookType $name) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{- end }}
