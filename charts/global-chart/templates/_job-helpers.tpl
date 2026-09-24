{{/*
Shared helper for the hook and cronjob pod spec, in both scopes: the single
implementation behind all four call sites.

Root-level jobs pass no `deploy`. That scope simply *is* the "nothing to inherit
from" case: with `deploy` empty every inheritance test fails and each field
resolves to the job's own value — and, for `imagePullSecrets` only, to
`global.imagePullSecrets` after that. No field gains a global fallback it did
not already have. Same widening as `jobServiceAccount` (see ADR 0001).

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
  hookType       - the hook's phase; hooks only. A pre-* hook reads the
                   hook-prerequisite copy of every externalSecrets entry, any
                   other job the real Secret (ADR 0007)
  deployName     - the deployment key, for the fail message of an inherited
                   externalSecrets entry; root-level callers omit it
  errCtx         - values path of the job, for the fail message of its own
                   externalSecrets entries
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
  {{- /* Opt-out flags: inheritDeploymentSecret/inheritDeploymentConfigMap default true, set false to break inheritance */ -}}
  {{- $inheritCM := ternary $job.inheritDeploymentConfigMap true (hasKey $job "inheritDeploymentConfigMap") -}}
  {{- $inheritSec := ternary $job.inheritDeploymentSecret true (hasKey $job "inheritDeploymentSecret") -}}
  {{- $hasDeployConfigMap := and $inheritCM $deploy.configMap (gt (len $deploy.configMap) 0) -}}
  {{- $hasDeploySecret := and $inheritSec $deploy.secret (gt (len $deploy.secret) 0) -}}
  {{- /* externalSecrets: inherited when the job does not set its own (hasKey), and
         split by form — an entry with a mountPath is a volume, any other one an
         envFrom source. Each group keeps its level: proximity, see CONTEXT.md */ -}}
  {{- $esRefs := include "global-chart.jobExternalSecretRefs" (dict "job" $job "deploy" $deploy) | fromJson -}}
  {{- $esReadsCopy := and (eq .kind "hook") (eq (include "global-chart.hookReadsExternalSecretCopy" .hookType) "true") -}}
  {{- $esInherited := include "global-chart.resolveExternalSecretRefs" (dict "root" $root "refs" $esRefs.inherited "hook" $esReadsCopy "errCtx" (printf "deployments.%s" (toString .deployName))) | fromJsonArray -}}
  {{- $esOwn := include "global-chart.resolveExternalSecretRefs" (dict "root" $root "refs" $esRefs.own "hook" $esReadsCopy "errCtx" .errCtx) | fromJsonArray -}}
  {{- $esEnvInherited := list -}}
  {{- $esEnvOwn := list -}}
  {{- $esMounted := list -}}
  {{- range $esInherited -}}
    {{- if .mountPath -}}{{- $esMounted = append $esMounted . -}}{{- else -}}{{- $esEnvInherited = append $esEnvInherited . -}}{{- end -}}
  {{- end -}}
  {{- range $esOwn -}}
    {{- if .mountPath -}}{{- $esMounted = append $esMounted . -}}{{- else -}}{{- $esEnvOwn = append $esEnvOwn . -}}{{- end -}}
  {{- end -}}
  {{- $hasEnvFrom := or $hasDeployConfigMap $hasDeploySecret $job.envFromConfigMaps $job.envFromSecrets $deploy.envFromConfigMaps $deploy.envFromSecrets $esEnvInherited $esEnvOwn -}}
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
    {{- range $cm := $deploy.envFromConfigMaps }}
    - configMapRef:
        name: {{ $cm | quote }}
    {{- end }}
    {{- /* Deployment's external Secrets */ -}}
    {{- range $sec := $deploy.envFromSecrets }}
    - secretRef:
        name: {{ $sec | quote }}
    {{- end }}
    {{- /* Deployment's externalSecrets, inherited */ -}}
    {{- range $esEnvInherited }}
    - secretRef:
        name: {{ .secretName | quote }}
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
        name: {{ .secretName | quote }}
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
    {{- range $esMounted }}
    - name: {{ .volumeName }}
      mountPath: {{ .mountPath | quote }}
      readOnly: true
    {{- end }}
  {{- end }}
{{- if or $job.volumes $esMounted }}
volumes:
  {{- range $job.volumes }}
  {{- include "global-chart.renderVolume" . | nindent 2 }}
  {{- end }}
  {{- range $esMounted }}
  - name: {{ .volumeName }}
    secret:
      secretName: {{ .secretName | quote }}
  {{- end }}
{{- end }}
{{- with $saName }}
serviceAccountName: {{ . | quote }}
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
Resolve the image string for a cronjob/hook command, unifying the choice across
root-level and deployment-level jobs. Returns the image string ("" when none
resolves, so the caller applies `required` with its own context message).

Accepts a dict with:
  root    - top-level chart context
  job     - the cronjob/hook command map
  deploy  - the parent deployment map (omit/nil for root-level jobs)
  errCtx  - prefix for the fromDeployment failure message (e.g. "cronJobs.cleanup")

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
{{- $errCtx := .errCtx -}}
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
{{- $img -}}
{{- end -}}

{{/*
Resolve the ServiceAccount for a deployment-level cronjob/hook, unifying the
resolution shared by hook.yaml PART 2 and cronjob.yaml PART 2.

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
{{- $deploySA := default (dict) $deploy.serviceAccount -}}
{{- $jobSAMap := (and (hasKey $job "serviceAccount") (kindIs "map" $job.serviceAccount)) | ternary $job.serviceAccount (dict) -}}
{{- $jobSAExplicitName := coalesce $job.serviceAccountName $jobSAMap.name -}}
{{- /* Resolve deployment's SA name (created or referenced-existing) */ -}}
{{- $deploymentSAName := "" -}}
{{- $deploySACreate := ternary $deploySA.create true (hasKey $deploySA "create") -}}
{{- if and $deploy $deploySACreate -}}
  {{- $deploymentSAName = include "global-chart.deploymentServiceAccountName" (dict "root" $root "deploymentName" $deployName "deployment" $deploy) -}}
{{- else if $deploySA.name -}}
  {{- $deploymentSAName = $deploySA.name -}}
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
