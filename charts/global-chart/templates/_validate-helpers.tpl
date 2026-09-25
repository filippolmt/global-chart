{{/*
Validation helpers for global-chart.
*/}}

{{/*
Validate that all generated resource names are unique after truncation.
Checks within each resource kind: Deployments, CronJobs, Jobs (hooks),
ServiceAccounts, ConfigMaps, Secrets, ExternalSecrets, TriggerAuthentications,
Roles and RoleBindings, the hook-prerequisite copies included.
A kind's accumulator holds every name of that kind whatever derived it, because
collisions cross sources: $cmNames carries the deployment's own ConfigMap, its
mounted config file ConfigMaps and its hook-prerequisite copy alike. A
deployment named `<other>-md-cm-<file>` renders a ConfigMap under the very name
another deployment's mounted file does — two manifests, one name, neither
invalid on its own.
Note: the remaining per-deployment resources (Service, SA, HPA, ScaledObject,
PDB, NetworkPolicy) share the Deployment's own name and no other kind derives a
name that can reach them, so the deployment name check covers them.
Called from validate.yaml.
*/}}
{{- define "global-chart.validateNameCollisions" -}}
{{- $root := . -}}
{{- $deployNames := dict -}}
{{- $cronNames := dict -}}
{{- $hookNames := dict -}}
{{- $cmNames := dict -}}
{{- $secretNames := dict -}}
{{- $saNames := dict -}}
{{- $esNames := dict -}}
{{- $esOwnedNames := dict -}}

