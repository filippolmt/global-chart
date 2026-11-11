{{/*
Shared helper for the hook and cronjob pod spec, in both scopes: the single
implementation behind all four call sites.

Root-level jobs pass no `deploy` (and no `deployName`). That scope simply *is*
the "nothing to inherit from" case: with `deploy` empty every inheritance test fails and each field
resolves to the job's own value — and, for `imagePullSecrets` only, to
`global.imagePullSecrets` after that. No field gains a global fallback it did
not already have. Same widening as `jobServiceAccount`, in
_serviceaccount-helpers.tpl (see ADR 0001).

Inheritance, workload scope. What a job takes from its workload, by values
key; tests/check-inheritance.py holds the schema descriptions and
docs/values-authors/README.md to these three lines (issue #245). Nothing holds
the lines to the code of jobPodSpec: a change to what it inherits edits them.
  inherited: image serviceAccount configMap secret envFromConfigMaps envFromSecrets externalSecrets additionalEnvs imagePullSecrets hostAliases podSecurityContext securityContext automountServiceAccountToken nodeSelector tolerations affinity priorityClassName
  cronjobs only: dnsConfig
  never: command args mountedConfigFiles volumes volumeMounts resources extraInitContainers
An explicit value overrides; an empty `{}`, `[]` or `""` (priorityClassName)
stops the inheritance. A null is unset and inherits, and so does a map whose
keys are all null (nodeSelector, affinity, the security contexts, dnsConfig;
isSetPassthrough, issue #294); resources, never inherited, falls back the same
way to defaults.resources. Four exceptions to that shape:
- envFromConfigMaps / envFromSecrets are additive: the job's own (`[]`
  included) come after the workload's and never replace them. The opt-outs
  are toggles, default true: inheritWorkloadConfigMap /
  inheritWorkloadSecret break the generated ConfigMap/Secret injection, and
  inheritWorkloadEnvFromConfigMaps / inheritWorkloadEnvFromSecrets drop the
  workload's lists (issue #159). They narrow the secret leak surface of a
  narrow-scope job.
- externalSecrets is not an envFrom list here: the job's own replaces the
  inherited one.
- additionalEnvs is additive too, with no opt-out: the job's own env comes
  after the workload's additionalEnvs.
- The envFrom order is by proximity, the workload's by type: see *Environment
  source* in GLOSSARY.md. Locked by an `equal` on the whole list in
  workload_test.yaml and cronjob_test.yaml; a `contains` passes whatever the
  order, which is how the two ends drifted unobserved.
Never inherited:
- command / args: a migration hook inheriting `python -m app.worker` would
  silently run the worker. Locked by regression tests in hook_test.yaml and
  cronjob_test.yaml.
- mountedConfigFiles: they describe the workload's runtime (see *Mounted
  config file* in GLOSSARY.md), and one can carry credentials. A job that needs
  one declares its own volumes / volumeMounts; the generated ConfigMap name is
  not a public interface, so values never hardcode it.
- volumes / volumeMounts: the job renders its own only.
- resources: the job's own, else defaults.resources; a job's `{}` renders
  none (renderResources).
- extraInitContainers: a workload's init container (a wait-for-db, a
  migrator) would run silently inside every job. A job renders its own
  initContainers only, a native sidecar included (issue #262).
- The probes, lifecycle and the rest of the main container's runtime fields:
  a job has no field for them.

Image assembly belongs here too: jobImageSource is resolved once for both the
image and pull policy. An imageString fail names the job's own image or the
workload's image with "(inherited by <job>)"; a missing image names the job.

Accepts a dict with:
  root           - top-level chart context (for global values, defaults)
  job            - the cronjob/hook command map
  kind           - "hook" or "cronjob"; selects the two behaviours that differ
                   between the two (dnsConfig inheritance, and whether an
                   externalSecrets entry reads its hook copy, with hookType).
                   It is the job's kind, NOT its scope: ADR 0001 rejects a
                   `scope` parameter, and this is not one
  deploy         - the parent workload map; omit for root-level jobs
  saName         - pre-resolved ServiceAccount name
  containerName  - name for the container
  configMapRef   - ConfigMap name for envFrom (hooks use hook-config, cronjobs
                   use deploy name); read only when the workload has a
                   ConfigMap, so root-level callers omit it
  secretRef      - same, for the workload's Secret; root-level callers omit it
  hookType       - the hook's phase; hooks only. A hook whose phase
                   hookReadsPrereqCopy names (pre-* except pre-delete, and
                   post-delete) reads the hook-prerequisite copy of every
                   externalSecrets entry, any other job the real Secret
                   (ADR 0007)
  deployName     - the workload key, for the image it inherits and the fail message of an inherited
                   externalSecrets entry; root-level callers omit it
  errCtx         - values path of the job, from jobValuesPath (required):
                   leads the fail messages of its own image, externalSecrets
                   entries, volumes and mounts, and names the job in the
                   "image is required" and jobImageSource fails

The pod-level `automountServiceAccountToken` follows the usual chain: the job's
own value, then the workload's pod-level value, else omitted and the
ServiceAccount decides. The pod field wins over the SA's at admission, so the
workload's value is never carried into an SA the job creates (ADR 0014,
docs/adr/0014-job-pod-automount-follows-the-inheritance-chain.md).
*/}}
{{- define "global-chart.jobPodSpec" -}}
{{- $root := .root -}}
{{- $job := .job -}}
{{- $deploy := default (dict) .deploy -}}
{{- $saName := .saName -}}
{{- /* Resolve once: the image and pull policy must follow the same source. */ -}}
{{- $errCtx := required "jobPodSpec: errCtx is required (build it with jobValuesPath)" .errCtx -}}
{{- $imageSource := include "global-chart.jobImageSource" (dict "root" $root "job" $job "deployName" .deployName "errCtx" $errCtx) | fromJson -}}
{{- $imageRef := "" -}}
{{- if hasKey $imageSource "image" -}}
  {{- $imgCtx := printf "%s.image" $errCtx -}}
  {{- with $imageSource.from -}}{{- $imgCtx = printf "%s.image (inherited by %s)" . $errCtx -}}{{- end -}}
  {{- $imageRef = include "global-chart.imageString" (dict "image" $imageSource.image "global" $root.Values.global "errCtx" $imgCtx) -}}
{{- end -}}
{{- if not $imageRef -}}
  {{- if .deployName -}}
    {{- fail (printf "%s: image is required" $errCtx) -}}
  {{- else -}}
    {{- fail (printf "%s: image is required (set %s.image or %s.fromWorkload)" $errCtx $errCtx $errCtx) -}}
  {{- end -}}
{{- end -}}
{{- $containerName := .containerName -}}
{{- $configMapRef := .configMapRef -}}
{{- $secretRef := .secretRef -}}
{{- /* An unknown kind would silently render as a hook: fail instead, like the
       role table in hookAnnotations (ADR 0004) */ -}}
{{- if not (has .kind (list "hook" "cronjob")) -}}
  {{- fail (printf "jobPodSpec: unknown kind %q for %s (expected \"hook\" or \"cronjob\")" (toString .kind) .containerName) -}}
{{- end -}}
{{- $isCronJob := eq .kind "cronjob" -}}
{{- /* ImagePullSecrets: explicit > inherited from workload > global (isSet distinguishes unset from empty) */ -}}
{{- $imagePullSecrets := list -}}
{{- if eq (include "global-chart.isSet" (list $job "imagePullSecrets")) "true" -}}
  {{- $imagePullSecrets = $job.imagePullSecrets -}}
{{- else if eq (include "global-chart.isSet" (list $deploy "imagePullSecrets")) "true" -}}
  {{- $imagePullSecrets = $deploy.imagePullSecrets -}}
{{- else -}}
  {{- $global := default (dict) $root.Values.global -}}
  {{- $imagePullSecrets = $global.imagePullSecrets -}}
{{- end -}}
{{- with (include "global-chart.renderImagePullSecrets" $imagePullSecrets) }}
{{ . }}
{{- end }}
{{- /* HostAliases: explicit > inherited from workload */ -}}
{{- $hostAliases := ternary $job.hostAliases $deploy.hostAliases (eq (include "global-chart.isSetPassthrough" (list $job "hostAliases")) "true") -}}
{{- with include "global-chart.passthroughYaml" $hostAliases }}
hostAliases:
  {{- . | nindent 2 }}
{{- end }}
{{- /* PodSecurityContext: explicit > inherited from workload */ -}}
{{- $podSecCtx := ternary $job.podSecurityContext $deploy.podSecurityContext (eq (include "global-chart.isSetPassthrough" (list $job "podSecurityContext")) "true") -}}
{{- with include "global-chart.passthroughYaml" $podSecCtx }}
securityContext:
  {{- . | nindent 2 }}
{{- end }}
{{- /* DnsConfig: cronjobs fall back to deploy.dnsConfig, hooks are job-only */ -}}
{{- $dnsConfig := dict -}}
{{- if $isCronJob -}}
  {{- if eq (include "global-chart.isSetPassthrough" (list $job "dnsConfig")) "true" -}}
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
{{- /* InitContainers: the job's own, never the workload's extraInitContainers. validatePodFailurePolicy lists the pod's containers too: a container added here joins it there */ -}}
{{- with include "global-chart.passthroughYaml" $job.initContainers }}
initContainers:
  {{- . | nindent 2 }}
{{- end }}
containers:
- name: {{ $containerName | quote }}
  image: {{ $imageRef | quote }}
  {{- /* The pullPolicy follows the image to wherever it came from: a
         root-level fromWorkload copies the workload's pullPolicy with its
         image (issue #160) */}}
  imagePullPolicy: {{ include "global-chart.imagePullPolicy" (dict "override" $job.imagePullPolicy "image" $imageSource.image) | quote }}
  {{- if $job.command }}
  command:
    {{- toYaml $job.command | nindent 4 }}
  {{- end }}
  {{- if $job.args }}
  args:
    {{- toYaml $job.args | nindent 4 }}
  {{- end }}
  {{- /* Container securityContext: explicit > inherited from workload */ -}}
  {{- $secCtx := ternary $job.securityContext $deploy.securityContext (eq (include "global-chart.isSetPassthrough" (list $job "securityContext")) "true") -}}
  {{- with include "global-chart.passthroughYaml" $secCtx }}
  securityContext:
    {{- . | nindent 4 }}
  {{- end }}
  {{- /* EnvFrom, by proximity: workload's configMap/secret, workload's envFromConfigMaps/envFromSecrets and inherited externalSecrets, then the job's own */ -}}
  {{- /* Opt-out flags, default true, set false to break inheritance:
         inheritWorkloadSecret/inheritWorkloadConfigMap for the generated
         Secret/ConfigMap, inheritWorkloadEnvFromSecrets/-ConfigMaps for the
         workload's envFromSecrets/envFromConfigMaps (issue #159). The job's
         own lists add to what it inherits, they never replace it */ -}}
  {{- $inheritCM := ternary $job.inheritWorkloadConfigMap true (eq (include "global-chart.isSet" (list $job "inheritWorkloadConfigMap")) "true") -}}
  {{- $inheritSec := ternary $job.inheritWorkloadSecret true (eq (include "global-chart.isSet" (list $job "inheritWorkloadSecret")) "true") -}}
  {{- $inheritEnvFromCMs := ternary $job.inheritWorkloadEnvFromConfigMaps true (eq (include "global-chart.isSet" (list $job "inheritWorkloadEnvFromConfigMaps")) "true") -}}
  {{- $inheritEnvFromSecrets := ternary $job.inheritWorkloadEnvFromSecrets true (eq (include "global-chart.isSet" (list $job "inheritWorkloadEnvFromSecrets")) "true") -}}
  {{- $deployEnvFromCMs := ternary $deploy.envFromConfigMaps list $inheritEnvFromCMs -}}
  {{- $deployEnvFromSecrets := ternary $deploy.envFromSecrets list $inheritEnvFromSecrets -}}
  {{- $hasDeployConfigMap := and $inheritCM $deploy.configMap (gt (len $deploy.configMap) 0) -}}
  {{- $hasDeploySecret := and $inheritSec $deploy.secret (gt (len $deploy.secret) 0) -}}
  {{- /* externalSecrets: inherited when the job does not set its own (isSet), and
         split by form — an entry with a mountPath is a volume, any other one an
         envFrom source. Each group keeps its level: proximity, see GLOSSARY.md */ -}}
  {{- $esRefs := include "global-chart.jobExternalSecretRefs" (dict "job" $job "deploy" $deploy) | fromJson -}}
  {{- $esReadsCopy := and (eq .kind "hook") (eq (include "global-chart.hookReadsPrereqCopy" .hookType) "true") -}}
  {{- /* Only one of the two lists is ever non-empty (a job's own replaces the
         inherited one), so checking each against the job's volumes alone is
         enough to catch every volume-name collision */ -}}
  {{- /* Only a workload-scope job inherits: at root level the path is never read */ -}}
  {{- $inheritedCtx := "" -}}
  {{- with .deployName -}}{{- $inheritedCtx = include "global-chart.deploymentValuesPath" . -}}{{- end -}}
  {{- /* Only volumes: a job renders no mountedConfigFiles, so none may count (issue #214) */ -}}
  {{- $podVolumes := include "global-chart.podVolumeNames" (dict "values" (pick $job "volumes") "errCtx" $errCtx) | fromJson -}}
  {{- $esInherited := include "global-chart.resolveExternalSecretRefs" (dict "root" $root "refs" $esRefs.inherited "hook" $esReadsCopy "taken" $podVolumes "errCtx" $inheritedCtx) | fromJson -}}
  {{- $esOwn := include "global-chart.resolveExternalSecretRefs" (dict "root" $root "refs" $esRefs.own "hook" $esReadsCopy "taken" $podVolumes "errCtx" $errCtx) | fromJson -}}
  {{- $esEnvInherited := $esInherited.env -}}
  {{- $esEnvOwn := $esOwn.env -}}
  {{- $esMounted := concat $esInherited.mounted $esOwn.mounted -}}
  {{- $hasEnvFrom := or $hasDeployConfigMap $hasDeploySecret $job.envFromConfigMaps $job.envFromSecrets $deployEnvFromCMs $deployEnvFromSecrets $esEnvInherited $esEnvOwn -}}
  {{- if $hasEnvFrom }}
  envFrom:
    {{- /* The workload's generated ConfigMap (using configMapRef name - differs for hooks vs cronjobs) */ -}}
    {{- if $hasDeployConfigMap }}
    - configMapRef:
        name: {{ $configMapRef | quote }}
    {{- end }}
    {{- /* The workload's generated Secret (using secretRef name - differs for hooks vs cronjobs) */ -}}
    {{- if $hasDeploySecret }}
    - secretRef:
        name: {{ $secretRef | quote }}
    {{- end }}
    {{- /* The workload's external ConfigMaps */ -}}
    {{- range $cm := $deployEnvFromCMs }}
    - configMapRef:
        name: {{ $cm | quote }}
    {{- end }}
    {{- /* The workload's external Secrets */ -}}
    {{- range $sec := $deployEnvFromSecrets }}
    - secretRef:
        name: {{ $sec | quote }}
    {{- end }}
    {{- /* The workload's externalSecrets, inherited */ -}}
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
  {{- /* Env: workload's additionalEnvs + job's env */ -}}
  {{- $envVars := list -}}
  {{- if $deploy.additionalEnvs -}}
    {{- $envVars = $deploy.additionalEnvs -}}
  {{- end -}}
  {{- if $job.env -}}
    {{- $envVars = concat $envVars $job.env -}}
  {{- end -}}
  {{- with include "global-chart.passthroughYaml" $envVars }}
  env:
    {{- . | nindent 4 }}
  {{- end }}
  {{- with (include "global-chart.renderResources" (dict "resources" $job.resources "hasResources" (eq (include "global-chart.isSetPassthrough" (list $job "resources")) "true") "defaults" $root.Values.defaults)) }}
  {{- . | nindent 2 }}
  {{- end }}
  {{- with include "global-chart.passthroughYaml" (include "global-chart.containerVolumeMounts" (dict "errCtx" $errCtx "volumeMounts" $job.volumeMounts "inherited" $esInherited.mounted "inheritedCtx" $inheritedCtx "externalSecrets" $esOwn.mounted) | fromJsonArray) }}
  volumeMounts:
    {{- . | nindent 4 }}
  {{- end }}
{{- if or $job.volumes $esMounted }}
volumes:
  {{- range $i, $v := $job.volumes }}
  {{- include "global-chart.renderVolume" (dict "volume" $v "errCtx" (printf "%s.volumes[%d]" $errCtx $i)) | nindent 2 }}
  {{- end }}
  {{- with $esMounted }}
  {{- include "global-chart.renderExternalSecretVolumes" . | nindent 2 }}
  {{- end }}
{{- end }}
{{- with $saName }}
serviceAccountName: {{ . | quote }}
{{- end }}
{{- /* Pod-level token automount: explicit > inherited from workload > omit (ADR 0014) */ -}}
{{- if eq (include "global-chart.isSet" (list $job "automountServiceAccountToken")) "true" }}
automountServiceAccountToken: {{ $job.automountServiceAccountToken }}
{{- else if eq (include "global-chart.isSet" (list $deploy "automountServiceAccountToken")) "true" }}
automountServiceAccountToken: {{ $deploy.automountServiceAccountToken }}
{{- end }}
{{- /* NodeSelector: explicit > inherited from workload */ -}}
{{- $nodeSelector := ternary $job.nodeSelector $deploy.nodeSelector (eq (include "global-chart.isSetPassthrough" (list $job "nodeSelector")) "true") -}}
{{- with include "global-chart.passthroughYaml" $nodeSelector }}
nodeSelector:
  {{- . | nindent 2 }}
{{- end }}
{{- /* Affinity: explicit > inherited from workload */ -}}
{{- $affinity := ternary $job.affinity $deploy.affinity (eq (include "global-chart.isSetPassthrough" (list $job "affinity")) "true") -}}
{{- with include "global-chart.passthroughYaml" $affinity }}
affinity:
  {{- . | nindent 2 }}
{{- end }}
{{- /* Tolerations: explicit > inherited from workload */ -}}
{{- $tolerations := ternary $job.tolerations $deploy.tolerations (eq (include "global-chart.isSetPassthrough" (list $job "tolerations")) "true") -}}
{{- with include "global-chart.passthroughYaml" $tolerations }}
tolerations:
  {{- . | nindent 2 }}
{{- end }}
{{- /* PriorityClassName: explicit > inherited from workload; "" stops it */ -}}
{{- $priorityClassName := ternary $job.priorityClassName $deploy.priorityClassName (eq (include "global-chart.isSet" (list $job "priorityClassName")) "true") -}}
{{- with $priorityClassName }}
priorityClassName: {{ . | quote }}
{{- end }}
restartPolicy: {{ default "Never" (ternary $job.restartPolicy "" (eq (include "global-chart.isSet" (list $job "restartPolicy")) "true")) | quote }}
{{- end }}

