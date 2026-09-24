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
Merge the label sources of one resource into a single map and render it.
Params: root · owned (the chart's own labels, as rendered YAML) · own (optional map
of the caller's extra labels, e.g. podLabels).
Precedence: the caller's own > the chart's identity labels > global.commonLabels.
The chart's identity labels win because the selectors are built from them alone
(`selectorLabels` / `deploymentSelectorLabels` never see commonLabels): letting a
common label overwrite `app.kubernetes.io/name` used to make the pod template stop
matching its own Deployment selector.
Like renderAnnotations, this exists so the sources are never concatenated: two
blocks that name the same label put the key in the manifest twice, which Helm
accepts and `kubeconform -strict` rejects. `mergeOverwrite`, not `merge`, for the
empty-string reason given there.
*/}}
{{- define "global-chart.mergeLabels" -}}
{{- $common := default (dict) (default (dict) .root.Values.global).commonLabels -}}
{{- $merged := mergeOverwrite (deepCopy $common) (fromYaml .owned) -}}
{{- toYaml (mergeOverwrite $merged (default (dict) .own)) -}}
{{- end }}

{{/*
Common labels (for non-deployment resources like Ingress)
*/}}
{{- define "global-chart.labels" -}}
{{- include "global-chart.mergeLabels" (dict "root" . "owned" (include "global-chart.chartOwnedLabels" .)) -}}
{{- end }}

{{- define "global-chart.chartOwnedLabels" -}}
helm.sh/chart: {{ include "global-chart.chart" . }}
{{ include "global-chart.selectorLabels" . }}
{{- with .Chart.AppVersion }}
app.kubernetes.io/version: {{ . | quote }}
{{- end }}
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
Pass an optional "own" map (podLabels) to fold it into the same merge instead of
appending a second block after this one.
*/}}
{{- define "global-chart.deploymentLabels" -}}
{{- include "global-chart.mergeLabels" (dict "root" .root "own" .own "owned" (include "global-chart.deploymentOwnedLabels" .)) -}}
{{- end }}

{{- define "global-chart.deploymentOwnedLabels" -}}
helm.sh/chart: {{ include "global-chart.chart" .root }}
{{ include "global-chart.deploymentSelectorLabels" . }}
{{- with .root.Chart.AppVersion }}
app.kubernetes.io/version: {{ . | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- end }}

{{/*
Check if a deployment is enabled. Defaults to true if the field is not set.
Usage: {{ include "global-chart.deploymentEnabled" $deploy }}
Input: the deployment map. The caller has already guarded it against nil —
`hasKey` on nil fails, and every call site sits inside `{{- if $deploy }}`.
Returns the string "true" or "false".
*/}}
{{- define "global-chart.deploymentEnabled" -}}
{{- ternary .enabled true (hasKey . "enabled") -}}
{{- end }}

{{/*
Check if a deployment's Service is enabled. Defaults to true if the field is not
set. Sits next to deploymentEnabled because it answers the same question one
level down, takes its argument the same way, and every call site asks both in
the same breath.
Usage: {{ include "global-chart.serviceEnabled" $svc }}
Input: the deployment's service map, already defaulted to (dict) by the caller.
Returns the string "true" or "false".
*/}}
{{- define "global-chart.serviceEnabled" -}}
{{- ternary .enabled true (hasKey . "enabled") -}}
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
{{- include "global-chart.mergeLabels" (dict "root" . "owned" (include "global-chart.hookOwnedLabels" .)) -}}
{{- end }}

{{- define "global-chart.hookOwnedLabels" -}}
helm.sh/chart: {{ include "global-chart.chart" . }}
{{- with .Chart.AppVersion }}
app.kubernetes.io/version: {{ . | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Hook labels plus the component, for both hook scopes.
Params: root, and deploymentName for a deployment-level hook — omit it for a
root-level one, whose component is just "hook".
Usage: {{ include "global-chart.hookLabelsWithComponent" (dict "root" $root "deploymentName" $deployName) }}
*/}}
{{- define "global-chart.hookLabelsWithComponent" -}}
{{- $component := "hook" -}}
{{- with .deploymentName }}{{- $component = printf "%s-hook" . }}{{- end -}}
{{- $owned := printf "%s\napp.kubernetes.io/component: %s" (include "global-chart.hookOwnedLabels" .root) $component -}}
{{- include "global-chart.mergeLabels" (dict "root" .root "owned" $owned) -}}
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