{{- /* 1. Deployment resource names (trunc 63) */ -}}
{{- range $name, $deploy := .Values.deployments -}}
  {{- if $deploy -}}
  {{- if eq (include "global-chart.deploymentEnabled" $deploy) "true" -}}
    {{- $depFullname := include "global-chart.deploymentFullname" (dict "root" $root "deploymentName" $name) -}}
    {{- include "global-chart.registerName" (dict "names" $deployNames "kind" "Deployment" "name" $depFullname "owner" (printf "deployments.%s" $name)) -}}

    {{- /* The deployment's own ConfigMap and Secret both carry $depFullname. They
           cannot clash with each other or with another deployment's — the name
           check above covers that — but they share $cmNames/$secretNames with the
           mounted config file copies and the hook-prerequisite copies, whose names
           are built by appending a suffix and so CAN land on a plain deployment
           name. */ -}}
    {{- if $deploy.configMap -}}
      {{- include "global-chart.registerName" (dict "names" $cmNames "kind" "ConfigMap" "name" $depFullname "owner" (printf "deployments.%s.configMap" $name)) -}}
    {{- end -}}
    {{- if $deploy.secret -}}
      {{- include "global-chart.registerName" (dict "names" $secretNames "kind" "Secret" "name" $depFullname "owner" (printf "deployments.%s.secret" $name)) -}}
    {{- end -}}

    {{- /* Chart-created deployment ServiceAccount: a root-level job that creates its
           own SA can land on this very name (both are <release>-<chart>-<key>) */ -}}
    {{- $deploySA := include "global-chart.deploymentServiceAccount" (dict "root" $root "deploymentName" $name "deployment" $deploy) | fromJson -}}
    {{- include "global-chart.registerSAName" (dict "names" $saNames "sa" $deploySA "owner" (printf "deployments.%s" $name)) -}}

    {{- /* 1a. Deployment-level CronJob names (trunc 52) — via deploymentCronJobName helper */ -}}
    {{- range $jobName, $job := $deploy.cronJobs -}}
      {{- if $job -}}
        {{- $jobFullname := include "global-chart.deploymentCronJobName" (dict "root" $root "deploymentName" $name "jobName" $jobName) -}}
        {{- $errCtx := include "global-chart.jobValuesPath" (dict "kind" "cronjob" "deploymentName" $name "jobName" $jobName) -}}
        {{- include "global-chart.registerName" (dict "names" $cronNames "kind" "CronJob" "name" $jobFullname "owner" $errCtx) -}}
        {{- $jobSA := include "global-chart.jobServiceAccount" (dict "root" $root "job" $job "deploy" $deploy "deployName" $name "jobFullname" $jobFullname "errCtx" $errCtx) | fromJson -}}
        {{- include "global-chart.registerSAName" (dict "names" $saNames "sa" $jobSA "owner" $errCtx) -}}
      {{- end -}}
    {{- end -}}

    {{- /* 1b. Deployment-level Hook names (trunc 63) + prerequisite ConfigMap/Secret */ -}}
    {{- if $deploy.hooks -}}
      {{- /* Hook prerequisite ConfigMap (trunc 63) */ -}}
      {{- $hasDeployConfigMap := and $deploy.configMap (gt (len $deploy.configMap) 0) -}}
      {{- if $hasDeployConfigMap -}}
        {{- $hookConfigName := include "global-chart.hookPrereqConfigName" (dict "deploymentFullname" $depFullname) -}}
        {{- include "global-chart.registerName" (dict "names" $cmNames "kind" "ConfigMap" "name" $hookConfigName "owner" (printf "deployments.%s.configMap (hook prerequisite copy)" $name)) -}}
      {{- end -}}

      {{- /* Hook prerequisite Secret (trunc 63) */ -}}
      {{- $hasDeploySecret := and $deploy.secret (gt (len $deploy.secret) 0) -}}
      {{- if $hasDeploySecret -}}
        {{- $hookSecretName := include "global-chart.hookPrereqSecretName" (dict "deploymentFullname" $depFullname) -}}
        {{- include "global-chart.registerName" (dict "names" $secretNames "kind" "Secret" "name" $hookSecretName "owner" (printf "deployments.%s.secret (hook prerequisite copy)" $name)) -}}
      {{- end -}}

      {{- range $hookType, $jobs := $deploy.hooks -}}
        {{- range $jobName, $command := $jobs -}}
          {{- if $command -}}
            {{- /* Canonical 4-part single-trunc name via shared helper — keeps validator byte-identical to hook.yaml (prior depFullname-based double-trunc only diverged for K8s-invalid trailing-dash names) */ -}}
            {{- $hookFullname := include "global-chart.deploymentHookName" (dict "root" $root "deploymentName" $name "hookType" $hookType "jobName" $jobName) -}}
            {{- $errCtx := include "global-chart.jobValuesPath" (dict "kind" "hook" "deploymentName" $name "hookType" $hookType "jobName" $jobName) -}}
            {{- include "global-chart.registerName" (dict "names" $hookNames "kind" "Job" "name" $hookFullname "owner" $errCtx) -}}
            {{- $hookSA := include "global-chart.jobServiceAccount" (dict "root" $root "job" $command "deploy" $deploy "deployName" $name "jobFullname" $hookFullname "errCtx" $errCtx) | fromJson -}}
            {{- include "global-chart.registerSAName" (dict "names" $saNames "sa" $hookSA "owner" $errCtx) -}}
          {{- end -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}

    {{- /* 1c. Mounted config file ConfigMaps — `files` and `bundles` share one
           name space, so a name used on both sides renders two ConfigMaps under
           one name with different content, and the pod gets whichever applied
           last. Registered in $cmNames, which also catches two deployments
           truncating to the same $depFullname. */ -}}
    {{- $mcf := default (dict) $deploy.mountedConfigFiles -}}
    {{- $mcHint := ". Give one of the two entries a different 'name'." -}}
    {{- range $i, $f := (default (list) $mcf.files) -}}
      {{- $owner := printf "deployments.%s.mountedConfigFiles.files[%d] ('%s')" $name $i $f.name -}}
      {{- include "global-chart.registerName" (dict "names" $cmNames "kind" "ConfigMap" "name" (include "global-chart.mountedConfigMapName" (dict "deploymentFullname" $depFullname "fileName" $f.name)) "owner" $owner "hint" $mcHint) -}}
    {{- end -}}
    {{- range $bi, $b := (default (list) $mcf.bundles) -}}
      {{- range $fi, $f := (default (list) $b.files) -}}
        {{- $owner := printf "deployments.%s.mountedConfigFiles.bundles[%d].files[%d] ('%s')" $name $bi $fi $f.name -}}
        {{- include "global-chart.registerName" (dict "names" $cmNames "kind" "ConfigMap" "name" (include "global-chart.mountedConfigMapName" (dict "deploymentFullname" $depFullname "fileName" $f.name)) "owner" $owner "hint" $mcHint) -}}
      {{- end -}}
    {{- end -}}

  {{- end -}}
  {{- end -}}
{{- end -}}

{{- /* 2. Root-level CronJob names (trunc 52) */ -}}
{{- range $name, $job := .Values.cronJobs -}}
  {{- if $job -}}
    {{- $jobFullname := include "global-chart.rootCronJobName" (dict "root" $root "name" $name) -}}
    {{- $errCtx := include "global-chart.jobValuesPath" (dict "kind" "cronjob" "jobName" $name) -}}
    {{- include "global-chart.registerName" (dict "names" $cronNames "kind" "CronJob" "name" $jobFullname "owner" $errCtx) -}}
    {{- $sa := include "global-chart.jobServiceAccount" (dict "root" $root "job" $job "jobFullname" $jobFullname "errCtx" $errCtx) | fromJson -}}
    {{- include "global-chart.registerSAName" (dict "names" $saNames "sa" $sa "owner" $errCtx) -}}
  {{- end -}}
{{- end -}}

{{- /* 3. Root-level Hook names (trunc 63) */ -}}
{{- range $hookType, $jobs := .Values.hooks -}}
  {{- range $name, $command := $jobs -}}
    {{- if $command -}}
      {{- $hookFullname := include "global-chart.hookfullname" (merge (dict "hookname" $hookType "jobname" $name) $root) -}}
      {{- $errCtx := include "global-chart.jobValuesPath" (dict "kind" "hook" "hookType" $hookType "jobName" $name) -}}
      {{- include "global-chart.registerName" (dict "names" $hookNames "kind" "Job" "name" $hookFullname "owner" $errCtx) -}}
      {{- $sa := include "global-chart.jobServiceAccount" (dict "root" $root "job" $command "jobFullname" $hookFullname "errCtx" $errCtx) | fromJson -}}
      {{- include "global-chart.registerSAName" (dict "names" $saNames "sa" $sa "owner" $errCtx) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{- /* 4. ExternalSecrets and their hook-prerequisite copies (ADR 0007). The copy
       appends "-hook" to both the ExternalSecret name and its target, so a key
       or a target.name that already ends in "-hook" lands on it.
       $esOwnedNames holds the Secrets an ExternalSecret *owns*: two owners of
       one Secret is ErrSecretIsOwned, and the copy's deletion would take the
       other's Secret with it. A real target under Merge or None is written
       into, not owned, so several of them sharing a target stays legal — but
       not one a copy owns, which the copy's deletion would garbage-collect:
       those are checked against the copies alone, on a throwaway copy of
       $copyTargets, so that two of them still never meet each other. An
       Owner target, the copy's included, also joins $secretNames, against the
       chart's own Secrets: Owner adopts a Helm Secret, the two overwrite each
       other's data and the ExternalSecret's deletion garbage-collects it
       (issue #153). Merge and None stay out: Helm's patch keeps the keys Merge
       adds, and None writes nothing (ADR 0013,
       docs/adr/0013-an-owner-externalsecret-target-cannot-be-a-chart-secret.md). */ -}}
{{- $consumers := include "global-chart.externalSecretHookConsumers" $root | fromJson -}}
{{- range $key, $secret := .Values.externalSecrets -}}
  {{- if $secret -}}
    {{- $nameCtx := dict "root" $root "key" $key "secret" $secret -}}
    {{- $owner := printf "externalSecrets.%s" $key -}}
    {{- include "global-chart.registerName" (dict "names" $esNames "kind" "ExternalSecret" "name" (include "global-chart.externalSecretName" $nameCtx) "owner" $owner) -}}
    {{- if eq (include "global-chart.externalSecretCreationPolicy" $secret) "Owner" -}}
      {{- $target := include "global-chart.externalSecretTargetName" $nameCtx -}}
      {{- include "global-chart.registerName" (dict "names" $esOwnedNames "kind" "Secret" "name" $target "owner" $owner) -}}
      {{- include "global-chart.registerName" (dict "names" $secretNames "kind" "Secret" "name" $target "owner" $owner) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $copyTargets := dict -}}
{{- range $key, $secret := .Values.externalSecrets -}}
  {{- if and $secret (hasKey $consumers $key) -}}
    {{- $nameCtx := dict "root" $root "key" $key "secret" $secret -}}
    {{- $owner := printf "externalSecrets.%s (hook prerequisite copy)" $key -}}
    {{- $copyTarget := include "global-chart.externalSecretHookTargetName" $nameCtx -}}
    {{- include "global-chart.registerName" (dict "names" $esNames "kind" "ExternalSecret" "name" (include "global-chart.externalSecretHookName" $nameCtx) "owner" $owner) -}}
    {{- include "global-chart.registerName" (dict "names" $esOwnedNames "kind" "Secret" "name" $copyTarget "owner" $owner) -}}
    {{- include "global-chart.registerName" (dict "names" $secretNames "kind" "Secret" "name" $copyTarget "owner" $owner) -}}
    {{- $_ := set $copyTargets $copyTarget $owner -}}
  {{- end -}}
{{- end -}}
{{- range $key, $secret := .Values.externalSecrets -}}
  {{- if and $secret (ne (include "global-chart.externalSecretCreationPolicy" $secret) "Owner") -}}
    {{- $target := include "global-chart.externalSecretTargetName" (dict "root" $root "key" $key "secret" $secret) -}}
    {{- include "global-chart.registerName" (dict "names" (deepCopy $copyTargets) "kind" "Secret" "name" $target "owner" (printf "externalSecrets.%s (%s)" $key (include "global-chart.externalSecretCreationPolicy" $secret))) -}}
  {{- end -}}
{{- end -}}

{{- /* 5. TriggerAuthentications (trunc 63): two keys sharing a long prefix
       truncate to one name, and a ScaledObject meant for the first reads the
       second's credentials (issue #117) */ -}}
{{- $taNames := dict -}}
{{- range $key, $auth := .Values.kedaTriggerAuthentications -}}
  {{- if $auth -}}
    {{- include "global-chart.registerName" (dict "names" $taNames "kind" "TriggerAuthentication" "name" (include "global-chart.kedaTriggerAuthName" (dict "root" $root "name" $key)) "owner" (printf "kedaTriggerAuthentications.%s" $key)) -}}
  {{- end -}}
{{- end -}}

{{- /* 6. rbacs.roles (issue #122): the Role name is used verbatim, the RoleBinding
       drops a trailing -role, and the default <name>-sa is truncated — each can
       land on another entry's. The SA joins $saNames, against every other
       chart-created one. */ -}}
{{- $roleNames := dict -}}
{{- $bindingNames := dict -}}
{{- range $i, $role := (default (dict) .Values.rbacs).roles -}}
  {{- $owner := printf "rbacs.roles[%d] ('%s')" $i $role.name -}}
  {{- include "global-chart.registerName" (dict "names" $roleNames "kind" "Role" "name" $role.name "owner" $owner) -}}
  {{- /* SA before RoleBinding: the binding keeps fewer characters of the role
         name, so two names whose default SA truncates alike always clash on the
         binding too — checked first, it would blame the wrong kind */ -}}
  {{- $sa := include "global-chart.rbacServiceAccount" $role | fromJson -}}
  {{- include "global-chart.registerSAName" (dict "names" $saNames "sa" $sa "owner" $owner) -}}
  {{- if $sa.name -}}
    {{- include "global-chart.registerName" (dict "names" $bindingNames "kind" "RoleBinding" "name" (include "global-chart.rbacRoleBindingName" $role.name) "owner" $owner) -}}
  {{- end -}}
{{- end -}}
{{- /* 7. The hook-prerequisite copies of rbacs.roles (ADR 0010), after every
       real name so the copy is the one blamed. <name>-hook lands on an entry
       already named so, and a name at its limit truncates back onto its own
       real one — a copy sharing the real name would delete it under
       hook-succeeded. The copied SA is registered in 8, with every SA copy. */ -}}
{{- $rbacConsumers := include "global-chart.rbacHookConsumers" $root | fromJson -}}
{{- /* The copy's name derives from the real one, so neither serviceAccount.name
       nor create: false is a way out: the name has to change */ -}}
{{- $copyHint := ". A hook-prerequisite copy is named after its real resource plus '-hook', truncated to the same limit (ADR 0010): shorten the name so the copy fits, or rename the entry it lands on." -}}
{{- range $i, $role := (default (dict) .Values.rbacs).roles -}}
  {{- if hasKey $rbacConsumers $role.name -}}
    {{- $owner := printf "rbacs.roles[%d] ('%s') (hook prerequisite copy)" $i $role.name -}}
    {{- include "global-chart.registerName" (dict "names" $roleNames "kind" "Role" "name" (include "global-chart.rbacRoleHookName" $role.name) "owner" $owner "hint" $copyHint) -}}
    {{- include "global-chart.registerName" (dict "names" $bindingNames "kind" "RoleBinding" "name" (include "global-chart.rbacRoleBindingHookName" $role.name) "owner" $owner "hint" $copyHint) -}}
  {{- end -}}
{{- end -}}
{{- /* 8. The hook-prerequisite copy of every ServiceAccount the release
       creates that a hook runs as (ADR 0010, ADR 0011), under the same rule and
       after every real name: <sa>-hook lands on another SA the chart creates, or
       truncates back onto its own real name. Blamed on the SA's creator. */ -}}
{{- $releaseSAs := include "global-chart.releaseServiceAccounts" $root | fromJson -}}
{{- range $saName, $_ := (include "global-chart.serviceAccountHookConsumers" $root | fromJson) -}}
  {{- include "global-chart.registerSAName" (dict "names" $saNames "sa" (dict "create" true "name" (include "global-chart.serviceAccountCopyName" (dict "root" $root "name" $saName))) "owner" (printf "%s (hook prerequisite copy)" (index $releaseSAs $saName).owner) "hint" (replace "(ADR 0010)" "(ADR 0011)" $copyHint)) -}}
{{- end -}}

{{- end }}

{{/*
Record a generated resource name and fail if something else already generated
that name for the same kind.

Two manifests of one kind sharing a name is the collision Kubernetes never
reports: each manifest is valid on its own, `helm template` renders both, and
the apply simply keeps the last one. So it has to be caught here.

Every collision check in validateNameCollisions routes through this, which is
what keeps the accumulators honest: a kind's dict holds every name of that kind
regardless of which values derived it, and a new source of names is one call,
not another copy of fail + set.

Accepts: names (the accumulator dict, mutated in place), kind (the Kubernetes
kind, for the message), name (the generated name), owner (human-readable source,
stored and quoted in the message), hint (optional remediation sentence; it is
appended verbatim, so start it with its separator: ". Give …").
*/}}
{{- define "global-chart.registerName" -}}
{{- $names := .names -}}
{{- if hasKey $names .name -}}
  {{- fail (printf "Name collision: %s '%s' generated by %s conflicts with %s%s" .kind .name .owner (index $names .name) (default "" .hint)) -}}
{{- end -}}
{{- $_ := set $names .name .owner -}}
{{- end }}

{{/*
Record a chart-created ServiceAccount name and fail if something else already
creates one under it. Two ServiceAccount manifests sharing a name render fine and
break the install itself ("already exists"), halfway through the release.

Only *created* SAs are registered: several jobs pointing at one existing SA, or at
the deployment's, is the normal way to share an identity. The hook-prerequisite
copies of ADR 0010 and ADR 0011 have their own name, <sa>-hook, and are
registered too.

Does not delegate to registerName: an SA is *created for* an owner rather than
generated by one, and the message says so (pinned by validate_test.yaml). The
shared part is the two lines of hasKey + set, which is less than the
parameterisation that unifying the two wordings would cost.

Accepts: names (the accumulator dict, mutated in place), sa (any resolver
result from _serviceaccount-helpers.tpl: .create + .name), owner
(human-readable source, used in the message), hint (optional: replaces the
default advice, for an owner it does not fit — a hook-prerequisite copy takes
its name from the real SA, so it can be given neither). Only a created, named
SA is registered, so callers pass the result whatever its create.
*/}}
{{- define "global-chart.registerSAName" -}}
{{- $names := .names -}}
{{- $sa := .sa -}}
{{- if and $sa.create $sa.name -}}
  {{- if hasKey $names $sa.name -}}
    {{- fail (printf "Name collision: ServiceAccount '%s' created for %s conflicts with the one created for %s%s" $sa.name .owner (index $names $sa.name) (default ". Give one of them an explicit serviceAccount.name, or set serviceAccount.create: false to bind the existing one." .hint)) -}}
  {{- end -}}
  {{- $_ := set $names $sa.name .owner -}}
{{- end -}}
{{- end }}

{{/*
Validate that the fullname fits the names it ends up leading (issue #120).
The fullname heads every generated name, and most of them are DNS subdomains,
which take anything Helm's release-name rule or the schema's override patterns
let through. Two kinds of name are stricter, and only some releases render them:
- a container name is a DNS-1123 label, so no dot. The fullname heads the
  container name of every enabled Deployment and of every root-level hook;
- a Service name is a DNS-1035 label, so it also starts with a letter. The
  fullname heads the name of every enabled deployment's Service.
The constraint therefore depends on what the release renders — see
docs/adr/0009-the-fullname-constraint-follows-what-the-release-renders.md. A
cronjob-only release with a dotted name renders valid names today and keeps
rendering.
Uppercase is not checked: Helm rejects it in a release name and the schema in
the overrides. That also keeps helm-unittest's RELEASE-NAME default out of it.
Called from validate.yaml. Emits nothing on success.
*/}}
{{- define "global-chart.validateFullname" -}}
{{- $fullname := include "global-chart.fullname" . -}}
{{- $label := "" -}}
{{- $service := "" -}}
{{- range $name, $deploy := .Values.deployments -}}
  {{- if $deploy -}}
  {{- if eq (include "global-chart.deploymentEnabled" $deploy) "true" -}}
    {{- $label = printf "deployments.%s" $name -}}
    {{- if eq (include "global-chart.serviceEnabled" (default (dict) $deploy.service)) "true" -}}
      {{- $service = printf "deployments.%s" $name -}}
    {{- end -}}
  {{- end -}}
  {{- end -}}
{{- end -}}
{{- range $hookType, $jobs := .Values.hooks -}}
  {{- range $name, $job := $jobs -}}
    {{- if $job -}}{{- $label = include "global-chart.jobValuesPath" (dict "kind" "hook" "hookType" $hookType "jobName" $name) -}}{{- end -}}
  {{- end -}}
{{- end -}}
{{- if and $label (contains "." $fullname) -}}
  {{- fail (printf "The fullname %q contains a dot, but %s names a container after it, and a container name is a DNS-1123 label. The dot comes from the release name or from nameOverride/fullnameOverride: set fullnameOverride to a name without dots." $fullname $label) -}}
{{- end -}}
{{- if and $service (regexMatch "^[0-9]" $fullname) -}}
  {{- fail (printf "The fullname %q starts with a digit, but %s renders a Service named after it, and a Service name is a DNS-1035 label, which starts with a letter. Set fullnameOverride to a name starting with a letter." $fullname $service) -}}
{{- end -}}
{{- end }}

{{/*
Validate that .Values.ingress and .Values.httpRoute are not both enabled.
The chart supports only one routing layer per release; both being enabled
would render conflicting top-level routing resources.
Called from validate.yaml. Emits nothing on success.
*/}}
{{- define "global-chart.validateRoutingConflict" -}}
{{- $ing := default (dict) .Values.ingress -}}
{{- $rt := default (dict) .Values.httpRoute -}}
{{- $ingEnabled := default false $ing.enabled -}}
{{- $rtEnabled := default false $rt.enabled -}}
{{- if and $ingEnabled $rtEnabled -}}
{{- fail "Both .Values.ingress.enabled and .Values.httpRoute.enabled are true. The chart supports only one routing layer per release. Disable one (set enabled: false) to proceed." -}}
{{- end -}}
{{- end }}

{{/*
The active HPA targets of a deployment's `autoscaling` map, as JSON: the ONE
home of "a target is active", read by validateAutoscalingConflict and by
hpa.yaml to build its metrics list. Never re-derive it inline — two templates
deriving one fact on their own is how issue #82 happened.

A target is active when it is set and `float64` reads it as positive; 0, ""
and an absent key all mean "this metric is off". Keys are `cpu` and `memory`,
the resource names, each carrying the raw value for printScalar: an int cast
here would truncate in silence. The schema admits only digits in a string
target, since `float64 "80%"` is 0 (ADR 0012,
docs/adr/0012-autoscaling-enabled-requires-an-active-metric.md).
Usage: {{ include "global-chart.hpaActiveTargets" $hpa | fromJson }}
*/}}
{{- define "global-chart.hpaActiveTargets" -}}
{{- $out := dict -}}
{{- range $res, $key := dict "cpu" "targetCPUUtilizationPercentage" "memory" "targetMemoryUtilizationPercentage" -}}
  {{- if and (hasKey $ $key) (gt (float64 (get $ $key)) 0.0) -}}
    {{- $_ := set $out $res (get $ $key) -}}
  {{- end -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{/*
Validate that a deployment does not enable both the native HPA and KEDA, and
that an enabled HPA has an active target.
KEDA creates and owns its own HorizontalPodAutoscaler (the *derived HPA*) for
every ScaledObject, so a chart-rendered HPA on the same Deployment gives two
controllers writing spec.replicas.
The Deployment drops spec.replicas whenever autoscaling is enabled, so with no
active target neither side owns the count and Kubernetes defaults it to one
pod (issue #151, ADR 0012). The KEDA conflict fails first: it is the more
fundamental error, and fixing it can make the other moot.
Called from validate.yaml. Emits nothing on success.
*/}}
{{- define "global-chart.validateAutoscalingConflict" -}}
{{- range $name, $deploy := .Values.deployments -}}
  {{- if $deploy -}}
  {{- if eq (include "global-chart.deploymentEnabled" $deploy) "true" -}}
    {{- $hpa := default (dict) $deploy.autoscaling -}}
    {{- $keda := default (dict) $deploy.keda -}}
    {{- if and $hpa.enabled $keda.enabled -}}
      {{- fail (printf "deployments.%s: autoscaling.enabled and keda.enabled are mutually exclusive. KEDA creates and owns its own HorizontalPodAutoscaler for the ScaledObject; a chart-rendered HPA on the same Deployment would fight it. Disable one of the two." $name) -}}
    {{- end -}}
    {{- if and $hpa.enabled (not (include "global-chart.hpaActiveTargets" $hpa | fromJson)) -}}
      {{- fail (printf "deployments.%s.autoscaling.enabled is true but neither targetCPUUtilizationPercentage nor targetMemoryUtilizationPercentage is a positive number; without one no HPA renders and the Deployment runs a single replica. Set a target or disable autoscaling." $name) -}}
    {{- end -}}
  {{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Validate that every named Service targetPort resolves to a container port the
chart declares.

A targetPort naming a port that no container declares is the one Service
misconfiguration Kubernetes accepts in silence: the Service is created, the pod
is Ready, and the port simply has no endpoints. It surfaces at request time, far
from its cause. Numbers need no check — a numeric targetPort reaches a pod port
whether or not the container declares it.
Called from validate.yaml. Emits nothing on success.
*/}}
{{- define "global-chart.validateServiceTargetPorts" -}}
{{- range $name, $deploy := .Values.deployments -}}
  {{- if $deploy -}}
  {{- if eq (include "global-chart.deploymentEnabled" $deploy) "true" -}}
    {{- $svc := default (dict) $deploy.service -}}
    {{- if eq (include "global-chart.serviceEnabled" $svc) "true" -}}
      {{- $declared := dict -}}
      {{- range (include "global-chart.containerPorts" $svc | fromJsonArray) -}}
        {{- $_ := set $declared .name true -}}
      {{- end -}}
      {{- $known := keys $declared | sortAlpha | join ", " -}}
      {{- $targetPort := (include "global-chart.servicePrimaryPort" $svc | fromJson).targetPort -}}
      {{- if and (hasKey $svc "targetPort") (kindIs "string" $svc.targetPort) (not (hasKey $declared $targetPort)) -}}
        {{- fail (printf "deployments.%s.service.targetPort names the port '%s', which no container port declares (declared: %s). A Service port whose targetPort names nothing gets no endpoints. Use the port number, or a name one of the declared ports carries." $name $targetPort $known) -}}
      {{- end -}}
      {{- range (default (list) $svc.extraPorts) -}}
        {{- if and (kindIs "string" .targetPort) (not (hasKey $declared .targetPort)) -}}
          {{- fail (printf "deployments.%s.service.extraPorts '%s' has targetPort '%s', which no container port declares (declared: %s). A Service port whose targetPort names nothing gets no endpoints. Give it the port number instead, and it will be declared on the container under this name." $name .name .targetPort $known) -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}