{{/*
The externalSecrets references of a cronjob/hook, split by level: the list the
job inherits from its workload and the one it declares itself. isSet decides,
like every other inheritable field: a job that sets externalSecrets — `[]`
included — inherits none; a null is the key left out (issue #303). Root-level
jobs pass no deploy and inherit nothing.
Returns JSON {inherited: [...], own: [...]}; callers do `include ... | fromJson`.
Usage: {{ include "global-chart.jobExternalSecretRefs" (dict "job" $job "deploy" $deploy) }}
*/}}
{{- define "global-chart.jobExternalSecretRefs" -}}
{{- $job := .job -}}
{{- $deploy := default (dict) .deploy -}}
{{- if eq (include "global-chart.isSet" (list $job "externalSecrets")) "true" -}}
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
  workloads.<d>.hooks.<type>.<name>      workload-scope hook
  workloads.<d>.cronJobs.<name>          workload-scope cronjob
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
{{- if .deploymentName -}}{{ include "global-chart.deploymentValuesPath" .deploymentName }}.{{- end -}}{{- $own -}}
{{- end -}}

{{/*
Choose the image value (a string or a repository/tag map) a cronjob/hook runs:
the one home of the resolution order, read once by jobPodSpec for both the
image and pullPolicy, so the two follow one source (issues #160, #265).
Returns JSON {"image": <value or null>, "from": <entry>}: "from" is the values
path of the workload the image was taken from ("workloads.<name>"), empty
when it is the job's own; fails only on a fromWorkload naming no workload.

Accepts a dict with:
  root    - top-level chart context
  job     - the cronjob/hook command map
  deployName - the parent workload's key (omit for root-level jobs): the
               helper reads the workload from it, and names it in "from"
  errCtx  - values path of the job, from jobValuesPath (required): names the job
            in the failure messages

Resolution order:
  1. explicit job.image (isSet: the schema allows a null, and a null is the
     key left out, issue #303)
  2. workloads[deployName].image (workload-scope: inherit parent; takes precedence
                              so a workload-scope job's fromWorkload is ignored,
                              matching prior behavior)
  3. job.fromWorkload      (root-level only: lookup + fail if missing)
*/}}
{{- define "global-chart.jobImageSource" -}}
{{- $job := .job -}}
{{- $errCtx := required "jobImageSource: errCtx is required (build it with jobValuesPath)" .errCtx -}}
{{- $image := dict -}}
{{- if eq (include "global-chart.isSet" (list $job "image")) "true" -}}
  {{- $image = dict "image" $job.image "from" "" -}}
{{- else if .deployName -}}
  {{- $image = dict "image" (index .root.Values.workloads .deployName).image "from" (include "global-chart.deploymentValuesPath" .deployName) -}}
{{- else if $job.fromWorkload -}}
  {{- $deploy := index (default (dict) .root.Values.workloads) $job.fromWorkload -}}
  {{- if not (include "global-chart.isEntry" $deploy) -}}
    {{- if hasKey (default (dict) .root.Values.workloads) $job.fromWorkload -}}
      {{- fail (printf "%s.fromWorkload: references workload '%s', which is empty: an empty workloads entry renders nothing. Fill the entry, or drop the reference." $errCtx $job.fromWorkload) -}}
    {{- end -}}
    {{- fail (printf "%s.fromWorkload: references workload '%s', which does not exist in .Values.workloads" $errCtx $job.fromWorkload) -}}
  {{- end -}}
  {{- $image = dict "image" $deploy.image "from" (include "global-chart.deploymentValuesPath" $job.fromWorkload) -}}
{{- end -}}
{{- $image | toJson -}}
{{- end -}}

