{{/*
Hook lifecycle helpers for global-chart.

Single home for the three "helm.sh/hook*" annotations: the effective weight,
the ordering invariant prereq (w-7) < SA (w-5) < Job (w), and the delete
policy per role. See docs/adr/0004-one-module-for-hook-lifecycle-annotations.md.
Also the home of which hooks the per-resource hook-prerequisite copies serve:
the phase predicate shared by all of them, and the consumer scans that decide
when a copy exists and who reads it — the ExternalSecret copy (ADR 0007) and
the rbacs.roles copy (ADR 0010).
*/}}

{{/*
The effective hook weight of one hook command: its own "weight" or the default.
The ONLY place that default and its int coercion are spelled out.
Usage: {{ include "global-chart.effectiveHookWeight" $command }}
*/}}
{{- define "global-chart.effectiveHookWeight" -}}
{{- $command := default (dict) . -}}
{{- int (ternary $command.weight 10 (hasKey $command "weight")) -}}
{{- end -}}

{{/*
Minimum effective hook weight across a hooks map.
Param: hooks - map hookType -> jobName -> command (a deployment's .hooks, or a
        synthetic subset of it when only some hooks count)
Usage: {{ include "global-chart.minHookWeight" (dict "hooks" $deploy.hooks) }}
*/}}
{{- define "global-chart.minHookWeight" -}}
{{- $min := 10 -}}
{{- range $hookType, $jobs := (default (dict) .hooks) -}}
{{- range $name, $command := (default (dict) $jobs) -}}
{{- if $command -}}
{{- $w := int (include "global-chart.effectiveHookWeight" $command) -}}
{{- if lt $w $min -}}{{- $min = $w -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $min -}}
{{- end -}}

{{/*
The three hook lifecycle annotations for one resource.
Params:
  hookType - value of "helm.sh/hook" (a single type, or a comma-joined list for
             the prereq copies)
  role     - job | sa | prereq | pre-install-sa; orthogonal to scope: root-level
             and deployment-level hooks share the roles they have
  command  - the hook's own map, for the roles a hook owns (job, sa)
  weight   - the Job weight to derive from, for the plumbing roles (prereq,
             pre-install-sa), whose weight is a minimum across several hooks
             rather than one hook's own; overrides command. Passing a command
             to a plumbing role is a template error, not a silent override
Usage:
  {{- include "global-chart.hookAnnotations" (dict "hookType" $hookType "role" "job" "command" $command) | nindent 4 }}
*/}}
{{- define "global-chart.hookAnnotations" -}}
{{- $command := default (dict) .command -}}
{{- $weight := int (ternary .weight (include "global-chart.effectiveHookWeight" $command) (hasKey . "weight")) -}}
{{- /* Role table: offset from the Job weight, default delete policy, and whether
       the resource belongs to one hook. */ -}}
{{- $table := dict
      "job"            (dict "offset" 0  "policy" "before-hook-creation"                "ownedByHook" true)
      "sa"             (dict "offset" -5 "policy" "before-hook-creation,hook-succeeded" "ownedByHook" true)
      "prereq"         (dict "offset" -7 "policy" "before-hook-creation,hook-succeeded" "ownedByHook" false)
      "pre-install-sa" (dict "offset" -5 "policy" "hook-succeeded,hook-failed"          "ownedByHook" false) -}}
{{- $row := index $table .role -}}
{{- /* Both guards fail loudly on purpose. With neither, an unknown role silently
       takes offset 0 and renders a null delete policy — an invalid annotation the
       API server rejects at apply time, far from its cause — and a plumbing role
       handed a command would silently honour a deletePolicy that ADR 0002/0004
       reject. Adding a role means adding a row, and the rows are the enforcement. */ -}}
{{- if not $row -}}
{{- fail (printf "hookAnnotations: unknown role %q (expected one of: %s)" .role (keys $table | sortAlpha | join ", ")) -}}
{{- end -}}
{{- if and (not $row.ownedByHook) (hasKey . "command") -}}
{{- fail (printf "hookAnnotations: role %q is plumbing shared by every hook of the deployment, so an explicit deletePolicy would have no owner. Call it with a weight, not a command." .role) -}}
{{- end -}}
{{- /* An explicit deletePolicy belongs to the hook, so it reaches only the roles
       a hook owns — the guard above is what keeps that true. The prereq copies are
       shared by every hook of the deployment, and the pre-install SA copy cannot
       take before-hook-creation without deleting a live SA mid-upgrade (ADR 0002). */ -}}
{{- $policy := ternary $command.deletePolicy $row.policy (hasKey $command "deletePolicy") -}}
{{- /* Derived weights are never floored at 0: Helm allows negative hook weights,
       and clamping a prereq to 0 would sort it AFTER a Job with a negative
       weight — the exact ordering failure this invariant exists to prevent. */ -}}
