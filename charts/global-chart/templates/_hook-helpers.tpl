{{/*
Hook lifecycle helpers for global-chart.

Single home for the three "helm.sh/hook*" annotations: the effective weight,
the ordering invariant prereq (w-7) < SA (w-5) < Job (w), and the delete
policy per role. See docs/adr/0004-one-module-for-hook-lifecycle-annotations.md.
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
             rather than one hook's own; overrides command
Usage:
  {{- include "global-chart.hookAnnotations" (dict "hookType" $hookType "role" "job" "command" $command) | nindent 4 }}
*/}}
{{- define "global-chart.hookAnnotations" -}}
{{- $command := default (dict) .command -}}
{{- $weight := int (ternary .weight (include "global-chart.effectiveHookWeight" $command) (hasKey . "weight")) -}}
{{- /* Role table: offset from the Job weight, and default delete policy. */ -}}
{{- $table := dict
      "job"            (dict "offset" 0  "policy" "before-hook-creation")
      "sa"             (dict "offset" -5 "policy" "before-hook-creation,hook-succeeded")
      "prereq"         (dict "offset" -7 "policy" "before-hook-creation,hook-succeeded")
      "pre-install-sa" (dict "offset" -5 "policy" "hook-succeeded,hook-failed") -}}
{{- $row := index $table .role -}}
{{- /* An explicit deletePolicy belongs to the hook, so it reaches only the roles
       a hook owns — the plumbing roles are called with a weight and no command.
       The prereq copies are shared by every hook of the deployment, so the
       choice would have no owner, and the pre-install SA copy cannot take
       before-hook-creation without deleting a live SA mid-upgrade (ADR 0002). */ -}}
{{- $policy := ternary $command.deletePolicy $row.policy (hasKey $command "deletePolicy") -}}
{{- /* Derived weights are never floored at 0: Helm allows negative hook weights,
       and clamping a prereq to 0 would sort it AFTER a Job with a negative
       weight — the exact ordering failure this invariant exists to prevent. */ -}}
"helm.sh/hook": {{ .hookType | quote }}
"helm.sh/hook-weight": {{ add $weight $row.offset | quote }}
"helm.sh/hook-delete-policy": {{ $policy | quote }}
{{- end -}}