{{/*
The CronJob spec fields between schedule/timeZone and jobTemplate, for both
scopes: one home, so the root and workload-scope CronJobs cannot drift apart.
These are CronJob spec fields, not Job spec fields — jobSpecVerbatimFields
below owns the Job template's. Rendered in this order, each from the job when
it sets the key, else from its default, else not at all. A number is set when
the key is there (hasKey, so 0 is kept and a null fails through printScalar);
suspend and concurrencyPolicy are set through isSet, a null being the key left
out (issue #303), false kept:
- startingDeadlineSeconds — no default
- suspend                 — no default
- concurrencyPolicy       — "Forbid"
- successfulJobsHistoryLimit, failedJobsHistoryLimit — 2 each
Nothing falls back to the workload or global: they describe this schedule.
Every value goes through global-chart.printScalar (issue #132), unquoted:
concurrencyPolicy is a schema enum (Allow/Forbid/Replace), a plain YAML string.
Params: job (the job map) · errCtx (the job's jobValuesPath).
Returns "field: value" lines at indent 0; concurrencyPolicy and the two limits
always render, so it is never empty.
Usage: {{- include "global-chart.cronJobSpecFields" (dict "job" $job "errCtx" $errCtx) | nindent 2 }}
errCtx is the job's jobValuesPath: a null the job sets fails naming its key.
*/}}
{{- define "global-chart.cronJobSpecFields" -}}
{{- $job := .job -}}
{{- $errCtx := required "cronJobSpecFields: errCtx is required (build it with jobValuesPath)" .errCtx -}}
{{- $defaults := dict "concurrencyPolicy" "Forbid" "successfulJobsHistoryLimit" 2 "failedJobsHistoryLimit" 2 -}}
{{- $own := dict
      "startingDeadlineSeconds" (hasKey $job "startingDeadlineSeconds")
      "suspend" (eq (include "global-chart.isSet" (list $job "suspend")) "true")
      "concurrencyPolicy" (eq (include "global-chart.isSet" (list $job "concurrencyPolicy")) "true")
      "successfulJobsHistoryLimit" (hasKey $job "successfulJobsHistoryLimit")
      "failedJobsHistoryLimit" (hasKey $job "failedJobsHistoryLimit") -}}
{{- $lines := list -}}
{{- range (list "startingDeadlineSeconds" "suspend" "concurrencyPolicy" "successfulJobsHistoryLimit" "failedJobsHistoryLimit") -}}
  {{- if or (index $own .) (hasKey $defaults .) -}}
    {{- $value := ternary (index $job .) (index $defaults .) (index $own .) -}}
    {{- $lines = append $lines (printf "%s: %s" . (include "global-chart.printScalar" (dict "value" $value "errCtx" (printf "%s.%s" $errCtx .)))) -}}
  {{- end -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end -}}

