{{/*
ServiceAccount resolution, one resolver per scope family (issue #126).

Every ServiceAccount the chart renders or binds is resolved here, as a JSON
object {create, name, automount, annotations} that callers read through
`include ... | fromJson`. Templates never read `serviceAccount.*` from values
themselves. The defaults of a declared serviceAccount map — `create` true,
`automount` true, "" meaning the scope's default name — live in
resolveServiceAccount alone; three copies of them used to drift apart one at a
time.

- deploymentServiceAccount: a deployment's SA. Also read by every deployment-level
  job that inherits it, and by the hook-prerequisite SA copy (ADR 0002).
- rbacServiceAccount: the SA of an rbacs.roles entry.
- jobServiceAccount: a hook or cronjob, both scopes. Its `create` and name keep
  their own chain: `create` defaults to "only when nothing else names a SA", not
  true. Its `automount` and annotations first fall back to the job-level
  automountServiceAccountToken / serviceAccountAnnotations, then to the shared
  defaults above. It takes the parent deployment's SA from
  deploymentServiceAccount. It is also the one resolver that validates: a job
  naming its SA twice, with different names, fails here (issue #133). The check
  sits in the resolver, not in _validate-helpers.tpl, because every render path
  of a job — hook.yaml, cronjob.yaml and the validator — goes through it, so no
  path can use the contradictory values before the check has run. Same reason
  jobImageString owns its fromDeployment fail.
The names these default to come from the naming helpers in _helpers.tpl.
*/}}

{{/*
The shared defaults of a declared serviceAccount map.
Params: sa (the values map, may be nil) · defaultName (the name when the SA is
created) · nameIfBound (optional: the name when it is not created, i.e. an
existing SA is bound; "" means none is named).
An explicit, non-empty sa.name wins over both.
*/}}
{{- define "global-chart.resolveServiceAccount" -}}
{{- $sa := default (dict) .sa -}}
{{- $create := hasKey $sa "create" | ternary $sa.create true -}}
{{- $name := default (ternary .defaultName (default "" .nameIfBound) $create) $sa.name -}}
{{- dict "create" $create "name" $name "automount" (hasKey $sa "automount" | ternary $sa.automount true) "annotations" $sa.annotations | toJson -}}
{{- end }}

{{/*
A deployment's ServiceAccount. Created by default, as <deploymentFullname>; with
create: false and no name, name is "": no SA is named. The Deployment then runs
as "default", which deployment.yaml renders, and a deployment-level job creates
its own SA instead of inheriting one. The resolver cannot return "default"
itself: a job would then inherit it as if the deployment had named it, and an
explicit `name: default` must stay inheritable.
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
{{- $defaultName := include "global-chart.rbacDefaultServiceAccountName" .name -}}
{{- include "global-chart.resolveServiceAccount" (dict "sa" .serviceAccount "defaultName" $defaultName "nameIfBound" $defaultName) -}}
{{- else -}}
{{- dict | toJson -}}
{{- end -}}
{{- end }}

{{/*
ServiceAccount of a hook or cronjob, both scopes: the SA resolver for every job.

Accepts a dict with:
  root         - top-level chart context
  job          - the cronjob/hook command map
  deploy       - the parent deployment map; nil/absent for root-level jobs, which
                 are simply the "no deployment SA applies" case
  deployName   - the deployment key (unused when deploy is nil)
  jobFullname  - the job's own resource name (fallback when a SA is created)
  errCtx       - values path of the job, from jobValuesPath (_job-helpers.tpl),
                 for the fail message below. Every call site passes it, built by
                 that one helper, so whichever renders first names the job the
                 same way

Resolution:
  name:   explicit (serviceAccountName | serviceAccount.name) > deployment SA > jobFullname.
          Empty when serviceAccount.create is false and nothing names a SA: callers
          then omit serviceAccountName and the pod runs as the namespace default.
          The two explicit fields are one name written in two places: both set,
          non-empty and different is a render-time `fail` naming the job and both
          values (issue #133) — before it, serviceAccountName won in silence and a
          created SA carried serviceAccount's annotations under the other name.
          The same name in both stays accepted; "" counts as unset, as in the
          coalesce that reads them. JSON Schema cannot compare two fields, hence
          a template fail (fixture in tests/bad-values/fail/)
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
{{- if and $job.serviceAccountName $jobSAMap.name (ne (toString $job.serviceAccountName) (toString $jobSAMap.name)) -}}
  {{- fail (printf "%s names its ServiceAccount twice, with different names: serviceAccountName %q and serviceAccount.name %q. Keep only one of the two fields (or set the same name in both)." (toString .errCtx) (toString $job.serviceAccountName) (toString $jobSAMap.name)) -}}
{{- end -}}
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
{{- /* automount and annotations fall back to the job-level fields, then to the
       defaults every scope shares: fold the fallback into a copy of the map and
       let resolveServiceAccount apply them */ -}}
{{- $effective := deepCopy $jobSAMap -}}
{{- if and (not (hasKey $effective "automount")) (hasKey $job "automountServiceAccountToken") -}}
  {{- $_ := set $effective "automount" $job.automountServiceAccountToken -}}
{{- end -}}
{{- if not (hasKey $effective "annotations") -}}
  {{- $_ := set $effective "annotations" $job.serviceAccountAnnotations -}}
{{- end -}}
{{- $shared := include "global-chart.resolveServiceAccount" (dict "sa" $effective "defaultName" "") | fromJson -}}
{{- $saAutomount := $shared.automount -}}
{{- $saAnnotations := $shared.annotations -}}
{{- dict "name" $saName "create" $saCreate "automount" $saAutomount "annotations" $saAnnotations | toJson -}}
{{- end -}}
