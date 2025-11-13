{{/*
Expand the name of the chart.
*/}}
{{- define "global-chart.name" -}}
{{- $suffix := default "" .deploymentNameSuffix -}}
{{- $base := default .Chart.Name .Values.deployment.nameOverride -}}
{{- printf "%s%s" $base $suffix | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "global-chart.fullname" -}}
{{- $suffix := default "" .deploymentNameSuffix -}}
{{- if .Values.deployment.fullnameOverride }}
{{- printf "%s%s" .Values.deployment.fullnameOverride $suffix | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.deployment.nameOverride }}
{{- if contains $name .Release.Name }}
{{- printf "%s%s" .Release.Name $suffix | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s%s" .Release.Name $name $suffix | trunc 63 | trimSuffix "-" }}
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
Common labels
*/}}
{{- define "global-chart.labels" -}}
helm.sh/chart: {{ include "global-chart.chart" . }}
{{ include "global-chart.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "global-chart.selectorLabels" -}}
app.kubernetes.io/name: {{ include "global-chart.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Hook-specific labels: do not include selectorLabels so hooks don't match Deployment/HPA selectors.
*/}}
{{- define "global-chart.hookLabels" -}}
helm.sh/chart: {{ include "global-chart.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: hook
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "global-chart.serviceAccountName" -}}
{{- if .Values.deployment.serviceAccount.create }}
{{- default (include "global-chart.fullname" .) .Values.deployment.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.deployment.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Ensure deployment suffixes are DNS-compatible, lowercase, and prefixed with '-'.
*/}}
{{- define "global-chart.sanitizeSuffix" -}}
{{- $suffix := printf "%v" (default "" .) -}}
{{- if not $suffix }}
{{- "" -}}
{{- else -}}
{{- $normalized := $suffix | lower | regexReplaceAll "[^a-z0-9-]+" "-" | regexReplaceAll "-+" "-" | trimAll "-" -}}
{{- if $normalized -}}
{{- printf "-%s" $normalized -}}
{{- else -}}
{{- "" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Iterate through the base deployment and any additional named deployments,
rendering the provided template for each merged context.
*/}}
{{- define "global-chart.renderForDeployments" -}}
{{- $root := .root -}}
{{- $template := .template -}}
{{- if not $root }}
  {{- fail "global-chart.renderForDeployments requires the root context" -}}
{{- end }}
{{- if not $template }}
  {{- fail "global-chart.renderForDeployments requires a template name" -}}
{{- end }}
{{- $contexts := list -}}
{{- $baseValues := deepCopy $root.Values -}}
{{- if not $baseValues }}
  {{- $baseValues = dict -}}
{{- end }}
{{- $baseDeployment := default (dict) (deepCopy $root.Values.deployment) -}}
{{- $_ := set $baseValues "deployment" $baseDeployment -}}
{{- $baseCtx := dict -}}
{{- $_ := set $baseCtx "Chart" $root.Chart -}}
{{- $_ = set $baseCtx "Release" $root.Release -}}
{{- $_ = set $baseCtx "Capabilities" $root.Capabilities -}}
{{- $_ = set $baseCtx "Files" $root.Files -}}
{{- $_ = set $baseCtx "Template" $root.Template -}}
{{- $_ = set $baseCtx "Subcharts" $root.Subcharts -}}
{{- if hasKey $root "Namespace" }}
  {{- $_ = set $baseCtx "Namespace" $root.Namespace -}}
{{- end }}
{{- $_ = set $baseCtx "Values" $baseValues -}}
{{- $_ = set $baseCtx "deploymentNameSuffix" "" -}}
{{- $contexts = append $contexts $baseCtx -}}
{{- $additional := default (dict) $root.Values.deployments -}}
{{- if $additional }}
  {{- $keys := sortAlpha (keys $additional) -}}
  {{- range $i, $name := $keys }}
    {{- $overrides := index $additional $name -}}
    {{- $merged := default (dict) (deepCopy $root.Values.deployment) -}}
    {{- if $overrides }}
      {{- $merged = mustMergeOverwrite $merged (deepCopy $overrides) -}}
    {{- end }}
    {{- $valuesCopy := deepCopy $root.Values -}}
    {{- if not $valuesCopy }}
      {{- $valuesCopy = dict -}}
    {{- end }}
    {{- $_ = set $valuesCopy "deployment" $merged -}}
    {{- $ctx := dict -}}
    {{- $_ = set $ctx "Chart" $root.Chart -}}
    {{- $_ = set $ctx "Release" $root.Release -}}
    {{- $_ = set $ctx "Capabilities" $root.Capabilities -}}
    {{- $_ = set $ctx "Files" $root.Files -}}
    {{- $_ = set $ctx "Template" $root.Template -}}
    {{- $_ = set $ctx "Subcharts" $root.Subcharts -}}
    {{- if hasKey $root "Namespace" }}
      {{- $_ = set $ctx "Namespace" $root.Namespace -}}
    {{- end }}
    {{- $_ = set $ctx "Values" $valuesCopy -}}
    {{- $_ = set $ctx "deploymentNameSuffix" (include "global-chart.sanitizeSuffix" $name) -}}
    {{- $contexts = append $contexts $ctx -}}
  {{- end }}
{{- end }}
{{- $manifests := list -}}
{{- range $context := $contexts }}
  {{- $content := trim (include $template $context) -}}
  {{- if $content }}
    {{- $manifests = append $manifests $content -}}
  {{- end }}
{{- end }}
{{- if gt (len $manifests) 0 }}
{{- join "\n---\n" $manifests -}}
{{- end }}
{{- end }}

{{- define "global-chart.hookfullname" -}}
{{- $fullname := (include "global-chart.fullname" .) }}
{{- printf "%s-%s-%s" $fullname .hookname .jobname | trunc 62 | trimSuffix "-" -}}
{{- end -}}

{{/*
Render an image reference from either a plain string or a map with repository/tag/digest.
*/}}
{{- define "global-chart.imageString" -}}
{{- $img := . -}}
{{- if kindIs "string" $img }}
  {{- $trimmed := $img | trim -}}
  {{- if $trimmed }}
    {{- $trimmed -}}
  {{- end }}
{{- else if and (kindIs "map" $img) $img.repository }}
  {{- $repo := $img.repository | trim -}}
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
  {{- $digest := $img.digest | trim -}}
  {{- if $digest }}
    {{- fail "image definitions that set a digest must also provide a repository (expected repository@digest)" -}}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Resolve an image pull policy from optional overrides, image map values, and a fallback.
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
{{- if $policy }}
  {{- $policy -}}
{{- else }}
  IfNotPresent
{{- end }}
{{- end }}