{{/*
The Job spec fields a job sets verbatim, for both kinds and both scopes (issue
#113). Each renders only when the job sets it, and nothing falls back to the
workload or global: a retry budget, a deadline or a failure policy is the
job's own.
- The integers (all but podFailurePolicy): hasKey, so 0 is kept, printed
  through global-chart.printScalar (_render-helpers.tpl), the one home of the
  rule for numbers from values: a number read from a values file is a
  float64, and the default format prints it as 1e+07 from a million up, which
  the API server rejects.
- podFailurePolicy (issue #282): a map, rendered with passthroughYaml under
  `with`, so a null is unset like any null map value, and a map of nulls only
  is no podFailurePolicy. The API server accepts it only beside
  restartPolicy Never, so OnFailure fails here naming the path; restartPolicy
  is never inherited, so the job's own value is the whole check. The two
  onExitCodes rules the schema cannot express fail here too (issue #285):
  validatePodFailurePolicy below.
The table below is the template-side home of which kind admits which field, so
the two scopes of a kind can no longer drift apart. The schema mirrors it —
cronJobSpec and hookJobSpec declare the same lists, and they are what rejects
a field a kind does not admit:
- cronjob: all six.
- hook: activeDeadlineSeconds and backoffLimit only. Not podFailurePolicy
  (issue #282): the default backoffLimit of 6 already absorbs a preemption,
  and no hook has needed more; a hook with backoffLimit 0 on Spot nodes is the
  case that would add it. Not ttlSecondsAfterFinished:
  a completed hook Job is kept as the record of what ran (the role table in _hook-helpers.tpl),
  and a TTL controller deleting it races before-hook-creation — deletePolicy
  hook-succeeded already covers cleanup. Not parallelism/completions: a hook is
  one run.
Params: job (the job map) · kind ("hook" | "cronjob") · errCtx (the job's
jobValuesPath: a null fails naming its key) · containerName (cronjob only:
the main container's name, the job's key, for validatePodFailurePolicy).
Returns the fields as YAML at indent 0, one "field: value" line per integer
and a block for podFailurePolicy, or "" when none is set.
Usage: {{- with (include "global-chart.jobSpecVerbatimFields" (dict "job" $job "kind" "hook" "errCtx" $errCtx)) }}
*/}}
{{- define "global-chart.jobSpecVerbatimFields" -}}
{{- $fields := dict
    "cronjob" (list "backoffLimit" "ttlSecondsAfterFinished" "activeDeadlineSeconds" "parallelism" "completions" "podFailurePolicy")
    "hook" (list "activeDeadlineSeconds" "backoffLimit") -}}
{{- $job := .job -}}
{{- $errCtx := required "jobSpecVerbatimFields: errCtx is required (build it with jobValuesPath)" .errCtx -}}
{{- $lines := list -}}
{{- range (required (printf "jobSpecVerbatimFields: unknown kind %q" (toString .kind)) (get $fields (toString .kind))) -}}
  {{- if eq . "podFailurePolicy" -}}
    {{- with include "global-chart.passthroughYaml" $job.podFailurePolicy -}}
      {{- if eq (toString $job.restartPolicy) "OnFailure" -}}
        {{- fail (printf "%s.podFailurePolicy: requires restartPolicy Never, not OnFailure" $errCtx) -}}
      {{- end -}}
      {{- include "global-chart.validatePodFailurePolicy" (dict "job" $job "containerName" (required "jobSpecVerbatimFields: containerName is required for a cronjob" $.containerName) "errCtx" $errCtx) -}}
      {{- $lines = append $lines (printf "podFailurePolicy:\n%s" (. | indent 2)) -}}
    {{- end -}}
  {{- else if hasKey $job . -}}
    {{- $lines = append $lines (printf "%s: %s" . (include "global-chart.printScalar" (dict "value" (index $job .) "errCtx" (printf "%s.%s" $errCtx .)))) -}}
  {{- end -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end -}}

