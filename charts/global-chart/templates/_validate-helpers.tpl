{{/*
Validation helpers for global-chart.

Every fail message a user can cause has one shape: "<values path>: <problem>",
the path being the key that holds the wrong value, as precise as the caller
knows it (issue #190). A job's path comes from jobValuesPath, a workload's
from deploymentValuesPath below: never printf either inline, and pass it to a
helper as errCtx. Two kinds of message keep another shape, each because it
has no path to lead with: a helper's own invariant ("<helper>: …", a chart
bug, not a values one), and a conflict between entries (name collisions, the
fullname, ingress with httpRoute). A null read from values fails through
rejectNull (_render-helpers.tpl), naming its key (issue #191). The shape and
its exceptions are mirrored by FAIL_SHAPE in tests/lint-templates.py, which
checks every fail against them: change both.
*/}}

{{/*
The values path of a workload, "workloads.<name>": its single home, as
jobValuesPath is a job's (and leads a workload-scope job's with it).
Usage: {{ include "global-chart.deploymentValuesPath" $name }}
*/}}
{{- define "global-chart.deploymentValuesPath" -}}
workloads.{{ . }}
{{- end }}

{{/*
Fail on every key removed in 4.0.0, wherever it sits and whether or not its
surface renders: a disabled Ingress, HTTPRoute or workload would carry the old
key into the next enable (ADR 0023). The one home of that walk and of its
message, called first from validate/validate.yaml, the first template Helm
renders (see its header). Each key
stays declared in the schema with no constraint, so any value reaches its fail
(ADR 0022); the walk, the declarations and the fixtures go in 5.0.0. A node of
the wrong type is skipped: the schema, or the template that reads it, rejects
it.
  deployments                                   → workloads, with the migration guide (issue #221)
  <hook or cronjob>.fromDeployment              → fromWorkload (issue #221)
  <hook or cronjob>.inheritDeployment*          → inheritWorkload* (issue #221)
  <ingress host or route backendRef>.deployment → workload (issue #221)
  <pod spec>.volumes[<i>].type, .secret.name, .persistentVolumeClaim.name
                                                → the native volume source (issue #230)
Usage: {{- include "global-chart.validateRemovedKeys" . -}}
*/}}
{{- define "global-chart.validateRemovedKeys" -}}
{{- $v := .Values -}}
{{- $in := "4.0.0" -}}
{{- $see := printf "%s/blob/main/CHANGELOG.md#migration-guide-from-3x" .Chart.Home -}}
{{- include "global-chart.rejectRemovedKeys" (dict "map" $v "errCtx" "" "in" $in "keys" (dict "deployments" "workloads") "see" $see) -}}
{{- $from := dict "fromDeployment" "fromWorkload" -}}
{{- $inherit := dict "inheritDeploymentConfigMap" "inheritWorkloadConfigMap" "inheritDeploymentSecret" "inheritWorkloadSecret" "inheritDeploymentEnvFromConfigMaps" "inheritWorkloadEnvFromConfigMaps" "inheritDeploymentEnvFromSecrets" "inheritWorkloadEnvFromSecrets" -}}
{{- $backend := dict "deployment" "workload" -}}
{{- /* Both job key families at both scopes: the schema rejects one at the
       wrong scope, and --skip-schema-validation would let it pass in silence */ -}}
{{- $jobKeys := merge (dict) $from $inherit -}}
{{- include "global-chart.rejectRemovedJobKeys" (dict "cronJobs" $v.cronJobs "hooks" $v.hooks "in" $in "see" $see "keys" $jobKeys) -}}
{{- if kindIs "map" $v.workloads -}}
  {{- range $name, $w := $v.workloads -}}
    {{- if kindIs "map" $w -}}
      {{- include "global-chart.rejectRemovedVolumeKeys" (dict "volumes" $w.volumes "errCtx" (include "global-chart.deploymentValuesPath" $name) "in" $in "see" $see) -}}
      {{- include "global-chart.rejectRemovedJobKeys" (dict "cronJobs" $w.cronJobs "hooks" $w.hooks "deploymentName" $name "in" $in "see" $see "keys" $jobKeys) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- if and (kindIs "map" $v.ingress) (kindIs "slice" $v.ingress.hosts) -}}
  {{- range $i, $host := $v.ingress.hosts -}}
    {{- include "global-chart.rejectRemovedKeys" (dict "map" $host "errCtx" (printf "ingress.hosts[%d]" $i) "in" $in "keys" $backend) -}}
  {{- end -}}
{{- end -}}
{{- /* httpRoute is one route, httpRoutes and the l4RouteKinds fields maps of
       them: every backendRef of every rule, enabled or not */ -}}
{{- $routes := dict -}}
{{- if kindIs "map" $v.httpRoute -}}
  {{- $_ := set $routes "httpRoute" $v.httpRoute -}}
{{- end -}}
{{- $maps := list "httpRoutes" -}}
{{- range (include "global-chart.l4RouteKinds" . | fromJsonArray) -}}
  {{- $maps = append $maps .field -}}
{{- end -}}
{{- range $field := $maps -}}
  {{- $entries := index $v $field -}}
  {{- if kindIs "map" $entries -}}
    {{- range $name, $route := $entries -}}
      {{- $_ := set $routes (printf "%s.%s" $field $name) $route -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- range $ctx, $route := $routes -}}
  {{- if and (kindIs "map" $route) (kindIs "slice" $route.rules) -}}
    {{- range $r, $rule := $route.rules -}}
      {{- if and (kindIs "map" $rule) (kindIs "slice" $rule.backendRefs) -}}
        {{- range $b, $ref := $rule.backendRefs -}}
          {{- include "global-chart.rejectRemovedKeys" (dict "map" $ref "errCtx" (printf "%s.rules[%d].backendRefs[%d]" $ctx $r $b) "in" $in "keys" $backend) -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
validateRemovedKeys over the hooks and cronJobs of one scope: deploymentName
empty at root scope, the workload's key at workload scope (jobValuesPath).
keys are the removed job keys; the volume keys apply too.
*/}}
{{- define "global-chart.rejectRemovedJobKeys" -}}
{{- $args := . -}}
{{- $jobs := list -}}
{{- if kindIs "map" .cronJobs -}}
  {{- range $name, $job := .cronJobs -}}
    {{- $jobs = append $jobs (dict "job" $job "errCtx" (include "global-chart.jobValuesPath" (dict "kind" "cronjob" "deploymentName" $args.deploymentName "jobName" $name))) -}}
  {{- end -}}
{{- end -}}
{{- if kindIs "map" .hooks -}}
  {{- range $type, $byName := .hooks -}}
    {{- if kindIs "map" $byName -}}
      {{- range $name, $job := $byName -}}
        {{- $jobs = append $jobs (dict "job" $job "errCtx" (include "global-chart.jobValuesPath" (dict "kind" "hook" "deploymentName" $args.deploymentName "hookType" $type "jobName" $name))) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- range $jobs -}}
  {{- include "global-chart.rejectRemovedKeys" (dict "map" .job "errCtx" .errCtx "in" $args.in "keys" $args.keys) -}}
  {{- if kindIs "map" .job -}}
    {{- include "global-chart.rejectRemovedVolumeKeys" (dict "volumes" .job.volumes "errCtx" .errCtx "in" $args.in "see" $args.see) -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
validateRemovedKeys over the volumes of one pod spec, errCtx its owner's path
(issue #230): the legacy `type`, of any value, and the `name` aliases of
secret and persistentVolumeClaim.
*/}}
{{- define "global-chart.rejectRemovedVolumeKeys" -}}
{{- $args := . -}}
{{- if kindIs "slice" .volumes -}}
  {{- range $i, $vol := .volumes -}}
    {{- $ctx := printf "%s.volumes[%d]" $args.errCtx $i -}}
    {{- include "global-chart.rejectRemovedKeys" (dict "map" $vol "errCtx" $ctx "in" $args.in "keys" (dict "type" "the native volume source without type (emptyDir: {}, configMap.name, secret.secretName, persistentVolumeClaim.claimName)") "see" $args.see) -}}
    {{- if kindIs "map" $vol -}}
      {{- range $key, $field := dict "secret" "secretName" "persistentVolumeClaim" "claimName" -}}
        {{- include "global-chart.rejectRemovedKeys" (dict "map" (get $vol $key) "errCtx" (printf "%s.%s" $ctx $key) "in" $args.in "keys" (dict "name" (printf "%s.%s" $key $field))) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Fail on the first of keys (old → replacement) that map carries:
"<values path>: removed in <in>, use <replacement>", and "; see <see>" when
the replacement takes more than a key to explain (CODING_STANDARDS.md). A map
of another type carries no key. Read only by validateRemovedKeys and its two
helpers above.
*/}}
{{- define "global-chart.rejectRemovedKeys" -}}
{{- $args := . -}}
{{- if kindIs "map" .map -}}
  {{- range $old, $new := .keys -}}
    {{- if hasKey $args.map $old -}}
      {{- $path := ternary $old (printf "%s.%s" $args.errCtx $old) (eq $args.errCtx "") -}}
      {{- fail (printf "%s: removed in %s, use %s%s" $path $args.in $new (ternary (printf "; see %s" $args.see) "" (hasKey $args "see"))) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Fail on a null item in any list under a values node, at any depth, naming its
path (issue #198): the single home of "a null list item fails", passthrough
surfaces included — a list the chart hands to a manifest verbatim (tolerations,
extraContainers, a container's args) is no more valid with a null in it. A null
map value is left alone: it is unset, for the chart as for the API server.
Recursive: a map recurses into each value, a list into each item.
Usage: {{- include "global-chart.rejectNullInLists" (dict "value" .Values.workloads "errCtx" "workloads") -}}
*/}}
{{- define "global-chart.rejectNullInLists" -}}
{{- $errCtx := .errCtx -}}
{{- if kindIs "slice" .value -}}
  {{- range $i, $item := .value -}}
    {{- $itemCtx := printf "%s[%d]" $errCtx $i -}}
    {{- include "global-chart.rejectNull" (dict "value" $item "errCtx" $itemCtx) -}}
    {{- include "global-chart.rejectNullInLists" (dict "value" $item "errCtx" $itemCtx) -}}
  {{- end -}}
{{- else if kindIs "map" .value -}}
  {{- range $key, $item := .value -}}
    {{- include "global-chart.rejectNullInLists" (dict "value" $item "errCtx" (ternary $key (printf "%s.%s" $errCtx $key) (eq $errCtx ""))) -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Validate that no list in values carries a null item, and that no item of a list
the chart reads carries a null in a field it needs (issue #198). Two parts:
- rejectNullInLists over the whole of .Values: a null item fails anywhere,
  passthrough lists included, naming its path;
- the required fields of the items the pod-spec helpers read —
  imagePullSecrets, volumes, volumeMounts, externalSecrets, dnsConfig.options,
  a workload's service.extraPorts and mountedConfigFiles — for every owner
  podSpecOwners lists, plus global.imagePullSecrets and rbacs.roles.
Those helpers skip a null item or field instead of reading through it, so this
is the one error such a null reaches, whatever order Helm renders the templates
in (isNamedEntry is their skip). Runs first in validate.yaml. A root-level list
only one template reads (ingress, externalSecrets data, keda triggers, route
rules) gets its required fields checked by that template, which has the path at
hand.
Called from validate.yaml. Emits nothing on success.
*/}}
{{- define "global-chart.validateNullItems" -}}
{{- include "global-chart.rejectNullInLists" (dict "value" .Values "errCtx" "") -}}
{{- include "global-chart.rejectNullItems" (dict "list" (default (dict) .Values.global).imagePullSecrets "errCtx" "global.imagePullSecrets" "required" (list "name")) -}}
{{- include "global-chart.rejectNullItems" (dict "list" (default (dict) .Values.rbacs).roles "errCtx" "rbacs.roles" "required" (list "name")) -}}
{{- range $owner := (include "global-chart.podSpecOwners" . | fromJsonArray) -}}
  {{- $spec := $owner.spec -}}
  {{- $path := $owner.path -}}
  {{- range $field, $required := dict "imagePullSecrets" (list "name") "volumes" (list "name") "volumeMounts" (list "name" "mountPath") "externalSecrets" (list "name") "volumeClaimTemplates" (list "name" "size") -}}
    {{- include "global-chart.rejectNullItems" (dict "list" (index $spec $field) "errCtx" (printf "%s.%s" $path $field) "required" $required) -}}
  {{- end -}}
  {{- include "global-chart.rejectNullItems" (dict "list" (default (dict) $spec.dnsConfig).options "errCtx" (printf "%s.dnsConfig.options" $path) "required" (list "name")) -}}
  {{- if eq $owner.kind "workload" -}}
    {{- include "global-chart.rejectNullItems" (dict "list" (default (dict) $spec.service).extraPorts "errCtx" (printf "%s.service.extraPorts" $path) "required" (list "name" "port" "targetPort")) -}}
    {{- $mcf := default (dict) $spec.mountedConfigFiles -}}
    {{- include "global-chart.rejectNullItems" (dict "list" $mcf.files "errCtx" (printf "%s.mountedConfigFiles.files" $path) "required" (list "name")) -}}
    {{- include "global-chart.rejectNullItems" (dict "list" $mcf.bundles "errCtx" (printf "%s.mountedConfigFiles.bundles" $path) "required" (list "name")) -}}
    {{- range $bi, $b := (default (list) $mcf.bundles) -}}
      {{- include "global-chart.rejectNullItems" (dict "list" (default (dict) $b).files "errCtx" (printf "%s.mountedConfigFiles.bundles[%d].files" $path $bi) "required" (list "name")) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Validate that all generated resource names are unique after truncation.
Checks within each resource kind: workloads, CronJobs, Jobs (hooks),
ServiceAccounts, ConfigMaps, Secrets, ExternalSecrets, TriggerAuthentications,
HTTPRoutes, TCPRoutes and UDPRoutes,
Roles and RoleBindings, the hook-prerequisite copies included.
A kind's accumulator holds every name of that kind whatever derived it, because
collisions cross sources: $cmNames carries the workload's own ConfigMap, its
mounted config file ConfigMaps and its hook-prerequisite copy alike. A
workload named `<other>-md-cm-<file>` renders a ConfigMap under the very name
another workload's mounted file does — two manifests, one name, neither
invalid on its own.
Note: the remaining per-workload resources (Service, SA, HPA, ScaledObject,
PDB, NetworkPolicy) share the workload's own name, so the workload name
check covers them. The one other name that can reach them is a StatefulSet's
headless Service, a Service only: it goes in $svcNames with every rendered
normal Service, so an entry named after it collides only when that entry
renders a Service of its own (issue #222).
Called from validate.yaml.
*/}}
{{- define "global-chart.validateNameCollisions" -}}
{{- $root := . -}}
{{- $deployNames := dict -}}
{{- $svcNames := dict -}}
{{- $cronNames := dict -}}
{{- $hookNames := dict -}}
{{- $cmNames := dict -}}
{{- $secretNames := dict -}}
{{- $saNames := dict -}}
{{- $esNames := dict -}}
{{- $esOwnedNames := dict -}}

{{- /* 1. Workload resource names (trunc 63) */ -}}
{{- range $name, $deploy := .Values.workloads -}}
  {{- if $deploy -}}
  {{- if eq (include "global-chart.deploymentEnabled" $deploy) "true" -}}
    {{- $depFullname := include "global-chart.deploymentFullname" (dict "root" $root "deploymentName" $name) -}}
    {{- include "global-chart.registerName" (dict "names" $deployNames "kind" (include "global-chart.workloadKind" $deploy) "name" $depFullname "owner" (include "global-chart.deploymentValuesPath" $name)) -}}
    {{- /* A StatefulSet's headless Service, <name>-headless, is a name another
           entry's own name can reach. It clashes only with a Service, so it goes
           in $svcNames beside the normal Services, not in $deployNames. */ -}}
    {{- if eq (include "global-chart.serviceEnabled" (default (dict) $deploy.service)) "true" -}}
      {{- include "global-chart.registerName" (dict "names" $svcNames "kind" "Service" "name" $depFullname "owner" (printf "%s.service" (include "global-chart.deploymentValuesPath" $name))) -}}
    {{- end -}}
    {{- if include "global-chart.isStatefulSet" $deploy -}}
      {{- include "global-chart.registerName" (dict "names" $svcNames "kind" "Service" "name" (include "global-chart.headlessServiceName" (dict "root" $root "deploymentName" $name)) "owner" (printf "%s (its headless Service)" (include "global-chart.deploymentValuesPath" $name))) -}}
    {{- end -}}

    {{- /* The workload's own ConfigMap and Secret both carry $depFullname. They
           cannot clash with each other or with another workload's — the name
           check above covers that — but they share $cmNames/$secretNames with the
           mounted config file copies and the hook-prerequisite copies, whose names
           are built by appending a suffix and so CAN land on a plain workload
           name. */ -}}
    {{- if $deploy.configMap -}}
      {{- include "global-chart.registerName" (dict "names" $cmNames "kind" "ConfigMap" "name" $depFullname "owner" (printf "%s.configMap" (include "global-chart.deploymentValuesPath" $name))) -}}
    {{- end -}}
    {{- if $deploy.secret -}}
      {{- include "global-chart.registerName" (dict "names" $secretNames "kind" "Secret" "name" $depFullname "owner" (printf "%s.secret" (include "global-chart.deploymentValuesPath" $name))) -}}
    {{- end -}}

    {{- /* Chart-created workload ServiceAccount: a root-level job that creates its
           own SA can land on this very name (both are <release>-<chart>-<key>) */ -}}
    {{- $deploySA := include "global-chart.deploymentServiceAccount" (dict "root" $root "deploymentName" $name "deployment" $deploy) | fromJson -}}
    {{- include "global-chart.registerSAName" (dict "names" $saNames "sa" $deploySA "owner" (include "global-chart.deploymentValuesPath" $name)) -}}

    {{- /* 1a. Workload-scope CronJob names (trunc 52) — via deploymentCronJobName helper */ -}}
    {{- range $jobName, $job := $deploy.cronJobs -}}
      {{- if $job -}}
        {{- $jobFullname := include "global-chart.deploymentCronJobName" (dict "root" $root "deploymentName" $name "jobName" $jobName) -}}
        {{- $errCtx := include "global-chart.jobValuesPath" (dict "kind" "cronjob" "deploymentName" $name "jobName" $jobName) -}}
        {{- include "global-chart.registerName" (dict "names" $cronNames "kind" "CronJob" "name" $jobFullname "owner" $errCtx) -}}
        {{- $jobSA := include "global-chart.jobServiceAccount" (dict "root" $root "job" $job "deploy" $deploy "deployName" $name "jobFullname" $jobFullname "errCtx" $errCtx) | fromJson -}}
        {{- include "global-chart.registerSAName" (dict "names" $saNames "sa" $jobSA "owner" $errCtx) -}}
      {{- end -}}
    {{- end -}}

    {{- /* 1b. Workload-scope Hook names (trunc 63) + prerequisite ConfigMap/Secret */ -}}
    {{- if $deploy.hooks -}}
      {{- /* Hook prerequisite ConfigMap (trunc 63) */ -}}
      {{- $hasDeployConfigMap := and $deploy.configMap (gt (len $deploy.configMap) 0) -}}
      {{- if $hasDeployConfigMap -}}
        {{- $hookConfigName := include "global-chart.hookPrereqConfigName" (dict "deploymentFullname" $depFullname) -}}
        {{- include "global-chart.registerName" (dict "names" $cmNames "kind" "ConfigMap" "name" $hookConfigName "owner" (printf "%s.configMap (hook prerequisite copy)" (include "global-chart.deploymentValuesPath" $name))) -}}
      {{- end -}}

      {{- /* Hook prerequisite Secret (trunc 63) */ -}}
      {{- $hasDeploySecret := and $deploy.secret (gt (len $deploy.secret) 0) -}}
      {{- if $hasDeploySecret -}}
        {{- $hookSecretName := include "global-chart.hookPrereqSecretName" (dict "deploymentFullname" $depFullname) -}}
        {{- include "global-chart.registerName" (dict "names" $secretNames "kind" "Secret" "name" $hookSecretName "owner" (printf "%s.secret (hook prerequisite copy)" (include "global-chart.deploymentValuesPath" $name))) -}}
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
           last. Registered in $cmNames, which also catches two workloads
           truncating to the same $depFullname. */ -}}
    {{- $mcf := default (dict) $deploy.mountedConfigFiles -}}
    {{- $mcHint := ". Give one of the two entries a different 'name'." -}}
    {{- /* A null file or bundle, or a null name, is validateNullItems' to report */ -}}
    {{- range $i, $f := (default (list) $mcf.files) -}}
      {{- if include "global-chart.isNamedEntry" $f -}}
      {{- $owner := printf "%s.mountedConfigFiles.files[%d] ('%s')" (include "global-chart.deploymentValuesPath" $name) $i $f.name -}}
      {{- include "global-chart.registerName" (dict "names" $cmNames "kind" "ConfigMap" "name" (include "global-chart.mountedConfigMapName" (dict "deploymentFullname" $depFullname "fileName" $f.name)) "owner" $owner "hint" $mcHint) -}}
      {{- end -}}
    {{- end -}}
    {{- range $bi, $b := (default (list) $mcf.bundles) -}}
      {{- range $fi, $f := (default (list) (default (dict) $b).files) -}}
        {{- if include "global-chart.isNamedEntry" $f -}}
        {{- $owner := printf "%s.mountedConfigFiles.bundles[%d].files[%d] ('%s')" (include "global-chart.deploymentValuesPath" $name) $bi $fi $f.name -}}
        {{- include "global-chart.registerName" (dict "names" $cmNames "kind" "ConfigMap" "name" (include "global-chart.mountedConfigMapName" (dict "deploymentFullname" $depFullname "fileName" $f.name)) "owner" $owner "hint" $mcHint) -}}
        {{- end -}}
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
       $copyTargets, so that two of them still never meet each other. A target
       whose policy rewrites the Secret's data — Owner, the copy's included,
       and Orphan — also joins $secretNames, against the chart's own Secrets:
       Owner adopts a Helm Secret, the two overwrite each other's data and the
       ExternalSecret's deletion garbage-collects it (issue #153); Orphan
       fights the same way without the garbage collection (issue #161). Merge,
       CreateOrMerge and None stay out: Helm's patch keeps the keys the first
       two add, and None writes nothing (ADR 0013,
       docs/adr/0013-an-owner-externalsecret-target-cannot-be-a-chart-secret.md). */ -}}
{{- $consumers := include "global-chart.externalSecretHookConsumers" $root | fromJson -}}
{{- range $key, $secret := .Values.externalSecrets -}}
  {{- if $secret -}}
    {{- $nameCtx := dict "root" $root "key" $key "secret" $secret -}}
    {{- $owner := printf "externalSecrets.%s" $key -}}
    {{- include "global-chart.registerName" (dict "names" $esNames "kind" "ExternalSecret" "name" (include "global-chart.externalSecretName" $nameCtx) "owner" $owner) -}}
    {{- $target := include "global-chart.externalSecretTargetName" $nameCtx -}}
    {{- if eq (include "global-chart.externalSecretCreationPolicy" $secret) "Owner" -}}
      {{- include "global-chart.registerName" (dict "names" $esOwnedNames "kind" "Secret" "name" $target "owner" $owner) -}}
    {{- end -}}
    {{- if eq (include "global-chart.externalSecretRewritesTarget" $secret) "true" -}}
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

{{- /* 5b. Gateway API routes (trunc 63, issues #194, #195), one accumulator
       per kind: a TCPRoute and a UDPRoute may share a name, two TCPRoutes may
       not, and two keys sharing a long prefix truncate to one. The HTTPRoutes:
       the single httpRoute is the fullname itself, which an httpRoutes key can
       truncate back onto */ -}}
{{- $httpRouteNames := dict -}}
{{- range (include "global-chart.httpRouteEntries" $root | fromJsonArray) -}}
  {{- include "global-chart.registerName" (dict "names" $httpRouteNames "kind" "HTTPRoute" "name" .name "owner" .errCtx) -}}
{{- end -}}
{{- range (include "global-chart.l4RouteKinds" $root | fromJsonArray) -}}
  {{- $routeNames := dict -}}
  {{- $kind := .kind -}}
  {{- $field := .field -}}
  {{- range $key, $route := (index $root.Values $field) -}}
    {{- if not (kindIs "invalid" $route) -}}
    {{- include "global-chart.registerName" (dict "names" $routeNames "kind" $kind "name" (include "global-chart.gatewayRouteName" (dict "root" $root "key" $key)) "owner" (printf "%s.%s" $field $key)) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{- /* 6. rbacs.roles (issue #122): the Role name is used verbatim, the RoleBinding
       drops a trailing -role, and the default <name>-sa is truncated — each can
       land on another entry's. The SA joins $saNames, against every other
       chart-created one. */ -}}
{{- $roleNames := dict -}}
{{- $bindingNames := dict -}}
{{- range $i, $role := (default (dict) .Values.rbacs).roles -}}
  {{- /* A null role or name is rbac.yaml's and validateNullItems' to report */ -}}
  {{- if include "global-chart.isNamedEntry" $role -}}
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
  {{- if and (include "global-chart.isNamedEntry" $role) (hasKey $rbacConsumers $role.name) -}}
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
the workload's, is the normal way to share an identity. The hook-prerequisite
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
The rules of a StatefulSet's name and claim templates (ADR 0020), for every
enabled entry with kind: StatefulSet:
- <fullname>-<key> is at most 52 characters, checked before the 63-character
  cut. Every pod carries controller-revision-hash: <name>-<hash>, the hash a
  decimal uint32 of up to 10 characters, and a label value holds 63: past 52 a
  pod is created or not depending on the hash. Truncating only the StatefulSet
  would split its name from its Service and HPA, so it fails instead;
- a claim template becomes a pod volume of its own name, so it must not take a
  name podVolumeNames lists (an externalSecrets volume is resolveExternalSecretRefs'
  to check, in workload.yaml);
- some container mounts it (the main one, extraContainers, extraInitContainers),
  or the claim is storage provisioned and never used. A mount with no name could
  be any claim's: its null is validateNullItems', and this check stands down.
Unnamed claim templates are skipped (isNamedEntry), as validateNullItems names them.
Called from validate.yaml. Emits nothing on success.
*/}}
{{- define "global-chart.validateStatefulSets" -}}
{{- $root := . -}}
{{- range $name, $deploy := .Values.workloads -}}
  {{- if $deploy -}}
  {{- if and (eq (include "global-chart.deploymentEnabled" $deploy) "true") (include "global-chart.isStatefulSet" $deploy) -}}
    {{- $errCtx := include "global-chart.deploymentValuesPath" $name -}}
    {{- $stsName := include "global-chart.deploymentUntruncatedName" (dict "root" $root "deploymentName" $name) -}}
    {{- if gt (len $stsName) 52 -}}
      {{- fail (printf "%s: a StatefulSet name is at most 52 characters, and '%s' has %d. The pods' controller-revision-hash label appends up to 11 to it, within the 63 of a label value. Shorten the key, or the fullname with fullnameOverride." $errCtx $stsName (len $stsName)) -}}
    {{- end -}}
    {{- $volumeNames := include "global-chart.podVolumeNames" (dict "values" $deploy "errCtx" $errCtx) | fromJson -}}
    {{- $mountNames := dict -}}
    {{- $unnamedMount := false -}}
    {{- range $c := concat (list $deploy) (default (list) $deploy.extraContainers) (default (list) $deploy.extraInitContainers) -}}
      {{- range (default (list) (default (dict) $c).volumeMounts) -}}
        {{- if include "global-chart.isNamedEntry" . -}}
          {{- $_ := set $mountNames .name true -}}
        {{- else -}}
          {{- $unnamedMount = true -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
    {{- range $i, $claim := (default (list) $deploy.volumeClaimTemplates) -}}
      {{- if include "global-chart.isNamedEntry" $claim -}}
        {{- if hasKey $volumeNames $claim.name -}}
          {{- fail (printf "%s.volumeClaimTemplates[%d]: '%s' is also the name of the pod volume of %s, and the claim becomes a pod volume of that name. Rename one of them." $errCtx $i $claim.name (index $volumeNames $claim.name)) -}}
        {{- end -}}
        {{- if not (or $unnamedMount (hasKey $mountNames $claim.name)) -}}
          {{- fail (printf "%s.volumeClaimTemplates[%d]: '%s' is mounted by no volumeMounts item of the pod's containers. Mount it, or drop the entry." $errCtx $i $claim.name) -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Validate that the fullname fits the names it ends up leading (issue #120).
The fullname heads every generated name, and most of them are DNS subdomains,
which take anything Helm's release-name rule or the schema's override patterns
let through. Two kinds of name are stricter, and only some releases render them:
- a container name is a DNS-1123 label, so no dot. The fullname heads the
  container name of every enabled workload and of every root-level hook;
- a Service name is a DNS-1035 label, so it also starts with a letter. The
  fullname heads the name of every enabled workload's Service.
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
{{- range $name, $deploy := .Values.workloads -}}
  {{- if $deploy -}}
  {{- if eq (include "global-chart.deploymentEnabled" $deploy) "true" -}}
    {{- $label = include "global-chart.deploymentValuesPath" $name -}}
    {{- if eq (include "global-chart.serviceEnabled" (default (dict) $deploy.service)) "true" -}}
      {{- $service = include "global-chart.deploymentValuesPath" $name -}}
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
Fail unless a CRD the release renders is registered in the target cluster: the
single home of the capability check every opt-in custom resource goes through
(KEDA through requireKedaCrd, the Gateway API routes through
requireGatewayApiCrd). Without it the failure surfaces at apply as
the API server's "no matches for kind", which names neither the values key nor
the remedy.
.Capabilities.APIVersions carries the cluster's CRDs only during
install/upgrade; `helm template` and `helm lint` see the built-in set alone, so
an offline render needs `--api-versions <apiVersion>` (HELM_API_VERSIONS in the
Makefile, `capabilities.apiVersions` in the unit-test suites).
Params:
  root       - the chart context
  apiVersion - what .Capabilities.APIVersions.Has is asked: "group/version", or
               "group/version/Kind" when one version serves kinds a cluster may
               lack (TCPRoute and UDPRoute reach Gateway API v1 later than
               HTTPRoute)
  install    - the remedy, a sentence head ("Install KEDA")
  errCtx     - values path of the resource; leads the message
Usage: {{- include "global-chart.requireCrd" (dict "root" $root "apiVersion" "keda.sh/v1alpha1" "install" "Install KEDA" "errCtx" "workloads.foo.keda") -}}
*/}}
{{- define "global-chart.requireCrd" -}}
{{- $apiVersion := required "requireCrd: apiVersion is required" .apiVersion -}}
{{- if not (.root.Capabilities.APIVersions.Has $apiVersion) -}}
{{- fail (printf "%s: needs the CRD %s, which is not registered in the cluster. %s before installing this release, or render offline with --api-versions %s." (required "requireCrd: errCtx is required (the values path of the resource)" .errCtx) $apiVersion (required "requireCrd: install is required" .install) $apiVersion) -}}
{{- end -}}
{{- end }}

{{/*
requireCrd for a Gateway API route kind (issues #194, #196): the single home of
the group and version the chart renders (gateway.networking.k8s.io/v1, checked
per kind) and of the first Gateway API release serving each kind there, read
from the release manifests: HTTPRoute v1.0.0, TCPRoute and UDPRoute v1.6.0
(up to v1.5 they are v1alpha2, experimental only). A new kind is a row here.
Usage: {{- include "global-chart.requireGatewayApiCrd" (dict "root" $root "kind" "TCPRoute" "errCtx" "tcpRoutes.gps") -}}
*/}}
{{- define "global-chart.requireGatewayApiCrd" -}}
{{- $since := dict "HTTPRoute" "v1.0.0" "TCPRoute" "v1.6.0" "UDPRoute" "v1.6.0" -}}
{{- $kind := required "requireGatewayApiCrd: kind is required" .kind -}}
{{- if not (hasKey $since $kind) -}}
  {{- fail (printf "requireGatewayApiCrd: no release is known for kind %q; add its row" $kind) -}}
{{- end -}}
{{- include "global-chart.requireCrd" (dict "root" .root "apiVersion" (printf "gateway.networking.k8s.io/v1/%s" $kind) "install" (printf "Install the Gateway API CRDs, release %s or later (the first to serve %s at v1)," (index $since $kind) $kind) "errCtx" .errCtx) -}}
{{- end }}

{{/*
Validate that the Ingress and the HTTPRoutes are not both rendered.
The chart supports one HTTP routing layer per release: the Ingress, or the
HTTPRoutes (the single httpRoute and the httpRoutes entries alike, listed by
httpRouteEntries — two forms of one layer, so they coexist). Both would answer
the same hostnames from two places. The L4 routes (tcpRoutes, udpRoutes) are
not a routing layer and coexist with either.
Called from validate.yaml. Emits nothing on success.
*/}}
{{- define "global-chart.validateRoutingConflict" -}}
{{- $ing := default (dict) .Values.ingress -}}
{{- if $ing.enabled -}}
  {{- with (include "global-chart.httpRouteEntries" . | fromJsonArray) -}}
    {{- $first := first . -}}
    {{- if $first.single -}}
      {{- fail "Both .Values.ingress.enabled and .Values.httpRoute.enabled are true. The chart supports only one HTTP routing layer per release. Disable one (set enabled: false) to proceed." -}}
    {{- end -}}
    {{- fail (printf "Both .Values.ingress.enabled and .Values.%s are set. The chart supports only one HTTP routing layer per release, and every httpRoutes entry is part of it. Disable the ingress, or drop the httpRoutes entries." $first.errCtx) -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
The active HPA targets of a workload's `autoscaling` map, as JSON: the ONE
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
Validate that a workload does not enable both the native HPA and KEDA, and
that an enabled HPA has an active target.
KEDA creates and owns its own HorizontalPodAutoscaler (the *derived HPA*) for
every ScaledObject, so a chart-rendered HPA on the same workload gives two
controllers writing spec.replicas.
The workload drops spec.replicas whenever autoscaling is enabled, so with no
active target neither side owns the count and Kubernetes defaults it to one
pod (issue #151, ADR 0012). The KEDA conflict fails first: it is the more
fundamental error, and fixing it can make the other moot.
Called from validate.yaml. Emits nothing on success.
*/}}
{{- define "global-chart.validateAutoscalingConflict" -}}
{{- range $name, $deploy := .Values.workloads -}}
  {{- if $deploy -}}
  {{- if eq (include "global-chart.deploymentEnabled" $deploy) "true" -}}
    {{- $hpa := default (dict) $deploy.autoscaling -}}
    {{- $keda := default (dict) $deploy.keda -}}
    {{- if and $hpa.enabled $keda.enabled -}}
      {{- fail (printf "%s.autoscaling.enabled: true together with keda.enabled, and the two are mutually exclusive. KEDA creates and owns its own HorizontalPodAutoscaler for the ScaledObject; a chart-rendered HPA on the same workload would fight it. Disable one of the two." (include "global-chart.deploymentValuesPath" $name)) -}}
    {{- end -}}
    {{- if and $hpa.enabled (not (include "global-chart.hpaActiveTargets" $hpa | fromJson)) -}}
      {{- fail (printf "%s.autoscaling: enabled, but neither targetCPUUtilizationPercentage nor targetMemoryUtilizationPercentage is a positive number; without one no HPA renders and the workload runs a single replica. Set a target or disable autoscaling." (include "global-chart.deploymentValuesPath" $name)) -}}
    {{- end -}}
  {{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Fail a PDB whose minAvailable allows no voluntary eviction at the replica
owner's floor (issue #216, ADR 0021): kubectl drain and cluster-autoscaler
scale-down never finish on the node, and Kubernetes accepts the manifest in
silence.
- Only the form whose effect depends on the count fails: minAvailable as an
  integer >= the floor, or a percentage below 100% that rounds up to it.
  maxUnavailable: 0, "0%" and minAvailable: "100%" block at any count and are
  taken as meant; maxUnavailable never fails;
- percentages round up, as the disruption controller does
  (GetScaledValueFromIntOrPercent(…, true));
- the floor comes from replicaFloor, where an autoscaled workload idles. A
  floor of 0 skips the check: a workload with no pods blocks nothing.
shortcut: a KEDA floor of 0 skips the check though the workload blocks at 1
pod, upgrade if a scale-to-zero workload reports a stuck drain.
shortcut: under --skip-schema-validation a string count or a minAvailable digit
string with no "%" skips the check, as the schema rejects both, upgrade if
either gets a fallback guard.
Called from pdb.yaml, after minAvailable has gone through printScalar, so a
null has already failed naming its key. Emits nothing on success.
Usage: {{- include "global-chart.validatePdbEvictions" (dict "deploy" $deploy "pdb" $pdb "errCtx" $errCtx) }}
*/}}
{{- define "global-chart.validatePdbEvictions" -}}
{{- $floor := include "global-chart.replicaFloor" (dict "deploy" .deploy "errCtx" .errCtx) | fromJson -}}
{{- $min := .pdb.minAvailable -}}
{{- if and (kindIs "float64" $floor.count) (ge (int $floor.count) 1) (not (kindIs "invalid" $min)) -}}
  {{- $count := int $floor.count -}}
  {{- $needed := -1 -}}
  {{- if kindIs "string" $min -}}
    {{- $pct := trimSuffix "%" $min | atoi -}}
    {{- if and (hasSuffix "%" $min) (lt $pct 100) -}}
      {{- $needed = div (add (mul $pct $count) 99) 100 -}}
    {{- end -}}
  {{- else -}}
    {{- $needed = int $min -}}
  {{- end -}}
  {{- if ge $needed $count -}}
    {{- $at := ternary (printf "the default of %d replicas" $count) (printf "%s: %d" $floor.path $count) $floor.default -}}
    {{- fail (printf "%s.pdb.minAvailable: %s allows no voluntary eviction with %s, so kubectl drain and cluster-autoscaler scale-down never finish on its node. Lower it, or set maxUnavailable: 0 instead to block evictions on purpose." .errCtx (include "global-chart.printScalar" $min) $at) -}}
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
{{- range $name, $deploy := .Values.workloads -}}
  {{- if $deploy -}}
  {{- if eq (include "global-chart.deploymentEnabled" $deploy) "true" -}}
    {{- $svc := default (dict) $deploy.service -}}
    {{- if eq (include "global-chart.serviceEnabled" $svc) "true" -}}
      {{- $declared := dict -}}
      {{- $errCtx := include "global-chart.deploymentValuesPath" $name -}}
      {{- $svcCtx := dict "service" $svc "errCtx" (printf "%s.service" $errCtx) -}}
      {{- range (include "global-chart.containerPorts" $svcCtx | fromJsonArray) -}}
        {{- $_ := set $declared .name true -}}
      {{- end -}}
      {{- $known := keys $declared | sortAlpha | join ", " -}}
      {{- $targetPort := (include "global-chart.servicePrimaryPort" $svcCtx | fromJson).targetPort -}}
      {{- if and (hasKey $svc "targetPort") (kindIs "string" $svc.targetPort) (not (hasKey $declared $targetPort)) -}}
        {{- fail (printf "%s.service.targetPort: names the port '%s', which no container port declares (declared: %s). A Service port whose targetPort names nothing gets no endpoints. Use the port number, or a name one of the declared ports carries." (include "global-chart.deploymentValuesPath" $name) $targetPort $known) -}}
      {{- end -}}
      {{- range $i, $port := (default (list) $svc.extraPorts) -}}
        {{- if and (kindIs "string" $port.targetPort) (not (hasKey $declared $port.targetPort)) -}}
          {{- fail (printf "%s.service.extraPorts[%d].targetPort: names the port '%s', which no container port declares (declared: %s). A Service port whose targetPort names nothing gets no endpoints. Give it the port number instead, and it will be declared on the container under this name." $errCtx $i $port.targetPort $known) -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Validate the Service side of a workload's ports against what the API server
rejects (issue #155): an extraPorts entry may not repeat a port name or a
port+protocol pair of the primary port or of another entry, and may carry
nodePort only on a NodePort or LoadBalancer Service.

A template fail, not the schema: the primary port's defaults live in
servicePrimaryPort, an extra port's protocol in extraPortProtocol and the type
in serviceType, and the schema sees none of them. The ports come from
servicePorts, the one enumeration of the Service side. The pod side dedups in
containerPorts; the Service side has nothing to dedup into, since every port is
rendered.
Called from validate.yaml. Emits nothing on success.
*/}}
{{- define "global-chart.validateServicePorts" -}}
{{- range $name, $deploy := .Values.workloads -}}
  {{- if $deploy -}}
  {{- if eq (include "global-chart.deploymentEnabled" $deploy) "true" -}}
    {{- $svc := default (dict) $deploy.service -}}
    {{- if eq (include "global-chart.serviceEnabled" $svc) "true" -}}
      {{- $errCtx := include "global-chart.deploymentValuesPath" $name -}}
      {{- $type := include "global-chart.serviceType" $svc -}}
      {{- $portNames := dict -}}
      {{- $portNumbers := dict -}}
      {{- range (include "global-chart.servicePorts" (dict "service" $svc "errCtx" (printf "%s.service" $errCtx)) | fromJsonArray) -}}
        {{- $number := printf "%s/%s" (include "global-chart.printScalar" .port) .protocol -}}
        {{- if lt (int .index) 0 -}}
          {{- $_ := set $portNames .name "service.portName" -}}
          {{- $_ := set $portNumbers $number "service.port" -}}
          {{- continue -}}
        {{- end -}}
        {{- $owner := printf "extraPorts[%d]" (int .index) -}}
        {{- $entry := index $svc.extraPorts (int .index) -}}
        {{- if and (hasKey $entry "nodePort") (not (has $type (list "NodePort" "LoadBalancer"))) -}}
          {{- fail (printf "%s.service.%s.nodePort: set on a %s Service, which the API server rejects: only a NodePort or LoadBalancer Service takes a nodePort. Drop nodePort, or set service.type." $errCtx $owner $type) -}}
        {{- end -}}
        {{- if hasKey $portNames .name -}}
          {{- fail (printf "%s.service.%s.name: '%s' repeats the port name of %s. The API server rejects two Service ports with one name." $errCtx $owner .name (get $portNames .name)) -}}
        {{- end -}}
        {{- if hasKey $portNumbers $number -}}
          {{- fail (printf "%s.service.%s.port: %s repeats the port and protocol of %s. The API server rejects two Service ports with one port and protocol." $errCtx $owner $number (get $portNumbers $number)) -}}
        {{- end -}}
        {{- $_ := set $portNames .name $owner -}}
        {{- $_ := set $portNumbers $number $owner -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Validate that no two mounts of a container land on one mountPath (issue #182).
The API server rejects the pod at apply ("must be unique"), which under Argo CD
surfaces as a failed sync well after lint and template have passed. It compares
the mountPath strings as written, and so does this check: /etc/app and
/etc/app/ are two paths to both, a nested path (/etc/app and /etc/app/a.conf)
is legal, and the subPath plays no part. Only the main container:
extraContainers and init containers carry their own volumeMounts verbatim.
An empty path is skipped: the schema, or the source's required, reports it.
Called from containerVolumeMounts, the single home of the list. Emits nothing
on success.
Params:
  errCtx - values path of the container's owner
  mounts - list of {mount (a volumeMount map), owner (its values path, relative to errCtx)}
*/}}
{{- define "global-chart.validateMountPaths" -}}
{{- $seen := dict -}}
{{- range .mounts -}}
  {{- /* A null mount is validateNullItems' to report */ -}}
  {{- $path := (default (dict) .mount).mountPath | default "" | toString -}}
  {{- if $path -}}
    {{- if hasKey $seen $path -}}
      {{- fail (printf "%s: %s mounts on '%s', which %s already mounts. The API server rejects two mounts on one path in a container: give each its own mountPath." $.errCtx .owner $path (get $seen $path)) -}}
    {{- end -}}
    {{- $_ := set $seen $path .owner -}}
  {{- end -}}
{{- end -}}
{{- end }}
