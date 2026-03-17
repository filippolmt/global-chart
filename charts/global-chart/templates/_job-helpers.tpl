{{/*
Shared helper for deployment-level hooks and cronjobs pod spec.
Renders the pod spec fields that are common to both, with parameterized differences.

Accepts a dict with:
  root                - top-level chart context (for global values, defaults)
  job                 - the cronjob/hook command map
  deploy              - the parent deployment map
  saName              - pre-resolved ServiceAccount name
  imageRef            - pre-resolved image string
  containerName       - name for the container
  configMapRef        - ConfigMap name for envFrom (hooks use hook-config, cronjobs use deploy name)
  secretRef           - Secret name for envFrom (hooks use hook-secret, cronjobs use deploy name)
  inheritDnsConfig    - whether to fall back to deploy.dnsConfig (false for hooks)
  renderInitContainers - whether to render initContainers (false for hooks)
*/}}
{{- define "global-chart.inheritedJobPodSpec" -}}
{{- $root := .root -}}
{{- $job := .job -}}
{{- $deploy := .deploy -}}
{{- $saName := .saName -}}
{{- $imageRef := .imageRef -}}
{{- $containerName := .containerName -}}
{{- $configMapRef := .configMapRef -}}
{{- $secretRef := .secretRef -}}
{{- $inheritDnsConfig := .inheritDnsConfig -}}
{{- $renderInitContainers := .renderInitContainers -}}
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
{{- /* DnsConfig: if inheritDnsConfig, fall back to deploy.dnsConfig; otherwise job only */ -}}
{{- $dnsConfig := dict -}}
{{- if $inheritDnsConfig -}}
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
{{- if and $renderInitContainers $job.initContainers }}
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
  {{- $hasDeployConfigMap := and $deploy.configMap (gt (len $deploy.configMap) 0) -}}
  {{- $hasDeploySecret := and $deploy.secret (gt (len $deploy.secret) 0) -}}
  {{- $hasEnvFrom := or $hasDeployConfigMap $hasDeploySecret $job.envFromConfigMaps $job.envFromSecrets $deploy.envFromConfigMaps $deploy.envFromSecrets -}}
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
{{ . | indent 2 }}
  {{- end }}
  {{- with $job.volumeMounts }}
  volumeMounts:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- with $job.volumes }}
volumes:
  {{- range . }}
  {{- include "global-chart.renderVolume" . | nindent 2 }}
  {{- end }}
{{- end }}
serviceAccountName: {{ $saName | quote }}
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