{{/*
Mounted config file ConfigMap name.
Covers both branches of `mountedConfigFiles`: `files` and `bundles[].files`
render into one name space, so two entries sharing a `name` are a collision —
validateNameCollisions fails on it.
No trunc here: values.schema.json bounds `name` at 52 chars (63 minus
len("md-cm-file-")), the tightest of the two sides, so the derived volume name
stays a legal DNS-1123 label. Truncating instead would silently manufacture the
very collision the validator exists to catch.
Usage: {{ include "global-chart.mountedConfigMapName" (dict "deploymentFullname" $depFullname "fileName" $f.name) }}
*/}}
{{- define "global-chart.mountedConfigMapName" -}}
{{- printf "%s-md-cm-%s" .deploymentFullname .fileName -}}
{{- end -}}

{{/*
Pod volume names for the two branches of mountedConfigFiles: one ConfigMap volume
per `files` entry, named after it, and one projected volume per bundle, indexed.
Two helpers rather than one taking a kind, following hookPrereqConfigName /
hookPrereqSecretName above: the two take disjoint arguments and share no body, so
a kind parameter would only be a flag every call site passes as a literal — plus
a guard for an unreachable third value.
Usage: {{ include "global-chart.mountedFileVolumeName" (dict "fileName" $f.name) }}
       {{ include "global-chart.mountedBundleVolumeName" (dict "bundleIndex" $bi) }}
*/}}
{{- define "global-chart.mountedFileVolumeName" -}}
{{- printf "md-cm-file-%s" .fileName -}}
{{- end -}}

{{- define "global-chart.mountedBundleVolumeName" -}}
{{- printf "md-cm-bundle-%v" .bundleIndex -}}
{{- end -}}

{{/*
ExternalSecret names: the resource and the Secret it produces, for the real
ExternalSecret and for its hook-prerequisite copy (ADR 0007). Four helpers, one
per generated name, following hookPrereqConfigName / hookPrereqSecretName: every
template and the collision validator read the names from here.
The copy's names are the real ones plus "-hook". Its target is its OWN Secret,
never the real one: two ExternalSecrets owning one Secret is ErrSecretIsOwned,
and the copy's deletion would garbage-collect the live Secret with it.
No trunc: an ExternalSecret and a Secret are DNS subdomains (253 chars), and
truncating would manufacture the collisions validateNameCollisions catches.
Params: root, key (the externalSecrets map key); the target helpers also take
secret (the externalSecrets.<key> map), whose target.name overrides the default.
*/}}
{{- define "global-chart.externalSecretName" -}}
{{- printf "%s-%s" (include "global-chart.fullname" .root) .key -}}
{{- end -}}

{{- define "global-chart.externalSecretHookName" -}}
{{- printf "%s-hook" (include "global-chart.externalSecretName" .) -}}
{{- end -}}

{{- define "global-chart.externalSecretTargetName" -}}
{{- $target := default (dict) .secret.target -}}
{{- ternary $target.name (include "global-chart.externalSecretName" .) (hasKey $target "name") -}}
{{- end -}}

{{- define "global-chart.externalSecretHookTargetName" -}}
{{- printf "%s-hook" (include "global-chart.externalSecretTargetName" .) -}}
{{- end -}}

{{/*
Pod volume name for an externalSecrets entry mounted with a mountPath. Not a
public interface, like the md-cm volume names above. A volume name is a
DNS-1123 label, which an externalSecrets key need not be: fail here, at render
time, rather than at apply time far from the cause.
Usage: {{ include "global-chart.externalSecretVolumeName" (dict "key" $key) }}
*/}}
{{- define "global-chart.externalSecretVolumeName" -}}
{{- $name := printf "es-%s" .key -}}
{{- if or (gt (len $name) 63) (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $name)) -}}
{{- fail (printf "externalSecrets key '%s' cannot be mounted: its volume name '%s' is not a DNS-1123 label of at most 63 characters. Rename the key, or inject it without a mountPath." .key $name) -}}
{{- end -}}
{{- $name -}}
{{- end -}}
