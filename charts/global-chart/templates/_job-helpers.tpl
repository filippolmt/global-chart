{{/*
Shared helper for the hook and cronjob pod spec, in both scopes: the single
implementation behind all four call sites.

Root-level jobs pass no `deploy`. That scope simply *is* the "nothing to inherit
from" case: with `deploy` empty every inheritance test fails and each field
resolves to the job's own value — and, for `imagePullSecrets` only, to
`global.imagePullSecrets` after that. No field gains a global fallback it did
not already have. Same widening as `jobServiceAccount`, in
_serviceaccount-helpers.tpl (see ADR 0001).

Accepts a dict with:
  root           - top-level chart context (for global values, defaults)
  job            - the cronjob/hook command map
  kind           - "hook" or "cronjob"; selects the two behaviours that differ
                   between the two (dnsConfig inheritance and initContainers).
                   It is the job's kind, NOT its scope: ADR 0001 rejects a
                   `scope` parameter, and this is not one
  deploy         - the parent deployment map; omit for root-level jobs
  saName         - pre-resolved ServiceAccount name
  imageRef       - pre-resolved image string
  containerName  - name for the container
  configMapRef   - ConfigMap name for envFrom (hooks use hook-config, cronjobs
                   use deploy name); read only when the deployment has a
                   ConfigMap, so root-level callers omit it
  secretRef      - same, for the deployment's Secret; root-level callers omit it
  hookType       - the hook's phase; hooks only. A hook whose phase
                   hookReadsPrereqCopy names (pre-* except pre-delete, and
                   post-delete) reads the hook-prerequisite copy of every
                   externalSecrets entry, any other job the real Secret
                   (ADR 0007)
  deployName     - the deployment key, for the fail message of an inherited
                   externalSecrets entry; root-level callers omit it
  errCtx         - values path of the job, for the fail message of its own
                   externalSecrets entries

The pod-level `automountServiceAccountToken` follows the usual chain: the job's
own value, then the deployment's pod-level value, else omitted and the
ServiceAccount decides. The pod field wins over the SA's at admission, so the
deployment's value is never carried into an SA the job creates (ADR 0014,
docs/adr/0014-job-pod-automount-follows-the-inheritance-chain.md).
*/}}
{{- define "global-chart.jobPodSpec" -}}
{{- $root := .root -}}
{{- $job := .job -}}
{{- $deploy := default (dict) .deploy -}}
{{- $saName := .saName -}}
{{- $imageRef := .imageRef -}}
{{- $containerName := .containerName -}}
{{- $configMapRef := .configMapRef -}}
{{- $secretRef := .secretRef -}}
{{- /* An unknown kind would silently render as a hook: fail instead, like the
       role table in hookAnnotations (ADR 0004) */ -}}
{{- if not (has .kind (list "hook" "cronjob")) -}}
  {{- fail (printf "jobPodSpec: unknown kind %q for %s (expected \"hook\" or \"cronjob\")" (toString .kind) .containerName) -}}
{{- end -}}
{{- $isCronJob := eq .kind "cronjob" -}}
{{- /* ImagePullSecrets: explicit > inherited from deployment > global (hasKey distinguishes unset from empty) */ -}}
{{- $imagePullSecrets := list -}}
{{- if hasKey $job "imagePullSecrets" -}}
  {{- $imagePullSecrets = $job.imagePullSecrets -}}
{{- else if hasKey $deploy "imagePullSecrets" -}}
  {{- $imagePullSecrets = $deploy.imagePullSecrets -}}
{{- else -}}
  {{- $global := default (dict) $root.Values.global -}}
  {{- $imagePullSecrets = $global.imagePullSecrets -}}
{{- end -}}
{{- with (include "global-chart.renderImagePullSecrets" $imagePullSecrets) }}
{{ . }}
{{- end }}
{{- /* HostAliases: explicit > inherited from deployment */ -}}
{{- $hostAliases := ternary $job.hostAliases $deploy.hostAliases (hasKey $job "hostAliases") -}}
{{- with $hostAliases }}
hostAliases:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- /* PodSecurityContext: explicit > inherited from deployment */ -}}
{{- $podSecCtx := ternary $job.podSecurityContext $deploy.podSecurityContext (hasKey $job "podSecurityContext") -}}
{{- with $podSecCtx }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- /* DnsConfig: cronjobs fall back to deploy.dnsConfig, hooks are job-only */ -}}
{{- $dnsConfig := dict -}}
{{- if $isCronJob -}}
  {{- if hasKey $job "dnsConfig" -}}
    {{- $dnsConfig = default (dict) $job.dnsConfig -}}
  {{- else -}}
    {{- $dnsConfig = default (dict) $deploy.dnsConfig -}}
  {{- end -}}
{{- else -}}
  {{- $dnsConfig = default (dict) $job.dnsConfig -}}
{{- end -}}
{{- with (include "global-chart.renderDnsConfig" $dnsConfig) }}
{{ . }}
{{- end }}
{{- /* InitContainers: only for cronjobs */ -}}
{{- if and $isCronJob $job.initContainers }}
initContainers:
  {{- toYaml $job.initContainers | nindent 2 }}
{{- end }}
containers:
- name: {{ $containerName }}
  image: {{ $imageRef | quote }}
  imagePullPolicy: {{ include "global-chart.imagePullPolicy" (dict "override" $job.imagePullPolicy "image" (default $deploy.image $job.image)) | quote }}
  {{- if $job.command }}
  command:
    {{- toYaml $job.command | nindent 4 }}
  {{- end }}
  {{- if $job.args }}
  args:
    {{- toYaml $job.args | nindent 4 }}
  {{- end }}
  {{- /* Container securityContext: explicit > inherited from deployment */ -}}
  {{- $secCtx := ternary $job.securityContext $deploy.securityContext (hasKey $job "securityContext") -}}
  {{- with $secCtx }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- /* EnvFrom: deployment's configMap/secret + explicit envFromConfigMaps/envFromSecrets + deployment's envFromConfigMaps/envFromSecrets */ -}}
  {{- /* Opt-out flags, default true, set false to break inheritance:
         inheritDeploymentSecret/inheritDeploymentConfigMap for the generated
         Secret/ConfigMap, inheritDeploymentEnvFromSecrets/-ConfigMaps for the
         deployment's envFromSecrets/envFromConfigMaps (issue #159). The job's
         own lists add to what it inherits, they never replace it */ -}}
  {{- $inheritCM := ternary $job.inheritDeploymentConfigMap true (hasKey $job "inheritDeploymentConfigMap") -}}
  {{- $inheritSec := ternary $job.inheritDeploymentSecret true (hasKey $job "inheritDeploymentSecret") -}}
  {{- $deployEnvFromCMs := ternary $job.inheritDeploymentEnvFromConfigMaps true (hasKey $job "inheritDeploymentEnvFromConfigMaps") | ternary $deploy.envFromConfigMaps list -}}
  {{- $deployEnvFromSecrets := ternary $job.inheritDeploymentEnvFromSecrets true (hasKey $job "inheritDeploymentEnvFromSecrets") | ternary $deploy.envFromSecrets list -}}
  {{- $hasDeployConfigMap := and $inheritCM $deploy.configMap (gt (len $deploy.configMap) 0) -}}
  {{- $hasDeploySecret := and $inheritSec $deploy.secret (gt (len $deploy.secret) 0) -}}
  {{- /* externalSecrets: inherited when the job does not set its own (hasKey), and
         split by form — an entry with a mountPath is a volume, any other one an
         envFrom source. Each group keeps its level: proximity, see CONTEXT.md */ -}}
  {{- $esRefs := include "global-chart.jobExternalSecretRefs" (dict "job" $job "deploy" $deploy) | fromJson -}}
  {{- $esReadsCopy := and (eq .kind "hook") (eq (include "global-chart.hookReadsPrereqCopy" .hookType) "true") -}}
  {{- /* Only one of the two lists is ever non-empty (a job's own replaces the
         inherited one), so checking each against the job's volumes alone is
         enough to catch every volume-name collision */ -}}
  {{- $esInherited := include "global-chart.resolveExternalSecretRefs" (dict "root" $root "refs" $esRefs.inherited "hook" $esReadsCopy "volumes" $job.volumes "errCtx" (printf "deployments.%s" (toString .deployName))) | fromJson -}}
  {{- $esOwn := include "global-chart.resolveExternalSecretRefs" (dict "root" $root "refs" $esRefs.own "hook" $esReadsCopy "volumes" $job.volumes "errCtx" .errCtx) | fromJson -}}
  {{- $esEnvInherited := $esInherited.env -}}
  {{- $esEnvOwn := $esOwn.env -}}
  {{- $esMounted := concat $esInherited.mounted $esOwn.mounted -}}
  {{- $hasEnvFrom := or $hasDeployConfigMap $hasDeploySecret $job.envFromConfigMaps $job.envFromSecrets $deployEnvFromCMs $deployEnvFromSecrets $esEnvInherited $esEnvOwn -}}
  {{- if $hasEnvFrom }}
  envFrom:
    {{- /* Deployment's generated ConfigMap (using configMapRef name - differs for hooks vs cronjobs) */ -}}
    {{- if $hasDeployConfigMap }}
    - configMapRef:
        name: {{ $configMapRef | quote }}
    {{- end }}
    {{- /* Deployment's generated Secret (using secretRef name - differs for hooks vs cronjobs) */ -}}
    {{- if $hasDeploySecret }}
    - secretRef:
        name: {{ $secretRef | quote }}
    {{- end }}
    {{- /* Deployment's external ConfigMaps */ -}}
    {{- range $cm := $deployEnvFromCMs }}
    - configMapRef:
        name: {{ $cm | quote }}
    {{- end }}
    {{- /* Deployment's external Secrets */ -}}
    {{- range $sec := $deployEnvFromSecrets }}
    - secretRef:
        name: {{ $sec | quote }}
    {{- end }}
    {{- /* Deployment's externalSecrets, inherited */ -}}
    {{- range $esEnvInherited }}
    - secretRef:
        name: {{ . | quote }}
    {{- end }}
    {{- /* Job's explicit external ConfigMaps */ -}}
    {{- range $cm := $job.envFromConfigMaps }}
    - configMapRef:
        name: {{ $cm | quote }}
    {{- end }}
    {{- /* Job's explicit external Secrets */ -}}
    {{- range $sec := $job.envFromSecrets }}
    - secretRef:
        name: {{ $sec | quote }}
    {{- end }}
    {{- /* Job's own externalSecrets */ -}}
    {{- range $esEnvOwn }}
    - secretRef:
        name: {{ . | quote }}
    {{- end }}
  {{- end }}
  {{- /* Env: deployment's additionalEnvs + job's env */ -}}
  {{- $envVars := list -}}
  {{- if $deploy.additionalEnvs -}}
    {{- $envVars = $deploy.additionalEnvs -}}
  {{- end -}}
  {{- if $job.env -}}
    {{- $envVars = concat $envVars $job.env -}}
  {{- end -}}
  {{- if $envVars }}
  env:
    {{- toYaml $envVars | nindent 4 }}
  {{- end }}
  {{- with (include "global-chart.renderResources" (dict "resources" $job.resources "hasResources" (hasKey $job "resources") "defaults" $root.Values.defaults)) }}
  {{- . | nindent 2 }}
  {{- end }}
  {{- if or $job.volumeMounts $esMounted }}
  volumeMounts:
    {{- with $job.volumeMounts }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
    {{- with $esMounted }}
    {{- include "global-chart.renderExternalSecretVolumeMounts" . | nindent 4 }}
    {{- end }}
  {{- end }}
{{- if or $job.volumes $esMounted }}
volumes:
  {{- range $job.volumes }}
  {{- include "global-chart.renderVolume" . | nindent 2 }}
  {{- end }}
  {{- with $esMounted }}
  {{- include "global-chart.renderExternalSecretVolumes" . | nindent 2 }}
  {{- end }}
{{- end }}
{{- with $saName }}
serviceAccountName: {{ . | quote }}
{{- end }}
{{- /* Pod-level token automount: explicit > inherited from deployment > omit (ADR 0014) */ -}}
{{- if hasKey $job "automountServiceAccountToken" }}
automountServiceAccountToken: {{ $job.automountServiceAccountToken }}
{{- else if hasKey $deploy "automountServiceAccountToken" }}
automountServiceAccountToken: {{ $deploy.automountServiceAccountToken }}
{{- end }}
{{- /* NodeSelector: explicit > inherited from deployment */ -}}
{{- $nodeSelector := ternary $job.nodeSelector $deploy.nodeSelector (hasKey $job "nodeSelector") -}}
{{- with $nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- /* Affinity: explicit > inherited from deployment */ -}}
{{- $affinity := ternary $job.affinity $deploy.affinity (hasKey $job "affinity") -}}
{{- with $affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- /* Tolerations: explicit > inherited from deployment */ -}}
{{- $tolerations := ternary $job.tolerations $deploy.tolerations (hasKey $job "tolerations") -}}
{{- with $tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
restartPolicy: {{ default "Never" (ternary $job.restartPolicy "" (hasKey $job "restartPolicy")) | quote }}
{{- end }}

{{/*
The externalSecrets references of a cronjob/hook, split by level: the list the
job inherits from its deployment and the one it declares itself. hasKey decides,
like every other inheritable field: a job that sets externalSecrets — `[]`
included — inherits none. Root-level jobs pass no deploy and inherit nothing.
Returns JSON {inherited: [...], own: [...]}; callers do `include ... | fromJson`.
Usage: {{ include "global-chart.jobExternalSecretRefs" (dict "job" $job "deploy" $deploy) }}
*/}}
{{- define "global-chart.jobExternalSecretRefs" -}}
{{- $job := .job -}}
{{- $deploy := default (dict) .deploy -}}
{{- if hasKey $job "externalSecrets" -}}
{{- dict "inherited" (list) "own" (default (list) $job.externalSecrets) | toJson -}}
{{- else -}}
{{- dict "inherited" (default (list) $deploy.externalSecrets) "own" (list) | toJson -}}
{{- end -}}
{{- end -}}

{{/*
The values path of a hook or cronjob, both scopes: the one name a job carries in
every error message the chart emits about it (issue #133 review). Each call
site used to rebuild it with its own printf, and a job reported by two paths —
resolver, render and validator — could be named two ways.
  hooks.<type>.<name>                      root-level hook
  cronJobs.<name>                          root-level cronjob
  deployments.<d>.hooks.<type>.<name>      deployment-level hook
  deployments.<d>.cronJobs.<name>          deployment-level cronjob
Bind it once per job (`$errCtx`) and reuse it; never printf the path inline.
Params: kind ("hook" | "cronjob") · deploymentName (omit or "" at root level) ·
hookType (hooks only) · jobName (the job's key) — the same names as
deploymentHookName and deploymentCronJobName (_helpers.tpl), which take the
same job.
*/}}
{{- define "global-chart.jobValuesPath" -}}
{{- $own := "" -}}
{{- if eq .kind "hook" -}}
  {{- $own = printf "hooks.%s.%s" .hookType .jobName -}}
{{- else if eq .kind "cronjob" -}}
  {{- $own = printf "cronJobs.%s" .jobName -}}
{{- else -}}
  {{- fail (printf "jobValuesPath: unknown kind %q for %s (expected \"hook\" or \"cronjob\")" (toString .kind) (toString .jobName)) -}}
{{- end -}}
{{- if .deploymentName -}}deployments.{{ .deploymentName }}.{{- end -}}{{- $own -}}
{{- end -}}

{{/*
Resolve the image string for a cronjob/hook command, unifying the choice across
root-level and deployment-level jobs. Returns the image string, and fails when
none resolves: the one home of the "image is required" message, which callers
used to spell out each with its own printf.

Accepts a dict with:
  root    - top-level chart context
  job     - the cronjob/hook command map
  deploy  - the parent deployment map (omit/nil for root-level jobs)
  errCtx  - values path of the job, from jobValuesPath (required): names the job
            in the failure messages

Resolution order:
  1. explicit job.image
  2. deploy.image            (deployment-level: inherit parent; takes precedence
                              so a deployment-level job's fromDeployment is ignored,
                              matching prior behavior)
  3. job.fromDeployment      (root-level only: lookup + fail if missing)
*/}}
{{- define "global-chart.jobImageString" -}}
{{- $root := .root -}}
{{- $job := .job -}}
{{- $deploy := .deploy -}}
{{- $errCtx := required "jobImageString: errCtx is required (build it with jobValuesPath)" .errCtx -}}
{{- $global := $root.Values.global -}}
{{- $img := "" -}}
{{- if hasKey $job "image" -}}
  {{- $img = include "global-chart.imageString" (dict "image" $job.image "global" $global) -}}
{{- else if $deploy -}}
  {{- $img = include "global-chart.imageString" (dict "image" $deploy.image "global" $global) -}}
{{- else if $job.fromDeployment -}}
  {{- $dep := index $root.Values.deployments $job.fromDeployment -}}
  {{- if not $dep -}}
    {{- fail (printf "%s.fromDeployment references deployment '%s' which does not exist in .Values.deployments" $errCtx $job.fromDeployment) -}}
  {{- end -}}
  {{- $img = include "global-chart.imageString" (dict "image" $dep.image "global" $global) -}}
{{- end -}}
{{- if not $img -}}
  {{- if $deploy -}}
    {{- fail (printf "image is required for %s" $errCtx) -}}
  {{- else -}}
    {{- fail (printf "image is required for %s (set %s.image or %s.fromDeployment)" $errCtx $errCtx $errCtx) -}}
  {{- end -}}
{{- end -}}
{{- $img -}}
{{- end -}}

{{/*
The CronJob spec fields between schedule/timeZone and jobTemplate, for both
scopes: one home, so the root and deployment-level CronJobs cannot drift apart.
These are CronJob spec fields, not Job spec fields — jobSpecVerbatimFields
below owns the Job template's. Rendered in this order, each from the job when
it sets the key (hasKey, so 0 and false are kept), else from its default, else
not at all:
- startingDeadlineSeconds — no default
- suspend                 — no default
- concurrencyPolicy       — "Forbid"
- successfulJobsHistoryLimit, failedJobsHistoryLimit — 2 each
Nothing falls back to the deployment or global: they describe this schedule.
Every value goes through global-chart.printScalar (issue #132), unquoted:
concurrencyPolicy is a schema enum (Allow/Forbid/Replace), a plain YAML string.
Params: the job map.
Returns "field: value" lines at indent 0; concurrencyPolicy and the two limits
always render, so it is never empty.
Usage: {{- include "global-chart.cronJobSpecFields" $job | nindent 2 }}
*/}}
{{- define "global-chart.cronJobSpecFields" -}}
{{- $job := . -}}
{{- $defaults := dict "concurrencyPolicy" "Forbid" "successfulJobsHistoryLimit" 2 "failedJobsHistoryLimit" 2 -}}
{{- $lines := list -}}
{{- range (list "startingDeadlineSeconds" "suspend" "concurrencyPolicy" "successfulJobsHistoryLimit" "failedJobsHistoryLimit") -}}
  {{- if or (hasKey $job .) (hasKey $defaults .) -}}
    {{- $value := ternary (index $job .) (index $defaults .) (hasKey $job .) -}}
    {{- $lines = append $lines (printf "%s: %s" . (include "global-chart.printScalar" $value)) -}}
  {{- end -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end -}}

{{/*
The Job spec fields a job sets verbatim, for both kinds and both scopes (issue
#113). Each renders only when the job sets it — hasKey, so 0 is kept — and
nothing falls back to the deployment or global: a retry budget or a deadline is
the job's own. Every field is an integer, printed through
global-chart.printScalar (_render-helpers.tpl), the one home of the rule for
numbers from values: a
number read from a values file is a float64, and the default format prints it
as 1e+07 from a million up, which the API server rejects.
The table below is the template-side home of which kind admits which field, so
the two scopes of a kind can no longer drift apart. The schema mirrors it —
cronJobSpec and hookJobSpec declare the same lists, and they are what rejects
a field a kind does not admit:
- cronjob: all five.
- hook: activeDeadlineSeconds and backoffLimit only. Not ttlSecondsAfterFinished:
  a completed hook Job is kept as the record of what ran (CLAUDE.md pattern 8),
  and a TTL controller deleting it races before-hook-creation — deletePolicy
  hook-succeeded already covers cleanup. Not parallelism/completions: a hook is
  one run.
Params: job (the job map) · kind ("hook" | "cronjob").
Returns "field: value" lines at indent 0, or "" when none is set.
Usage: {{- with (include "global-chart.jobSpecVerbatimFields" (dict "job" $job "kind" "hook")) }}
*/}}
{{- define "global-chart.jobSpecVerbatimFields" -}}
{{- $fields := dict
    "cronjob" (list "backoffLimit" "ttlSecondsAfterFinished" "activeDeadlineSeconds" "parallelism" "completions")
    "hook" (list "activeDeadlineSeconds" "backoffLimit") -}}
{{- $job := .job -}}
{{- $lines := list -}}
{{- range (required (printf "jobSpecVerbatimFields: unknown kind %q" (toString .kind)) (get $fields (toString .kind))) -}}
  {{- if hasKey $job . -}}
    {{- $lines = append $lines (printf "%s: %s" . (include "global-chart.printScalar" (index $job .))) -}}
  {{- end -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end -}}
