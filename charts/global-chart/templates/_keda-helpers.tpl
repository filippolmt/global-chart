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
{{- include "global-chart.truncName" (list (printf "%s-%s" $fullname .name) 63) -}}
{{- end -}}

{{/*
Resolve the name a trigger's authenticationRef should point at.

Values carry the *key* of .Values.kedaTriggerAuthentications, not the rendered
name — the rendered name embeds the release name, which the user cannot know
when writing values. If the key exists in the map, this returns the name the
chart actually renders; otherwise the value is passed through verbatim so a
TriggerAuthentication managed outside the chart can still be referenced. A key
whose entry is empty fails: it renders nothing, so the ref would dangle. A null
entry is the key left out (issue #303): the ref passes through verbatim.

Only namespaced references are rewritten: the map renders TriggerAuthentication,
never ClusterTriggerAuthentication, so a ref that names a cluster-scoped object
must survive even when its name happens to match a key here.
Usage: {{ include "global-chart.kedaAuthRefName" (dict "root" . "name" $refName "kind" $refKind) }}
*/}}
{{- define "global-chart.kedaAuthRefName" -}}
{{- $auths := default (dict) .root.Values.kedaTriggerAuthentications -}}
{{- $namespaced := or (not .kind) (eq .kind "TriggerAuthentication") -}}
{{- if and $namespaced (eq (include "global-chart.isSet" (list $auths .name)) "true") -}}
{{- if not (index $auths .name) -}}
{{- fail (printf "kedaTriggerAuthentications.%s: empty, but a keda trigger's authenticationRef names it. An empty entry renders no TriggerAuthentication, and the ScaledObject would reference nothing. Fill the entry, or drop the reference." .name) -}}
{{- end -}}
{{- include "global-chart.kedaTriggerAuthName" (dict "root" .root "name" .name) -}}
{{- else -}}
{{- .name -}}
{{- end -}}
{{- end -}}

{{/*
Fail unless the KEDA CRDs are registered in the target cluster.

Without this the failure surfaces as the API server's "no matches for kind
ScaledObject", which names neither the workload nor the remedy.

.Capabilities.APIVersions is populated from the cluster only during
install/upgrade; `helm template` and `helm lint` see the built-in set alone, so
offline rendering of a KEDA scenario needs `--api-versions keda.sh/v1alpha1`
(the Makefile passes it, and the unit-test suites declare it under
`capabilities.apiVersions`). The check itself is requireCrd's.
Usage: {{ include "global-chart.requireKedaCrd" (dict "root" . "errCtx" "workloads.foo.keda") }}
*/}}
{{- define "global-chart.requireKedaCrd" -}}
{{- include "global-chart.requireCrd" (dict "root" .root "apiVersion" "keda.sh/v1alpha1" "install" "Install KEDA" "errCtx" (required "requireKedaCrd: errCtx is required (the values path of the KEDA resource)" .errCtx)) -}}
{{- end -}}

{{/*
Build the ScaledObject trigger list with every authenticationRef resolved.
Returns the triggers as YAML, ready to nindent under `triggers:`. A null
trigger, or a null authenticationRef name, fails naming its path (issue #198),
and so does a missing one, as the schema's `required` (issue #304); a null map
value inside a trigger is unset and left out (issue #294).
Usage: {{ include "global-chart.kedaTriggers" (dict "root" . "triggers" $keda.triggers "errCtx" "workloads.api.keda.triggers") }}
*/}}
{{- define "global-chart.kedaTriggers" -}}
{{- $root := .root -}}
{{- $errCtx := required "kedaTriggers: errCtx is required (the values path of the triggers)" .errCtx -}}
{{- include "global-chart.rejectNullItems" (dict "list" .triggers "errCtx" $errCtx) -}}
{{- $resolved := list -}}
{{- range $i, $trigger := .triggers -}}
  {{- $copy := deepCopy $trigger -}}
  {{- if eq (include "global-chart.isSet" (list $copy "authenticationRef")) "true" -}}
    {{- $ref := $copy.authenticationRef -}}
    {{- $nameCtx := printf "%s[%d].authenticationRef.name" $errCtx $i -}}
    {{- if not (hasKey $ref "name") -}}
      {{- fail (printf "%s: mandatory, the TriggerAuthentication the trigger reads" $nameCtx) -}}
    {{- end -}}
    {{- include "global-chart.rejectNull" (dict "value" $ref.name "errCtx" $nameCtx) -}}
    {{- $_ := set $ref "name" (include "global-chart.kedaAuthRefName" (dict "root" $root "name" $ref.name "kind" $ref.kind)) -}}
    {{- $_ := set $copy "authenticationRef" $ref -}}
  {{- end -}}
  {{- $resolved = append $resolved $copy -}}
{{- end -}}
{{- include "global-chart.dropNullsInPlace" $resolved -}}
{{- toYaml $resolved -}}
{{- end -}}
