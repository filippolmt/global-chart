{{/*
Hook lifecycle helpers for global-chart.

Single home for the three "helm.sh/hook*" annotations: the effective weight,
the ordering invariant prereq (w-7) < SA (w-5) < Job (w), and the delete
policy per role. See docs/adr/0004-one-module-for-hook-lifecycle-annotations.md.
Also the home of which hooks the per-resource hook-prerequisite copies serve:
the phase predicate shared by all of them, the one enumeration of the hooks it
admits, and the consumer scans that decide when a copy exists and who reads it
— the ExternalSecret copy (ADR 0007), the rbacs.roles copy (ADR 0010) and the
copy of a ServiceAccount the release creates (ADR 0011). Which copy a hook's
ServiceAccount matches is a ServiceAccount question, answered by hookRbacCopy
and hookReadsServiceAccountCopy in _serviceaccount-helpers.tpl.
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
  role     - job | sa | prereq; orthogonal to scope: root-level and
             deployment-level hooks share the roles they have
  command  - the hook's own map, for the roles a hook owns (job, sa)
  weight   - the Job weight to derive from, for the plumbing role (prereq),
             whose weight is a minimum across several hooks
             rather than one hook's own; overrides command. Passing a command
             to a plumbing role is a template error, not a silent override
Usage:
  {{- include "global-chart.hookAnnotations" (dict "hookType" $hookType "role" "job" "command" $command) | nindent 4 }}
*/}}
{{- define "global-chart.hookAnnotations" -}}
{{- $command := default (dict) .command -}}
{{- $weight := int (ternary .weight (include "global-chart.effectiveHookWeight" $command) (hasKey . "weight")) -}}
{{- /* Role table: offset from the Job weight, default delete policy, and whether
       the resource belongs to one hook. The plumbing (sa, prereq) deletes itself on
       failure too: Argo CD marks every hook of a failed operation HookFailed, so
       without hook-failed a copy outlives the attempt and the retry's
       before-hook-creation races the garbage collector on what it owned (ADR 0015).
       The Job keeps no hook-failed: a failed Job is the record of what broke. */ -}}
{{- $table := dict
      "job"            (dict "offset" 0  "policy" "before-hook-creation"                            "ownedByHook" true)
      "sa"             (dict "offset" -5 "policy" "before-hook-creation,hook-succeeded,hook-failed" "ownedByHook" true)
      "prereq"         (dict "offset" -7 "policy" "before-hook-creation,hook-succeeded,hook-failed" "ownedByHook" false) -}}
{{- $row := index $table .role -}}
{{- /* Both guards fail loudly on purpose. With neither, an unknown role silently
       takes offset 0 and renders a null delete policy — an invalid annotation the
       API server rejects at apply time, far from its cause — and a plumbing role
       handed a command would silently honour a deletePolicy that ADR 0004
       rejects. Adding a role means adding a row, and the rows are the enforcement. */ -}}
{{- if not $row -}}
{{- fail (printf "hookAnnotations: unknown role %q (expected one of: %s)" .role (keys $table | sortAlpha | join ", ")) -}}
{{- end -}}
{{- if and (not $row.ownedByHook) (hasKey . "command") -}}
{{- fail (printf "hookAnnotations: role %q is plumbing shared by every hook of the deployment, so an explicit deletePolicy would have no owner. Call it with a weight, not a command." .role) -}}
{{- end -}}
{{- /* An explicit deletePolicy belongs to the hook, so it reaches only the roles
       a hook owns — the guard above is what keeps that true. The prereq copies are
       shared by every hook that reads them, so none of them owns the policy. */ -}}
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
resource rather than the resource itself. "true" for:
- pre-install, pre-upgrade and pre-rollback, which run before the normal
  resources of the revision being applied: on an install they do not exist yet,
  and on an upgrade or a rollback the chart cannot tell whether that revision
  adds them (`lookup` is rejected: it returns nothing under `helm template`);
- post-delete, which runs after they are gone (an ExternalSecret's Secret with
  it, through its ownerReference).