"helm.sh/hook": {{ .hookType | quote }}
"helm.sh/hook-weight": {{ add $weight $row.offset | quote }}
"helm.sh/hook-delete-policy": {{ $policy | quote }}
{{- end -}}

{{/*
Whether a hook of this phase reads the hook-prerequisite copy of a normal
resource rather than the resource itself: "true" for a pre-* phase, which runs
before the normal resources are applied, and for post-delete, which runs after
they are gone (an ExternalSecret's Secret with it, through its ownerReference).
Every other phase finds the real resource in place. The ONE place the cut is
made, for the ExternalSecret copy (ADR 0007) and the rbacs.roles copy (ADR
0010) alike — the consumer scans below (which emit the copies) and the call
sites that point a hook at them (jobPodSpec for the Secret, hook.yaml for the
ServiceAccount) all ask here, so a hook can never read a copy that was not
rendered.
Usage: {{ include "global-chart.hookReadsPrereqCopy" $hookType }}
*/}}
{{- define "global-chart.hookReadsPrereqCopy" -}}
{{- or (hasPrefix "pre-" (toString .)) (eq (toString .) "post-delete") -}}
{{- end -}}

{{/*
The hooks that read the copy of each ExternalSecret, in both scopes: the input of the
ExternalSecret hook-prerequisite copy (ADR 0007), for externalsecret.yaml, which
emits it, and for validateNameCollisions, which registers its names.
Returns JSON: key -> hookType -> "<scope>/<job>" -> command, the shape
minHookWeight reads, so the copy's weight and phases come from the hooks that
actually read it. A key no such hook references is absent: it gets no copy.
Only the phases hookReadsPrereqCopy names; a hook of any other phase
reads the real Secret.
Usage: {{ $consumers := include "global-chart.externalSecretHookConsumers" $root | fromJson }}
*/}}
{{- define "global-chart.externalSecretHookConsumers" -}}
{{- $out := dict -}}
{{- $scopes := list (dict "id" "root" "hooks" .Values.hooks) -}}
{{- range $deployName, $deploy := .Values.deployments -}}
  {{- if and $deploy (eq (include "global-chart.deploymentEnabled" $deploy) "true") -}}
    {{- $scopes = append $scopes (dict "id" (printf "deployments.%s" $deployName) "hooks" $deploy.hooks "deploy" $deploy) -}}
  {{- end -}}
{{- end -}}
{{- range $scope := $scopes -}}
  {{- range $hookType, $jobs := (default (dict) $scope.hooks) -}}
    {{- if eq (include "global-chart.hookReadsPrereqCopy" $hookType) "true" -}}
      {{- range $jobName, $command := (default (dict) $jobs) -}}
        {{- if $command -}}
          {{- $refs := include "global-chart.jobExternalSecretRefs" (dict "job" $command "deploy" $scope.deploy) | fromJson -}}
          {{- range $ref := concat $refs.inherited $refs.own -}}
            {{- $byType := default (dict) (index $out $ref.name) -}}
            {{- $jobsOfType := default (dict) (index $byType $hookType) -}}
            {{- $_ := set $jobsOfType (printf "%s/%s" $scope.id $jobName) $command -}}
            {{- $_ := set $byType $hookType $jobsOfType -}}
            {{- $_ := set $out $ref.name $byType -}}
          {{- end -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{/*
The ServiceAccount through which a hook reads the rbacs.roles hook-prerequisite
copy (ADR 0010), or "" when it reads none. The ONE match: rbacHookConsumers
(which emits the copies) and hook.yaml (which points the hook's pod at the
copied SA) both ask here, so a hook can never run as a copy that was not
rendered, nor miss one that was.
A hook reads the copy when all hold:
- its phase is one hookReadsPrereqCopy names;
- its resolved SA is bound, not created by the hook itself (create: false);
- that SA's name is the SA of at least one rbacs.roles entry, whether the entry
  creates it or binds an existing one.
The SA is compared by resolved name, so a hook inheriting its deployment's SA
matches a role binding that SA, in either scope.
Params: root · hookType · sa (the hook's jobServiceAccount result).
Usage: {{ include "global-chart.hookRbacServiceAccount" (dict "root" $root "hookType" $hookType "sa" $sa) }}
*/}}
{{- define "global-chart.hookRbacServiceAccount" -}}
{{- $sa := .sa -}}
{{- if and (eq (include "global-chart.hookReadsPrereqCopy" .hookType) "true") (not $sa.create) $sa.name -}}
  {{- $match := false -}}
  {{- range $role := (default (dict) .root.Values.rbacs).roles -}}
    {{- if eq (include "global-chart.rbacServiceAccount" $role | fromJson).name $sa.name -}}
      {{- $match = true -}}
    {{- end -}}
  {{- end -}}
  {{- if $match -}}{{- $sa.name -}}{{- end -}}
{{- end -}}
{{- end -}}

{{/*
The ServiceAccount the rbacs.roles copies bind, and the one a hook reading them
runs as: <sa>-hook when an rbacs.roles entry creates that SA — the real one is a
normal resource, absent during a pre-* phase, so the copy is created alongside
the Role copy — else the SA itself, which exists outside the release. Single
home of that choice, for rbac.yaml (the copy's SA and RoleBinding subject) and
hook.yaml (the pod's serviceAccountName).
The copy has its own name, never the real one: under Argo CD a pre-install hook
runs on every sync, and a same-name copy deleted by hook-succeeded would take
the live SA with it. The cost: an identity keyed on the SA name (Workload
Identity, IRSA) does not reach the copy; bind an existing SA to keep it.
Params: root · name (the SA name hookRbacServiceAccount returned).
Usage: {{ include "global-chart.rbacCopyServiceAccountName" (dict "root" $root "name" $name) }}
*/}}
{{- define "global-chart.rbacCopyServiceAccountName" -}}
{{- $name := .name -}}
{{- $created := false -}}
{{- range $role := (default (dict) .root.Values.rbacs).roles -}}
  {{- $sa := include "global-chart.rbacServiceAccount" $role | fromJson -}}
  {{- if and $sa.create (eq $sa.name $name) -}}{{- $created = true -}}{{- end -}}
{{- end -}}
{{- ternary (include "global-chart.rbacHookName" (list $name 63)) $name $created -}}
{{- end -}}

{{/*
The hooks that read the copy of each rbacs.roles entry, in both scopes: the
input of the rbacs.roles hook-prerequisite copy (ADR 0010), for rbac.yaml,
which emits it, and for validateNameCollisions, which registers its names.
Returns JSON: role name -> hookType -> "<scope>/<job>" -> command, the shape
minHookWeight reads, as externalSecretHookConsumers does. A role whose SA no
such hook runs as is absent: it gets no copy. Role names are unique
(validateNameCollisions), so the name is a safe key.
Usage: {{ $consumers := include "global-chart.rbacHookConsumers" $root | fromJson }}
*/}}
{{- define "global-chart.rbacHookConsumers" -}}
{{- $root := . -}}
{{- $out := dict -}}
{{- $roles := (default (dict) .Values.rbacs).roles -}}
{{- if $roles -}}
  {{- $hooks := list -}}
  {{- range $hookType, $jobs := (default (dict) .Values.hooks) -}}
    {{- range $jobName, $command := (default (dict) $jobs) -}}
      {{- if $command -}}
        {{- $fn := include "global-chart.hookfullname" (merge (dict "hookname" $hookType "jobname" $jobName) $root) -}}
        {{- $sa := include "global-chart.jobServiceAccount" (dict "root" $root "job" $command "jobFullname" $fn) | fromJson -}}
        {{- $hooks = append $hooks (dict "id" (printf "hooks/%s" $jobName) "hookType" $hookType "command" $command "sa" $sa) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- range $deployName, $deploy := .Values.deployments -}}
    {{- if and $deploy (eq (include "global-chart.deploymentEnabled" $deploy) "true") -}}
      {{- range $hookType, $jobs := (default (dict) $deploy.hooks) -}}
        {{- range $jobName, $command := (default (dict) $jobs) -}}
          {{- if $command -}}
            {{- $fn := include "global-chart.deploymentHookName" (dict "root" $root "deploymentName" $deployName "hookType" $hookType "jobName" $jobName) -}}
            {{- $sa := include "global-chart.jobServiceAccount" (dict "root" $root "job" $command "deploy" $deploy "deployName" $deployName "jobFullname" $fn) | fromJson -}}
            {{- $hooks = append $hooks (dict "id" (printf "deployments.%s/%s" $deployName $jobName) "hookType" $hookType "command" $command "sa" $sa) -}}
          {{- end -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- range $hook := $hooks -}}
    {{- $saName := include "global-chart.hookRbacServiceAccount" (dict "root" $root "hookType" $hook.hookType "sa" $hook.sa) -}}
    {{- if $saName -}}
      {{- range $role := $roles -}}
        {{- if eq (include "global-chart.rbacServiceAccount" $role | fromJson).name $saName -}}
          {{- $byType := default (dict) (index $out $role.name) -}}
          {{- $jobsOfType := default (dict) (index $byType $hook.hookType) -}}
          {{- $_ := set $jobsOfType $hook.id $hook.command -}}
          {{- $_ := set $byType $hook.hookType $jobsOfType -}}
          {{- $_ := set $out $role.name $byType -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}
