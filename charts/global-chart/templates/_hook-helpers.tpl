{{/*
Hook lifecycle helpers for global-chart.

Single home for the three "helm.sh/hook*" annotations: the effective weight,
the ordering invariant prereq (w-7) < SA (w-5) < Job (w), and the delete
policy per role. See docs/adr/0004-one-module-for-hook-lifecycle-annotations.md.
Also the home of which hooks the ExternalSecret hook-prerequisite copy serves:
the phase predicate and the consumer scan that decide when the copy exists and
who reads it (ADR 0007).
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
Whether a hook of this phase reads the ExternalSecret hook-prerequisite copy
rather than the real Secret: "true" for a pre-* phase, which runs before the
real ExternalSecret is applied, and for post-delete, which runs after it — and,
through its ownerReference, its Secret — is gone. Every other phase finds the
real Secret in place. The ONE place the cut is made — the consumer
scan below (which emits the copy) and jobPodSpec (which points the hook at it)
both ask here, so a hook can never read a copy that was not rendered.
Usage: {{ include "global-chart.hookReadsExternalSecretCopy" $hookType }}
*/}}
{{- define "global-chart.hookReadsExternalSecretCopy" -}}
{{- or (hasPrefix "pre-" (toString .)) (eq (toString .) "post-delete") -}}
{{- end -}}

{{/*
The hooks that read the copy of each ExternalSecret, in both scopes: the input of the
ExternalSecret hook-prerequisite copy (ADR 0007), for externalsecret.yaml, which
emits it, and for validateNameCollisions, which registers its names.
Returns JSON: key -> hookType -> "<scope>/<job>" -> command, the shape
minHookWeight reads, so the copy's weight and phases come from the hooks that
actually read it. A key no such hook references is absent: it gets no copy.
Only the phases hookReadsExternalSecretCopy names; a hook of any other phase
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
    {{- if eq (include "global-chart.hookReadsExternalSecretCopy" $hookType) "true" -}}
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