pre-delete is not one: it runs before Helm deletes anything, against the
release that is still installed, so the real resources are in place. Reading a
copy there would only cost: an ExternalSecret copy to reconcile first, and for
rbacs.roles a pod moved off the SA an identity binding is keyed on.
Every other phase finds the real resource in place. The ONE place the cut is
made, for the ExternalSecret copy (ADR 0007), the rbacs.roles copy (ADR 0010)
and the ServiceAccount copy (ADR 0011) alike — the consumer scans below (which
emit the copies) and the call sites that point a hook at them (jobPodSpec for
the Secret, hookRbacCopy and hookReadsServiceAccountCopy for the
ServiceAccount) all ask here, so a hook can never read a copy that was not
rendered.
Usage: {{ include "global-chart.hookReadsPrereqCopy" $hookType }}
*/}}
{{- define "global-chart.hookReadsPrereqCopy" -}}
{{- $type := toString . -}}
{{- and (or (hasPrefix "pre-" $type) (eq $type "post-delete")) (ne $type "pre-delete") -}}
{{- end -}}

{{/*
Every hook that reads the hook-prerequisite copies, in both scopes: the one
enumeration the consumer scans below walk. Fills `out` in place, keyed by the
hook's values path (jobValuesPath, unique across both scopes), with
{hookType, jobName, command, fullname, deploy, deployName} — deploy and
deployName absent at root level. Disabled deployments are skipped: they render
no hook. Only the phases hookReadsPrereqCopy names.
Params: root · out (the accumulator dict, mutated in place).
Usage: {{- $hooks := dict }}{{- include "global-chart.prereqCopyHooks" (dict "root" $root "out" $hooks) }}
*/}}
{{- define "global-chart.prereqCopyHooks" -}}
{{- $root := .root -}}
{{- $out := .out -}}
{{- $scopes := list (dict "hooks" $root.Values.hooks) -}}
{{- range $deployName, $deploy := $root.Values.deployments -}}
  {{- if and $deploy (eq (include "global-chart.deploymentEnabled" $deploy) "true") -}}
    {{- $scopes = append $scopes (dict "hooks" $deploy.hooks "deploy" $deploy "deployName" $deployName) -}}
  {{- end -}}
{{- end -}}
{{- range $scope := $scopes -}}
  {{- range $hookType, $jobs := (default (dict) $scope.hooks) -}}
    {{- if eq (include "global-chart.hookReadsPrereqCopy" $hookType) "true" -}}
      {{- range $jobName, $command := (default (dict) $jobs) -}}
        {{- if $command -}}
          {{- $hook := dict "hookType" $hookType "jobName" $jobName "command" $command -}}
          {{- if $scope.deploy -}}
            {{- $_ := set $hook "deploy" $scope.deploy -}}
            {{- $_ := set $hook "deployName" $scope.deployName -}}
            {{- $_ := set $hook "fullname" (include "global-chart.deploymentHookName" (dict "root" $root "deploymentName" $scope.deployName "hookType" $hookType "jobName" $jobName)) -}}
          {{- else -}}
            {{- $_ := set $hook "fullname" (include "global-chart.hookfullname" (merge (dict "hookname" $hookType "jobname" $jobName) $root)) -}}
          {{- end -}}
          {{- $_ := set $out (include "global-chart.jobValuesPath" (dict "kind" "hook" "deploymentName" (default "" $scope.deployName) "hookType" $hookType "jobName" $jobName)) $hook -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Record that a hook reads the copy under `key`: the one way the consumer scans
fill their result, in the shape minHookWeight reads.
Params: out (key -> hookType -> id -> command, mutated in place) · key ·
hookType · id (the hook's values path) · command.
*/}}
{{- define "global-chart.addPrereqConsumer" -}}
{{- $byType := default (dict) (index .out .key) -}}
{{- $jobsOfType := default (dict) (index $byType .hookType) -}}
{{- $_ := set $jobsOfType .id .command -}}
{{- $_ := set $byType .hookType $jobsOfType -}}
{{- $_ := set .out .key $byType -}}
{{- end -}}

{{/*
The hooks that read the copy of each ExternalSecret, in both scopes: the input of the
ExternalSecret hook-prerequisite copy (ADR 0007), for externalsecret.yaml, which
emits it, and for validateNameCollisions, which registers its names.
Returns JSON: key -> hookType -> values path -> command, the shape
minHookWeight reads, so the copy's weight and phases come from the hooks that
actually read it. A key no such hook references is absent: it gets no copy.
Usage: {{ $consumers := include "global-chart.externalSecretHookConsumers" $root | fromJson }}
*/}}
{{- define "global-chart.externalSecretHookConsumers" -}}
{{- $out := dict -}}
{{- $hooks := dict -}}
{{- include "global-chart.prereqCopyHooks" (dict "root" . "out" $hooks) -}}
{{- range $id, $hook := $hooks -}}
  {{- $refs := include "global-chart.jobExternalSecretRefs" (dict "job" $hook.command "deploy" $hook.deploy) | fromJson -}}
  {{- range $ref := concat $refs.inherited $refs.own -}}
    {{- include "global-chart.addPrereqConsumer" (dict "out" $out "key" $ref.name "hookType" $hook.hookType "id" $id "command" $hook.command) -}}
  {{- end -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{/*
The hooks that read the copy of each rbacs.roles entry, in both scopes: the
input of the rbacs.roles hook-prerequisite copy (ADR 0010), for rbac.yaml,
which emits it, and for validateNameCollisions, which registers its names.
Returns JSON: role name -> hookType -> values path -> command, the shape
minHookWeight reads, as externalSecretHookConsumers does. A role whose SA no
such hook runs as is absent: it gets no copy. Role names are unique
(validateNameCollisions), so the name is a safe key. Which hook reads which
entry is hookRbacCopy's answer, not this scan's.
Usage: {{ $consumers := include "global-chart.rbacHookConsumers" $root | fromJson }}
*/}}
{{- define "global-chart.rbacHookConsumers" -}}
{{- $root := . -}}
{{- $out := dict -}}
{{- if (default (dict) .Values.rbacs).roles -}}
  {{- $hooks := dict -}}
  {{- include "global-chart.prereqCopyHooks" (dict "root" $root "out" $hooks) -}}
  {{- range $id, $hook := $hooks -}}
    {{- $sa := include "global-chart.jobServiceAccount" (dict "root" $root "job" $hook.command "deploy" $hook.deploy "deployName" $hook.deployName "jobFullname" $hook.fullname "errCtx" $id) | fromJson -}}
    {{- $copy := include "global-chart.hookRbacCopy" (dict "root" $root "hookType" $hook.hookType "sa" $sa) | fromJson -}}
    {{- range $roleName := (default (list) $copy.roles) -}}
      {{- include "global-chart.addPrereqConsumer" (dict "out" $out "key" $roleName "hookType" $hook.hookType "id" $id "command" $hook.command) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{/*
The hooks that run as the copy of each ServiceAccount the release creates, in
both scopes: the input of the ServiceAccount hook-prerequisite copy (ADR 0010,
ADR 0011), for hook.yaml, which emits every one of them, and for
validateNameCollisions, which registers their names.
Returns JSON: SA name -> hookType -> values path -> command, the shape
minHookWeight reads, as the scans above. A SA no such hook runs as is absent:
it gets no copy. Which hook runs as which copy is hookReadsServiceAccountCopy's
answer, not this scan's.
Usage: {{ $consumers := include "global-chart.serviceAccountHookConsumers" $root | fromJson }}
*/}}
{{- define "global-chart.serviceAccountHookConsumers" -}}
{{- $root := . -}}
{{- $out := dict -}}
{{- $hooks := dict -}}
{{- include "global-chart.prereqCopyHooks" (dict "root" $root "out" $hooks) -}}
{{- range $id, $hook := $hooks -}}
  {{- $sa := include "global-chart.jobServiceAccount" (dict "root" $root "job" $hook.command "deploy" $hook.deploy "deployName" $hook.deployName "jobFullname" $hook.fullname "errCtx" $id) | fromJson -}}
  {{- if eq (include "global-chart.hookReadsServiceAccountCopy" (dict "root" $root "hookType" $hook.hookType "sa" $sa)) "true" -}}
    {{- include "global-chart.addPrereqConsumer" (dict "out" $out "key" $sa.name "hookType" $hook.hookType "id" $id "command" $hook.command) -}}
  {{- end -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}
