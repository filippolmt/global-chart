{{/*
ServiceAccount resolution, one resolver per scope family (issue #126).

Every ServiceAccount the chart renders or binds is resolved here, as a JSON
object {create, name, automount, annotations} that callers read through
`include ... | fromJson`. Templates never read `serviceAccount.*` from values
themselves. The defaults of a declared serviceAccount map — `create` true,
`automount` true, "" meaning the scope's default name — live in
resolveServiceAccount, for deployments and rbac entries; three copies of them
used to drift apart one at a time.

- deploymentServiceAccount: a deployment's SA. Also read by every deployment-level
  job that inherits it, and by the hook-prerequisite SA copy (ADR 0002).
- rbacServiceAccount: the SA of an rbacs.roles entry.
- jobServiceAccount: a hook or cronjob, both scopes. It keeps its own chain: its
  `create` default is "only when nothing else names a SA", not true, and its
  `automount` and annotations fall back to the job-level
  automountServiceAccountToken / serviceAccountAnnotations. It takes the parent
  deployment's SA from deploymentServiceAccount.
The names these default to come from the naming helpers in _helpers.tpl.
*/}}

{{/*
The shared defaults of a declared serviceAccount map.
Params: sa (the values map, may be nil) · defaultName (the name when the SA is
created) · boundName (optional: the name when it is not, i.e. an existing SA is
bound; "" means none, and the pod runs as the namespace default).
An explicit, non-empty sa.name wins over both.
*/}}
{{- define "global-chart.resolveServiceAccount" -}}
{{- $sa := default (dict) .sa -}}
{{- $create := hasKey $sa "create" | ternary $sa.create true -}}
{{- $name := default (ternary .defaultName (default "" .boundName) $create) $sa.name -}}
{{- dict "create" $create "name" $name "automount" (hasKey $sa "automount" | ternary $sa.automount true) "annotations" $sa.annotations | toJson -}}
{{- end }}

{{/*
A deployment's ServiceAccount. Created by default, as <deploymentFullname>; with
create: false and no name, name is "" — deployment.yaml then renders "default",
and a deployment-level job creates its own SA instead of inheriting none.
Usage: {{ include "global-chart.deploymentServiceAccount" (dict "root" . "deploymentName" $name "deployment" $deploy) | fromJson }}
*/}}
{{- define "global-chart.deploymentServiceAccount" -}}
{{- $defaultName := include "global-chart.deploymentFullname" (dict "root" .root "deploymentName" .deploymentName) -}}
{{- include "global-chart.resolveServiceAccount" (dict "sa" .deployment.serviceAccount "defaultName" $defaultName) -}}
{{- end }}

{{/*
ServiceAccount of an rbacs.roles entry; {} when the entry declares none.
Presence is hasKey, never truthiness: `serviceAccount: {}` declares an SA with
every default, as it does for a deployment (issue #124). <role>-sa is the name
whether the SA is created or bound.
Usage: {{ include "global-chart.rbacServiceAccount" $role | fromJson }}
*/}}
{{- define "global-chart.rbacServiceAccount" -}}
{{- if hasKey . "serviceAccount" -}}
{{- $defaultName := include "global-chart.truncName" (list (printf "%s-sa" .name) 63) -}}
{{- include "global-chart.resolveServiceAccount" (dict "sa" .serviceAccount "defaultName" $defaultName "boundName" $defaultName) -}}
{{- else -}}
{{- dict | toJson -}}
{{- end -}}
{{- end }}

{{/*
ServiceAccount of a hook or cronjob, both scopes: the SA resolver for every job.

Helpers can only return strings, so this returns a JSON object; callers do
`include ... | fromJson` and read .name/.create/.automount/.annotations.

Accepts a dict with:
  root         - top-level chart context
  job          - the cronjob/hook command map
  deploy       - the parent deployment map; nil/absent for root-level jobs, which
                 are simply the "no deployment SA applies" case
  deployName   - the deployment key (unused when deploy is nil)
  jobFullname  - the job's own resource name (fallback when a SA is created)

Resolution:
  name:   explicit (serviceAccountName | serviceAccount.name) > deployment SA > jobFullname.
          Empty when serviceAccount.create is false and nothing names a SA: callers
          then omit serviceAccountName and the pod runs as the namespace default
  create: true only when no explicit/deployment SA applies, unless serviceAccount.create overrides
  automount: serviceAccount.automount > job automountServiceAccountToken (default true)
  annotations: SA-map annotations > job.serviceAccountAnnotations
*/}}
{{- define "global-chart.jobServiceAccount" -}}
{{- $root := .root -}}
{{- $job := .job -}}
{{- $deploy := default (dict) .deploy -}}
{{- $deployName := .deployName -}}
{{- $jobFullname := .jobFullname -}}
{{- $jobSAMap := (and (hasKey $job "serviceAccount") (kindIs "map" $job.serviceAccount)) | ternary $job.serviceAccount (dict) -}}
{{- $jobSAExplicitName := coalesce $job.serviceAccountName $jobSAMap.name -}}
{{- /* The deployment's SA name, created or referenced-existing; "" when it
       names none, and always "" at root level */ -}}
{{- $deploymentSAName := "" -}}
{{- if $deploy -}}
  {{- $deploymentSAName = (include "global-chart.deploymentServiceAccount" (dict "root" $root "deploymentName" $deployName "deployment" $deploy) | fromJson).name -}}
{{- end -}}
{{- $saName := "" -}}
{{- $saCreate := false -}}
{{- if $jobSAExplicitName -}}
  {{- $saName = $jobSAExplicitName -}}
{{- else if $deploymentSAName -}}
  {{- $saName = $deploymentSAName -}}
{{- else -}}
  {{- $saName = $jobFullname -}}
  {{- $saCreate = true -}}
{{- end -}}
{{- /* Override saCreate if explicitly set in job */ -}}
{{- if hasKey $jobSAMap "create" -}}
  {{- $saCreate = $jobSAMap.create -}}
  {{- if $saCreate -}}
    {{- /* Creating one: under the explicit name when given, else the job's own */ -}}
    {{- $saName = default $jobFullname $jobSAExplicitName -}}
  {{- else if and (not $jobSAExplicitName) (not $deploymentSAName) -}}
    {{- /* Told not to create a SA and given no name to bind: leave the pod on the
           namespace default rather than point it at a SA nothing creates */ -}}
    {{- $saName = "" -}}
  {{- end -}}
{{- end -}}
{{- $saAutomount := true -}}
{{- if hasKey $job "automountServiceAccountToken" -}}
  {{- $saAutomount = $job.automountServiceAccountToken -}}
{{- end -}}
{{- if hasKey $jobSAMap "automount" -}}
  {{- $saAutomount = $jobSAMap.automount -}}
{{- end -}}
{{- $saAnnotations := $job.serviceAccountAnnotations -}}
{{- if hasKey $jobSAMap "annotations" -}}
  {{- $saAnnotations = $jobSAMap.annotations -}}
{{- end -}}
{{- dict "name" $saName "create" $saCreate "automount" $saAutomount "annotations" $saAnnotations | toJson -}}
{{- end -}}