{{/*
Validate a cronjob's podFailurePolicy onExitCodes as the API server does
(issue #285). The schema cannot express either rule, and the API server
refused both only at apply:
- values in strictly ascending order. uniqueItems already rejects a repeat,
  so this is its fallback under --skip-schema-validation;
- containerName naming a container of the Job's pod: the main container,
  named after the job's key, or one of the job's own initContainers. The same
  set jobPodSpec renders: a container it adds to the pod joins it here. The
  message lists them: a values author cannot know the main container takes
  the job's key.
A null exit code, a null initContainers name and a null initContainers item
fail naming their path (rejectNullItems). A rule, an onExitCodes or a list
that is not of its type is skipped, and so is a string exit code: the schema
rejects them.
Called from jobSpecVerbatimFields. Emits nothing on success.
Usage: {{- include "global-chart.validatePodFailurePolicy" (dict "job" $job "containerName" $name "errCtx" $errCtx) }}
*/}}
{{- define "global-chart.validatePodFailurePolicy" -}}
{{- $path := printf "%s.podFailurePolicy" .errCtx -}}
{{- $initList := (kindIs "slice" .job.initContainers | ternary .job.initContainers list) -}}
{{- include "global-chart.rejectNullItems" (dict "list" $initList "errCtx" (printf "%s.initContainers" .errCtx) "required" (list "name")) -}}
{{- $inits := list -}}
{{- range $initList -}}
  {{- if include "global-chart.isNamedEntry" . -}}
    {{- $inits = append $inits .name -}}
  {{- end -}}
{{- end -}}
{{- $names := prepend $inits .containerName -}}
{{- $known := printf "'%s' (the job's key)" .containerName -}}
{{- if $inits -}}
  {{- $known = printf "%s, '%s' (initContainers)" $known (join "', '" $inits) -}}
{{- end -}}
{{- $rules := .job.podFailurePolicy.rules -}}
{{- range $r, $rule := (kindIs "slice" $rules | ternary $rules list) -}}
  {{- $codes := (kindIs "map" $rule | ternary $rule dict).onExitCodes -}}
  {{- if kindIs "map" $codes -}}
    {{- $at := printf "%s.rules[%d].onExitCodes" $path $r -}}
    {{- $values := (kindIs "slice" $codes.values | ternary $codes.values list) -}}
    {{- include "global-chart.rejectNullItems" (dict "list" $values "errCtx" (printf "%s.values" $at)) -}}
    {{- range $i, $v := $values -}}
      {{- $prev := index $values (max 0 (sub $i 1)) -}}
      {{- if and $i (not (kindIs "string" $prev)) (not (kindIs "string" $v)) (le (float64 $v) (float64 $prev)) -}}
        {{- $printed := list -}}
        {{- range $values -}}
          {{- $printed = append $printed (include "global-chart.printScalar" .) -}}
        {{- end -}}
        {{- fail (printf "%s.values: [%s] is not in ascending order, which the API server rejects. List the exit codes from lowest to highest." $at (join ", " $printed)) -}}
      {{- end -}}
    {{- end -}}
    {{- if and (kindIs "string" $codes.containerName) (not (has $codes.containerName $names)) -}}
      {{- fail (printf "%s.containerName: '%s' names no container of the job's pod, which the API server rejects. The pod's containers: %s." $at $codes.containerName $known) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}
