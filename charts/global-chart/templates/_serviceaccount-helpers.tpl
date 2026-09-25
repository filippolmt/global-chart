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
- rbacServiceAccount: the SA of an rbacs.roles entry. rbacServiceAccounts folds
  every entry's into one map by SA name, the input of the rbacs.roles
  hook-prerequisite copy (ADR 0010): rbacCopyServiceAccountName picks the SA the
  copy binds, hookRbacCopy decides whether a hook reads the copy, and
  hookServiceAccountName is the SA a hook's pod runs as, the copy's included.
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
                 for the fail message below (required). Every call site passes
                 it, built by that one helper, so whichever renders first names
                 the job the same way

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
{{- $errCtx := required "jobServiceAccount: errCtx is required (build it with jobValuesPath)" .errCtx -}}
{{- $jobSAMap := (and (hasKey $job "serviceAccount") (kindIs "map" $job.serviceAccount)) | ternary $job.serviceAccount (dict) -}}
{{- if and $job.serviceAccountName $jobSAMap.name (ne (toString $job.serviceAccountName) (toString $jobSAMap.name)) -}}
  {{- fail (printf "%s names its ServiceAccount twice, with different names: serviceAccountName %q and serviceAccount.name %q. Keep only one of the two fields (or set the same name in both)." $errCtx (toString $job.serviceAccountName) (toString $jobSAMap.name)) -}}
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

{{/*
The ServiceAccounts of the rbacs.roles entries, by name: the one scan of the
entries that the rbacs.roles hook-prerequisite copy (ADR 0010) reads.
Returns JSON: SA name -> {create, roles}. create is true when any entry creates
that SA; roles lists, in values order, every entry whose SA it is. An entry
declaring no SA is absent: nothing binds it, so no hook can match it.
Usage: {{ $rbacSAs := include "global-chart.rbacServiceAccounts" $root | fromJson }}
*/}}
{{- define "global-chart.rbacServiceAccounts" -}}
{{- $out := dict -}}
{{- range $role := (default (dict) .Values.rbacs).roles -}}
  {{- $sa := include "global-chart.rbacServiceAccount" $role | fromJson -}}
  {{- if $sa.name -}}
    {{- $entry := default (dict "create" false "roles" (list)) (index $out $sa.name) -}}
    {{- $_ := set $out $sa.name (dict "create" (or $entry.create $sa.create) "roles" (append $entry.roles $role.name)) -}}
  {{- end -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{/*
The ServiceAccount the rbacs.roles copies bind, and the one a hook reading them
runs as: <sa>-hook when an rbacs.roles entry creates that SA — the real one is a
normal resource, absent during the phases the copy serves, so the copy is
created alongside the Role copy — else the SA itself, which exists outside the
release. Single home of that choice, for rbac.yaml (the copy's SA and
RoleBinding subject), hookRbacCopy (the pod) and validateNameCollisions.
The copy has its own name, never the real one: under Argo CD a pre-install hook
runs on every sync, and a same-name copy deleted by hook-succeeded would take
the live SA with it. The cost: an identity keyed on the SA name (Workload
Identity, IRSA) does not reach the copy; bind an existing SA to keep it.
Params: root · name (an rbacs.roles SA name).
Usage: {{ include "global-chart.rbacCopyServiceAccountName" (dict "root" $root "name" $name) }}
*/}}
{{- define "global-chart.rbacCopyServiceAccountName" -}}
{{- $created := false -}}
{{- with index (include "global-chart.rbacServiceAccounts" .root | fromJson) .name -}}
  {{- $created = .create -}}
{{- end -}}
{{- ternary (include "global-chart.rbacServiceAccountHookName" .name) .name $created -}}
{{- end -}}

{{/*
The rbacs.roles hook-prerequisite copy a hook reads (ADR 0010), or {} when it
reads none. The ONE match: rbacHookConsumers (which emits the copies) and
hookServiceAccountName (which points the hook's pod at the copied SA) both ask
here, so a hook can never run as a copy that was not rendered, nor miss one
that was.
A hook reads the copy when all hold:
- its phase is one hookReadsPrereqCopy names;
- its resolved SA is bound, not created by the hook itself (create: false);
- that SA's name is the SA of at least one rbacs.roles entry, whether the entry
  creates it or binds an existing one.
The SA is compared by resolved name, so a hook inheriting its deployment's SA
matches a role binding that SA, in either scope.
Returns JSON: {serviceAccountName, roles} — the SA the pod runs as, and every
entry whose copy it reads.
Params: root · hookType · sa (the hook's jobServiceAccount result).
Usage: {{ $copy := include "global-chart.hookRbacCopy" (dict "root" $root "hookType" $hookType "sa" $sa) | fromJson }}
*/}}
{{- define "global-chart.hookRbacCopy" -}}
{{- $sa := .sa -}}
{{- $out := dict -}}
{{- if and (eq (include "global-chart.hookReadsPrereqCopy" .hookType) "true") (not $sa.create) $sa.name -}}
  {{- with index (include "global-chart.rbacServiceAccounts" .root | fromJson) $sa.name -}}
    {{- $out = dict "serviceAccountName" (include "global-chart.rbacCopyServiceAccountName" (dict "root" $.root "name" $sa.name)) "roles" .roles -}}
  {{- end -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{/*
The ServiceAccount a hook's pod runs as: the SA of the rbacs.roles copy it
reads (hookRbacCopy), else its own resolved SA. hook.yaml calls it once per
scope, so neither scope can forget the redirect.
Params: root · hookType · sa (the hook's jobServiceAccount result).
Usage: {{ $saName := include "global-chart.hookServiceAccountName" (dict "root" $root "hookType" $hookType "sa" $sa) }}
*/}}
{{- define "global-chart.hookServiceAccountName" -}}
{{- default .sa.name (include "global-chart.hookRbacCopy" . | fromJson).serviceAccountName -}}
{{- end -}}
