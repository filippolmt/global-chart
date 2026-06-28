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
{{- with .Chart.AppVersion }}
app.kubernetes.io/version: {{ . | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- $global := default (dict) .Values.global }}
{{- with $global.commonLabels }}
{{ toYaml . | trimSuffix "\n" }}
{{- end }}
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
{{- with .root.Chart.AppVersion }}
app.kubernetes.io/version: {{ . | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- $global := default (dict) .root.Values.global }}
{{- with $global.commonLabels }}
{{ toYaml . | trimSuffix "\n" }}
{{- end }}
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
{{- with .Chart.AppVersion }}
app.kubernetes.io/version: {{ . | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- $global := default (dict) .Values.global }}
{{- with $global.commonLabels }}
{{ toYaml . | trimSuffix "\n" }}
{{- end }}
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
Resource-name helpers for the job family. These concentrate the printf+trunc
rules so the resource templates (cronjob.yaml, hook.yaml) and the collision
validator (_validate-helpers.tpl) compute every name through ONE seam and can
never drift. Truncation constants live here only.
*/}}

{{/*
Root-level CronJob name. Truncated to 52 chars because Kubernetes appends an
11-char timestamp suffix to the Jobs a CronJob creates.
Usage: {{ include "global-chart.rootCronJobName" (dict "root" . "name" $name) }}
*/}}
{{- define "global-chart.rootCronJobName" -}}
{{- $fullname := include "global-chart.fullname" .root -}}
{{- printf "%s-%s" $fullname .name | trunc 52 | trimSuffix "-" -}}
{{- end -}}

{{/*
Deployment-level CronJob name (includes deployment name for uniqueness).
Truncated to 52 chars (see rootCronJobName).
Usage: {{ include "global-chart.deploymentCronJobName" (dict "root" . "deploymentName" $deployName "jobName" $name) }}
*/}}
{{- define "global-chart.deploymentCronJobName" -}}
{{- $fullname := include "global-chart.fullname" .root -}}
{{- printf "%s-%s-%s" $fullname .deploymentName .jobName | trunc 52 | trimSuffix "-" -}}
{{- end -}}

{{/*
Deployment-level Hook Job name (includes deployment name + hook type for uniqueness).
Canonical form: a single `trunc 63` over the full 4-part name. The collision
validator MUST use this exact decomposition — an earlier validator variant
truncated deploymentFullname first and re-truncated. The two only differ at a
trailing-dash truncation boundary (names K8s would reject), so the collision
verdict was never wrong for valid input; this keeps the two byte-identical.
Usage: {{ include "global-chart.deploymentHookName" (dict "root" . "deploymentName" $deployName "hookType" $hookType "jobName" $name) }}
*/}}
{{- define "global-chart.deploymentHookName" -}}
{{- $fullname := include "global-chart.fullname" .root -}}
{{- printf "%s-%s-%s-%s" $fullname .deploymentName .hookType .jobName | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Hook-prerequisite ConfigMap name for a deployment.
Usage: {{ include "global-chart.hookPrereqConfigName" (dict "deploymentFullname" $deployFullname) }}
*/}}
{{- define "global-chart.hookPrereqConfigName" -}}
{{- printf "%s-hook-config" .deploymentFullname | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Hook-prerequisite Secret name for a deployment.
Usage: {{ include "global-chart.hookPrereqSecretName" (dict "deploymentFullname" $deployFullname) }}
*/}}
{{- define "global-chart.hookPrereqSecretName" -}}
{{- printf "%s-hook-secret" .deploymentFullname | trunc 63 | trimSuffix "-" -}}
{{- end -}}
