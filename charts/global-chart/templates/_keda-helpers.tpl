{{/*
KEDA helpers for global-chart.

Domain: ScaledObject and TriggerAuthentication naming, cross-reference
resolution and CRD presence checks. Kept out of _helpers.tpl so the core
naming/label file stays free of feature-specific logic.
*/}}

{{/*
Name of a chart-created TriggerAuthentication.
Same idiom as the other root-level named resources (see externalsecret.yaml):
{fullname}-{key}. Truncation constant lives here only.
Usage: {{ include "global-chart.kedaTriggerAuthName" (dict "root" . "name" $name) }}
*/}}
{{- define "global-chart.kedaTriggerAuthName" -}}
{{- $fullname := include "global-chart.fullname" .root -}}
{{- printf "%s-%s" $fullname .name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Resolve the name a trigger's authenticationRef should point at.

Values carry the *key* of .Values.kedaTriggerAuthentications, not the rendered
name — the rendered name embeds the release name, which the user cannot know
when writing values. If the key exists in the map, this returns the name the
chart actually renders; otherwise the value is passed through verbatim so a
TriggerAuthentication managed outside the chart can still be referenced.

Only namespaced references are rewritten: the map renders TriggerAuthentication,
never ClusterTriggerAuthentication, so a ref that names a cluster-scoped object
must survive even when its name happens to match a key here.
Usage: {{ include "global-chart.kedaAuthRefName" (dict "root" . "name" $refName "kind" $refKind) }}
*/}}
{{- define "global-chart.kedaAuthRefName" -}}
{{- $auths := default (dict) .root.Values.kedaTriggerAuthentications -}}
{{- $namespaced := or (not .kind) (eq .kind "TriggerAuthentication") -}}
{{- if and $namespaced (hasKey $auths .name) -}}
{{- include "global-chart.kedaTriggerAuthName" (dict "root" .root "name" .name) -}}
{{- else -}}
{{- .name -}}
{{- end -}}
{{- end -}}

{{/*
Fail unless the KEDA CRDs are registered in the target cluster.

Without this the failure surfaces as the API server's "no matches for kind
ScaledObject", which names neither the deployment nor the remedy.

.Capabilities.APIVersions is populated from the cluster only during
install/upgrade; `helm template` and `helm lint` see the built-in set alone, so
offline rendering of a KEDA scenario needs `--api-versions keda.sh/v1alpha1`
(the Makefile passes it, and the unit-test suites declare it under
`capabilities.apiVersions`).
Usage: {{ include "global-chart.requireKedaCrd" (dict "root" . "source" "deployments.foo.keda") }}
*/}}
{{- define "global-chart.requireKedaCrd" -}}
{{- if not (.root.Capabilities.APIVersions.Has "keda.sh/v1alpha1") -}}
{{- fail (printf "%s needs the CRD keda.sh/v1alpha1, which is not registered in the cluster. Install KEDA before installing this release, or render offline with --api-versions keda.sh/v1alpha1." .source) -}}
{{- end -}}
{{- end -}}

{{/*
Build the ScaledObject trigger list with every authenticationRef resolved.
Returns the triggers as YAML, ready to nindent under `triggers:`.
Usage: {{ include "global-chart.kedaTriggers" (dict "root" . "triggers" $keda.triggers) }}
*/}}
{{- define "global-chart.kedaTriggers" -}}
{{- $root := .root -}}
{{- $resolved := list -}}
{{- range $trigger := .triggers -}}
  {{- $copy := deepCopy $trigger -}}
  {{- with $copy.authenticationRef -}}
    {{- $ref := deepCopy . -}}
    {{- $_ := set $ref "name" (include "global-chart.kedaAuthRefName" (dict "root" $root "name" .name "kind" .kind)) -}}
    {{- $_ := set $copy "authenticationRef" $ref -}}
  {{- end -}}
  {{- $resolved = append $resolved $copy -}}
{{- end -}}
{{- toYaml $resolved -}}
{{- end -}}
