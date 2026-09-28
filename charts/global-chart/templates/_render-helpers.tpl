{{/*
Rendering helpers for global-chart: blocks shared by more than one template, so
each is written once. Rules of the file:
- Every scalar printed from values goes through printScalar (below, issue #132).
  A helper that returns JSON hands its numbers back as float64, so its caller
  prints them through printScalar too.
- A helper that can render nothing is wrapped by its caller in {{- with }}.
- The ConfigMap/Secret data bodies are shared with the hook-prerequisite copies
  (ADR 0005); the ExternalSecret spec with its copy (ADR 0007).
- The primary port has one source per side: servicePrimaryPort for the Service,
  containerPorts for the pod (issue #82).
*/}}

{{/*
Print a scalar read from values. The rule: every number printed from values
goes through this helper — never a bare {{ $x.field }}, never toString or
printf "%v" of a values-derived scalar, and never a site-local int64/%d
(jobSpecVerbatimFields included, issue #132). The rule is about printing: a
cast used only to compute (the hook weight arithmetic in _hook-helpers.tpl) is
outside it: the int64 such a cast produces already prints in plain digits. Integer fields print it as is,
string fields pipe it to quote.
Why: Helm reads a number from a values file as a float64, and the template
default format (toString and printf "%v" alike) prints a float64 in exponent
notation from a million upward. In an integer field, 10000000 renders as 1e+07,
which the schema accepts, helm lint passes and the API server rejects. In a
string field it is worse: LIMIT: 10000000 in a ConfigMap renders "1e+07", the
API server accepts it and the application silently reads the wrong value.
--set parses the same number as an int64, so testing with --set hides the
defect; the values file is how the chart is normally used. A port read back
through fromJson is a float64 too. toYaml goes through JSON encoding and is
unaffected, so a block rendered with toYaml needs nothing.
Contract, by kind of value:
- string: returned unchanged, unquoted. Int-or-string fields (pdb
  minAvailable/maxUnavailable, Service targetPort) keep "50%" as 50% and a
  named targetPort as its name, exactly as before.
- float64 with no fractional part, within int64 range: %d after int64, so
  10000000 prints as 10000000.
- any other number (1.5, a float64 beyond int64 range, an int from --set or a
  template literal): toString. 1.5 stays 1.5 — never truncated. A float64
  beyond ±9.2e18 keeps Go's exponent form: int64 cannot hold it, and a YAML
  number that large has already lost its low digits to float64 anyway.
- bool: toString, true/false as before.
- nil: fails. A null that reaches a printed field would otherwise render as
  "<nil>" (toString) or 0 (int64) — a value the user never wrote. The schema
  rejects it; under --skip-schema-validation (tests/bad-values/skip-schema/) a
  null in a key the chart gives no default survives the values merge.
Two forms. A value read straight from values is passed with its path,
(dict "value" $v "errCtx" "<values path>"), and a null fails through
rejectNull naming it (issue #191). A value the chart computed is passed bare:
its helper rejects a null at the source with the path (rejectNullServicePorts,
resolveBackend, rejectNullDataValue), so a null reaching the bare form is a
chart bug, and says so. A value read from values that such a helper has
already checked prints bare too: the Service ports, extraPorts included. The dict form is unambiguous: a scalar is never a map.
Maps and slices are not scalars: callers render them with toYaml.
Usage: {{ include "global-chart.printScalar" (dict "value" $deploy.revisionHistoryLimit "errCtx" (printf "%s.revisionHistoryLimit" $errCtx)) }}
       {{ include "global-chart.printScalar" $primary.port }}
*/}}
{{- define "global-chart.printScalar" -}}
{{- $v := . -}}
{{- if kindIs "map" . -}}
  {{- $v = .value -}}
  {{- include "global-chart.rejectNull" (dict "value" $v "errCtx" (required "printScalar: errCtx is required with the dict form" .errCtx)) -}}
{{- end -}}
{{- if kindIs "invalid" $v -}}
{{- fail "printScalar: a null reached a computed field with no values path, a chart bug: the helper that computed it must reject the null, naming the key." -}}
{{- else if and (kindIs "float64" $v) (eq (floor $v) $v) (lt $v 9.2e18) (gt $v -9.2e18) -}}
{{- printf "%d" (int64 $v) -}}
{{- else -}}
{{- toString $v -}}
{{- end -}}
{{- end }}

{{/*
Fail on a null read from values, naming its path: the single home of the
message, read by printScalar's dict form, servicePrimaryPort and
resolveBackend, rejectNullServicePorts and hook.yaml's weight. A null is a value nobody wrote: printed, it becomes "<nil>" or
0. rejectNullDataValue keeps its own wording for the ConfigMap/Secret maps,
which hold strings only. Renders nothing when the value is set.
Usage: {{- include "global-chart.rejectNull" (dict "value" $v "errCtx" "deployments.web.revisionHistoryLimit") -}}
*/}}
{{- define "global-chart.rejectNull" -}}
{{- if kindIs "invalid" .value -}}
{{- fail (printf "%s: null, a value nobody wrote. Set a value — \"\" for an empty string — or remove the key." .errCtx) -}}
{{- end -}}
{{- end }}

{{/*
Render a single volume entry. Supports both:
- Legacy format: { name, type, secret/configMap/persistentVolumeClaim/emptyDir }
- Native format: { name, <any-k8s-volume-source> } (no .type field)
$defs/volumes stays open (ADR 0017) and requires a non-empty name, so the
required below fires only under --skip-schema-validation, where a fixture in
tests/bad-values/skip-schema/ holds it; the legacy type vocabulary is this
helper's fail, not a schema enum. errCtx is the values path of the entry,
<owner>.volumes[<i>], which leads every fail message (issue #190).
Usage: {{ include "global-chart.renderVolume" (dict "volume" $v "errCtx" (printf "%s.volumes[%d]" $errCtx $i)) }}
*/}}
{{- define "global-chart.renderVolume" -}}
{{- $vol := .volume -}}
{{- $path := required "renderVolume: errCtx is required (the values path of the volume)" .errCtx -}}
- name: {{ required (printf "%s: a volume needs a 'name'" $path) $vol.name }}
{{- if hasKey $vol "type" }}
  {{- /* Legacy format: translate .type to native */ -}}
  {{- if eq $vol.type "emptyDir" }}
  emptyDir: {}
  {{- else if eq $vol.type "configMap" }}
  {{- $src := default (dict) $vol.configMap }}
  configMap:
    name: {{ required (printf "%s.configMap.name: required by the legacy type configMap" $path) $src.name | quote }}
  {{- else if eq $vol.type "secret" }}
  {{- $src := default (dict) $vol.secret }}
  secret:
    secretName: {{ required (printf "%s.secret.secretName: required by the legacy type secret (or secret.name)" $path) (default $src.name $src.secretName) | quote }}
  {{- else if eq $vol.type "persistentVolumeClaim" }}
  {{- $src := default (dict) $vol.persistentVolumeClaim }}
  persistentVolumeClaim:
    claimName: {{ required (printf "%s.persistentVolumeClaim.claimName: required by the legacy type persistentVolumeClaim (or persistentVolumeClaim.name)" $path) (default $src.name $src.claimName) | quote }}
  {{- else }}
  {{- fail (printf "%s.type: unknown legacy volume type '%s'. Supported types: emptyDir, configMap, secret, persistentVolumeClaim. For other volume types, use native Kubernetes volume spec (omit .type)." $path $vol.type) }}
  {{- end }}
{{- else }}
  {{- /* Native format: render everything except name deterministically */ -}}
  {{- $native := omit $vol "name" -}}
  {{- toYaml $native | nindent 2 }}
{{- end }}
{{- end }}

{{/*
The values path of every volume in the legacy format (one carrying `type`), in
the Deployment and in the hooks and cronjobs of both scopes, as a JSON list of
"<path>.volumes[<i>] (<name>)". Disabled deployments render nothing and are
skipped. Read by NOTES.txt for the deprecation line (issue #183); it goes with
the format in 4.0.0.
Usage: {{- $legacy := include "global-chart.legacyVolumePaths" . | fromJsonArray }}
*/}}
{{- define "global-chart.legacyVolumePaths" -}}
{{- $owners := list (dict "hooks" .Values.hooks "cronJobs" .Values.cronJobs "deployName" "") -}}
{{- range $name, $deploy := .Values.deployments -}}
  {{- if and $deploy (eq (include "global-chart.deploymentEnabled" $deploy) "true") -}}
    {{- $owners = append $owners (dict "path" (include "global-chart.deploymentValuesPath" $name) "volumes" $deploy.volumes "hooks" $deploy.hooks "cronJobs" $deploy.cronJobs "deployName" $name) -}}
  {{- end -}}
{{- end -}}
{{- $withVolumes := list -}}
{{- range $owner := $owners -}}
  {{- if $owner.path -}}
    {{- $withVolumes = append $withVolumes (dict "path" $owner.path "volumes" $owner.volumes) -}}
  {{- end -}}
  {{- range $hookType, $jobs := (default (dict) $owner.hooks) -}}
    {{- range $jobName, $job := (default (dict) $jobs) -}}
      {{- if $job -}}
        {{- $withVolumes = append $withVolumes (dict "path" (include "global-chart.jobValuesPath" (dict "kind" "hook" "deploymentName" $owner.deployName "hookType" $hookType "jobName" $jobName)) "volumes" $job.volumes) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- range $jobName, $job := (default (dict) $owner.cronJobs) -}}
    {{- if $job -}}
      {{- $withVolumes = append $withVolumes (dict "path" (include "global-chart.jobValuesPath" (dict "kind" "cronjob" "deploymentName" $owner.deployName "jobName" $jobName)) "volumes" $job.volumes) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $out := list -}}
{{- range $withVolumes -}}
  {{- $path := .path -}}
  {{- range $i, $vol := (default (list) .volumes) -}}
    {{- if hasKey $vol "type" -}}
      {{- $out = append $out (printf "%s.volumes[%d] (%s)" $path $i $vol.name) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{/*
Render imagePullSecrets block. Accepts a list of strings or objects with "name" key.
Every scope holds its items to $defs/imagePullSecret in the schema (issue #158),
so an item here is one of the two.
Usage: {{ include "global-chart.renderImagePullSecrets" $listOrNil }}
Returns empty string if list is nil/empty.
*/}}
{{- define "global-chart.renderImagePullSecrets" -}}
{{- with . -}}
imagePullSecrets:
  {{- range . }}
    {{- if kindIs "string" . }}
  - name: {{ . | quote }}
    {{- else }}
  - name: {{ .name | quote }}
    {{- end }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Render dnsConfig block from a dnsConfig dict.
Usage: {{ include "global-chart.renderDnsConfig" $dnsConfigDict }}
Returns empty string if no nameservers/searches/options are set.
*/}}
{{- define "global-chart.renderDnsConfig" -}}
{{- $dnsConfig := default (dict) . -}}
{{- if or $dnsConfig.nameservers $dnsConfig.searches $dnsConfig.options -}}
dnsConfig:
  {{- if $dnsConfig.nameservers }}
  nameservers:
    {{- range $dnsConfig.nameservers }}
    - {{ . | quote }}
    {{- end }}
  {{- end }}
  {{- if $dnsConfig.searches }}
  searches:
    {{- range $dnsConfig.searches }}
    - {{ . | quote }}
    {{- end }}
  {{- end }}
  {{- if $dnsConfig.options }}
  options:
    {{- range $dnsConfig.options }}
    - name: {{ .name }}
      {{- /* Set means present and not null: 0 and "" are values */}}
      {{- if not (kindIs "invalid" .value) }}
      value: {{ include "global-chart.printScalar" .value | quote }}
      {{- end }}
    {{- end }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Render resources block with defaults fallback.
Usage: {{ include "global-chart.renderResources" (dict "resources" $job.resources "hasResources" (hasKey $job "resources") "defaults" $root.Values.defaults) }}
When hasResources is true and resources is empty ({}), no resources block is rendered (explicit override to clear defaults).
When hasResources is false (key absent), defaults.resources is used as fallback.
*/}}
{{- define "global-chart.renderResources" -}}
{{- if .resources -}}
resources:
  {{- toYaml .resources | nindent 2 }}
{{- else if not (default false .hasResources) }}
{{- $defaultRes := default (dict) (default (dict) .defaults).resources -}}
{{- with $defaultRes -}}
resources:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Render the annotations of one resource: global.commonAnnotations merged with the
resource's own, the resource's own winning on a shared key.
Usage: {{- with (include "global-chart.renderAnnotations" (dict "root" $root "own" $sa.annotations)) }}
Returns the "key: value" lines at indent 0, or empty string when both sides are
empty; the caller owns the "annotations:" key and its nindent.
The merge is the point, not a convenience: emitting the two sources as two
concatenated blocks puts a shared key in the manifest twice. Helm's parser is not
strict and takes the last one, so the precedence happens to come out right, but
kubeconform -strict rejects the manifest outright. Never concatenate.
`mergeOverwrite`, not `merge`: sprig's `merge` treats an empty destination value as
absent, so a per-resource annotation deliberately blanked to "" would lose to the
global one — the precedence would hold for every value but that one.
The three helm.sh/hook* keys the chart emits itself are dropped from the merged map
(ADR 0004): hook.yaml renders them right after this block, so leaving a values-supplied
copy in would put the key in the manifest twice — the very defect this helper removes —
and the chart owns them either way. helm.sh/hook-output-log-policy is not dropped: the
chart never emits it, so there is nothing to collide with.
*/}}
{{- define "global-chart.renderAnnotations" -}}
{{- $common := default (dict) (default (dict) .root.Values.global).commonAnnotations -}}
{{- $merged := mergeOverwrite (deepCopy $common) (default (dict) .own) -}}
{{- with omit $merged "helm.sh/hook" "helm.sh/hook-weight" "helm.sh/hook-delete-policy" -}}
{{- toYaml . -}}
{{- end -}}
{{- end }}

{{/*
A deployment's own annotations, as JSON, for renderAnnotations' `own`: its
`annotations` unchanged, plus — when reloader.externalSecrets is on (issue #175,
ADR 0016) — secret.reloader.stakater.com/reload listing the targets of its
referenced externalSecrets. Single home of "the field is on" and of its one
failure: on, with nothing referenced, is a silent no-op the chart can see, so it
fails the render, as ADR 0012 rules for autoscaling.
The targets come from the resolveExternalSecretRefs `targets`, never from
values: the generated names are not a public interface (ADR 0007). Reloader
reads each entry as an anchored regex, so each goes through regexQuoteMeta.
A reload list the user set — in `annotations` and in the common annotations
alike — is kept, entry by entry, and the targets are appended: "the user wins"
would drop the targets in silence, "own wins over common" a shared list. A
target the user already listed, quoted or bare, is not listed twice.
Params:
  root   - chart context
  deploy - the deployment's values
  name   - the deployment's key, for the fail message
  es     - its resolveExternalSecretRefs result
Usage: {{- $own := include "global-chart.deploymentOwnAnnotations" (dict "root" $root "deploy" $deploy "name" $name "es" $es) | fromJson }}
*/}}
{{- define "global-chart.deploymentOwnAnnotations" -}}
{{- $own := deepCopy (default (dict) .deploy.annotations) -}}
{{- if (default (dict) .deploy.reloader).externalSecrets -}}
  {{- if not .es.targets -}}
    {{- fail (printf "%s.reloader.externalSecrets: true, but the deployment references no externalSecrets, so Reloader has no Secret to watch. Reference an externalSecrets entry or disable the field." (include "global-chart.deploymentValuesPath" .name)) -}}
  {{- end -}}
  {{- $key := "secret.reloader.stakater.com/reload" -}}
  {{- $common := default (dict) (default (dict) .root.Values.global).commonAnnotations -}}
  {{- $names := list -}}
  {{- range (concat (splitList "," (default "" (index $common $key))) (splitList "," (default "" (index $own $key)))) -}}
    {{- with trim . -}}{{- $names = append $names . -}}{{- end -}}
  {{- end -}}
  {{- range .es.targets -}}
    {{- if not (or (has . $names) (has (regexQuoteMeta .) $names)) -}}
      {{- $names = append $names (regexQuoteMeta .) -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set $own $key (join "," (uniq $names)) -}}
{{- end -}}
{{- toJson $own -}}
{{- end }}

{{/*
Fail on a null value of a ConfigMap or Secret data map, naming <path>.<key>.
Single home of the null check shared by renderConfigMapData and renderSecretData
(issue #166): both data maps hold strings only, and a null is a value nobody
wrote — "<nil>" in a ConfigMap, the base64 of "null" in a Secret. Renders
nothing when the value is set.
Usage: {{- include "global-chart.rejectNullDataValue" (dict "value" $value "errCtx" $errCtx "key" $key "kind" "Secret") -}}
*/}}
{{- define "global-chart.rejectNullDataValue" -}}
{{- if kindIs "invalid" .value -}}
{{- fail (printf "%s.%s: a null value reached a %s, which holds strings only. Set a value — \"\" for an empty string — or remove the key." .errCtx .key .kind) -}}
{{- end -}}
{{- end }}

{{/*
Render the body of a ConfigMap "data:" block: one "key: value" line per entry, at
indent 0. The caller owns the "data:" key and applies its own nindent 2.
Usage: {{- include "global-chart.renderConfigMapData" (dict "data" $deploy.configMap "deploymentName" $name) | nindent 2 }}
Map/slice values are serialized with toYaml into a block scalar, everything else
printed through printScalar and quoted — a bare toString turned 10000000 into
"1e+07" (issue #132). A null value fails, naming
deployments.<deploymentName>.configMap.<key>, before it reaches printScalar,
whose own null message cannot name the key:
ConfigMap.data is map[string]string, so every value has to render as a YAML
string or the API server rejects the manifest.
Keys are quoted, here and in renderSecretData: a bare `on`, `0x1F` or `1.10` is
reparsed as a YAML 1.1 scalar and reaches the API server as "true", "31", "1.1"
(issue #152).
Returns empty string on an empty map; callers guard on the map being non-empty.
Built by joining lines rather than by literal text + whitespace control, unlike the
block helpers above: those own their block key and so start on literal text, while a
body-only helper written as a literal range emits a leading newline, which the
caller's nindent turns into a line of bare spaces.
*/}}
{{- define "global-chart.renderConfigMapData" -}}
{{- $errCtx := printf "%s.configMap" (include "global-chart.deploymentValuesPath" .deploymentName) -}}
{{- $lines := list -}}
{{- range $key, $value := .data -}}
{{- include "global-chart.rejectNullDataValue" (dict "value" $value "errCtx" $errCtx "key" $key "kind" "ConfigMap") -}}
{{- if or (kindIs "map" $value) (kindIs "slice" $value) -}}
{{- $lines = append $lines (printf "%s: |-\n%s" ($key | quote) (toYaml $value | indent 2)) -}}
{{- else -}}
{{- $lines = append $lines (printf "%s: %s" ($key | quote) (include "global-chart.printScalar" $value | quote)) -}}
{{- end -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end }}

{{/*
Render the body of a Secret "data:" block: one "key: <base64>" line per entry, at
indent 0. The caller owns the "data:" key and applies its own nindent 2.
Usage: {{- include "global-chart.renderSecretData" (dict "data" $deploy.secret "deploymentName" $name) | nindent 2 }}
Strings are base64-encoded as-is, everything else through toYaml first. A null
fails, naming deployments.<deploymentName>.secret.<key>: toYaml nil is the
string "null", and the app would read those four characters as its secret
(issue #166). renderConfigMapData fails on a null the same way.
Returns empty string on an empty map; callers guard on the map being non-empty.
*/}}
{{- define "global-chart.renderSecretData" -}}
{{- $errCtx := printf "%s.secret" (include "global-chart.deploymentValuesPath" .deploymentName) -}}
{{- $lines := list -}}
{{- range $key, $value := .data -}}
{{- include "global-chart.rejectNullDataValue" (dict "value" $value "errCtx" $errCtx "key" $key "kind" "Secret") -}}
{{- if kindIs "string" $value -}}
{{- $lines = append $lines (printf "%s: %s" ($key | quote) ($value | b64enc | quote)) -}}
{{- else -}}
{{- $lines = append $lines (printf "%s: %s" ($key | quote) (toYaml $value | b64enc | quote)) -}}
{{- end -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end }}

{{/*
Render the "rules:" block of a Role, at indent 0: the rbacs.roles entry's rules,
or [] when it has none. Single home for the real Role and its hook-prerequisite
copy (ADR 0010), so the copy cannot grant something the real Role does not.
Usage: {{ include "global-chart.renderRoleRules" $role.rules }}
*/}}
{{- define "global-chart.renderRoleRules" -}}
rules:
{{- with . }}
{{ toYaml . | indent 2 }}
{{- else }}
  []
{{- end }}
{{- end }}

{{/*
Resolve a backend reference to a {name, port} dict, emitted as JSON for the caller to parse via fromJson.
Usage:
  {{- $b := include "global-chart.resolveBackend" (dict "root" $root "ref" $hostEntry "errCtx" (printf "ingress.hosts[%d]" $hostIdx)) | fromJson -}}
  {{- $svcName := $b.name -}}
  {{- $svcPort := $b.port -}}

Inputs (dict):
  - root        (required) — Helm root context (the chart "." passed in)
  - ref         (required) — host entry (ingress) or backendRef (httpRoute) map; supports .service.name/.port and .deployment
  - errCtx      (required) — values path of ref (ingress.hosts[<i>], httpRoute.rules[<i>].backendRefs[<j>]);
                             leads every fail message, "<values path>: <problem>" (issue #190).

Resolution priority (mirrors the historical inline ingress logic):
  1. Explicit service override: ref.service.name set      → {name=ref.service.name, port=ref.service.port|80}
  2. Deployment reference:      ref.deployment set        → {name=deploymentFullname, port=deploy.service.port|80}
                                with validations: deployment exists, enabled, service.enabled != false
  3. Otherwise: fail with actionable message.

Output: JSON string of the form {"name":"<svc>","port":<int>}
Numbers come back float64: see the file header.
*/}}
{{- define "global-chart.resolveBackend" -}}
{{- $root := .root -}}
{{- $ref := .ref -}}
{{- $path := required "resolveBackend: errCtx is required (the values path of ref)" .errCtx -}}
{{- $svcName := "" -}}
{{- $svcPort := 80 -}}

{{- /* Priority 1: Explicit service override.
       This 80 is deliberately NOT servicePrimaryPort's: ref.service is an
       arbitrary Service in the cluster, with only name/port — no portName, no
       targetPort. Its default merely coincides with the chart's primary port;
       sharing a home would couple a deployment's primary port to a foreign
       Service's. */ -}}
{{- if and (hasKey $ref "service") $ref.service $ref.service.name -}}
  {{- $svcName = $ref.service.name -}}
  {{- if hasKey $ref.service "port" -}}
    {{- include "global-chart.rejectNull" (dict "value" $ref.service.port "errCtx" (printf "%s.service.port" $path)) -}}
  {{- end -}}
  {{- $svcPort = ternary $ref.service.port 80 (hasKey $ref.service "port") -}}
{{- /* Priority 2: Deployment reference */ -}}
{{- else if $ref.deployment -}}
  {{- $depName := $ref.deployment -}}
  {{- $deploy := index $root.Values.deployments $depName -}}
  {{- if not $deploy -}}
    {{- if hasKey (default (dict) $root.Values.deployments) $depName -}}
      {{- fail (printf "%s.deployment: references deployment '%s', which is empty: an empty deployments entry renders nothing. Fill the entry, or drop the reference." $path $depName) -}}
    {{- end -}}
    {{- fail (printf "%s.deployment: references deployment '%s', which does not exist in .Values.deployments" $path $depName) -}}
  {{- end -}}
  {{- if ne (include "global-chart.deploymentEnabled" $deploy) "true" -}}
    {{- fail (printf "%s.deployment: references deployment '%s', which has enabled: false (its Service will not be created)" $path $depName) -}}
  {{- end -}}
  {{- $depSvc := default (dict) $deploy.service -}}
  {{- if ne (include "global-chart.serviceEnabled" $depSvc) "true" -}}
    {{- fail (printf "%s.deployment: references deployment '%s', which has service.enabled: false. Enable the service or remove the reference." $path $depName) -}}
  {{- end -}}
  {{- $svcName = include "global-chart.deploymentFullname" (dict "root" $root "deploymentName" $depName) -}}
  {{- $depSvcCtx := printf "%s.service" (include "global-chart.deploymentValuesPath" $depName) -}}
  {{- $svcPort = (include "global-chart.servicePrimaryPort" (dict "service" $depSvc "errCtx" $depSvcCtx) | fromJson).port -}}
{{- /* Priority 3: Error - must specify deployment or service */ -}}
{{- else -}}
  {{- fail (printf "%s: must specify either 'deployment' (name of a deployment) or 'service.name' (explicit service name)" $path) -}}
{{- end -}}

{{- dict "name" $svcName "port" $svcPort | toJson -}}
{{- end }}

{{/*
Render an ExternalSecret remoteRef block, shared by both the data-list and
single-key branches of externalsecret.yaml so their defaults can never drift.
`property` and `version` carry no chart-side default — ESO defaults them at the
CRD level — so they are emitted only when the key is present, keyed on `hasKey`
rather than truthiness: an explicit empty string is the user's input and is
passed through, not silently dropped. `version` goes through `quote` because the
schema accepts a number for it (`version: 3`) while the CRD wants a string;
printScalar first, so a large number does not become "1e+07".
Usage: {{- include "global-chart.renderExternalSecretRemoteRef" (dict "remote" $remote "errCtx" (printf "externalSecrets.%s.remote" $name)) | nindent 8 }}
Inputs (dict):
  - remote    (required) — the remote map (key + optional conversion/decoding/metadata strategies, property, version)
  - errCtx    (required) — values path of the remote map; leads the message when remote.key is missing
*/}}
{{- define "global-chart.renderExternalSecretRemoteRef" -}}
{{- $remote := .remote -}}
conversionStrategy: {{ ternary $remote.conversionStrategy "Default" (hasKey $remote "conversionStrategy") | quote }}
decodingStrategy: {{ ternary $remote.decodingStrategy "None" (hasKey $remote "decodingStrategy") | quote }}
key: {{ required (printf "%s.key: mandatory" (required "renderExternalSecretRemoteRef: errCtx is required (the values path of the remote)" .errCtx)) $remote.key | quote }}
metadataPolicy: {{ ternary $remote.metadataPolicy "None" (hasKey $remote "metadataPolicy") | quote }}
{{- if hasKey $remote "property" }}
property: {{ $remote.property | quote }}
{{- end }}
{{- if hasKey $remote "version" }}
version: {{ include "global-chart.printScalar" (dict "value" $remote.version "errCtx" (printf "%s.version" .errCtx)) | quote }}
{{- end }}
{{- end }}

{{/*
Container ports for a deployment's pod spec, derived from its Service definition.
Single source of truth for the pod side of the Service: deployment.yaml renders
this list, and validateServiceTargetPorts checks named targetPorts against it,
so the two can never drift — that drift is what made service.targetPort unusable
(issue #82).

The Service's targetPort decides the pod's port: a number IS the port, a name has
to resolve to one of these entries. Every numeric targetPort under extraPorts is
therefore declared here as well, named after its Service port, so that a named
targetPort has something to bind to.

Entries are deduplicated by name and by number+protocol. A numeric targetPort
reaches a pod port whether or not the container declares it, so re-declaring an
already-declared port would buy nothing and risk a duplicate name, which the API
server rejects. The protocol is part of the key because the same number under
two protocols is a distinct port — TCP and UDP on 53 is the ordinary DNS shape.
Usage: {{ include "global-chart.containerPorts" (dict "service" $svc "errCtx" (printf "%s.service" $errCtx)) | fromJsonArray }}
Numbers come back float64: see the file header.
*/}}
{{- define "global-chart.containerPorts" -}}
{{- $svc := .service -}}
{{- $primary := include "global-chart.servicePrimaryPort" . | fromJson -}}
{{- $portName := $primary.name -}}
{{- $targetPort := $primary.targetPort -}}
{{- $containerPort := kindIs "string" $targetPort | ternary $primary.port $targetPort -}}
{{- $protocol := $primary.protocol -}}
{{- $ports := list (dict "name" $portName "containerPort" $containerPort "protocol" $protocol) -}}
{{- $names := dict $portName true -}}
{{- $numbers := dict (printf "%s/%s" (include "global-chart.printScalar" $containerPort) $protocol) true -}}
{{- range (default (list) $svc.extraPorts) -}}
  {{- if not (kindIs "string" .targetPort) -}}
    {{- $extraProtocol := include "global-chart.extraPortProtocol" . -}}
    {{- $key := printf "%s/%s" (include "global-chart.printScalar" .targetPort) $extraProtocol -}}
    {{- if and (not (hasKey $names .name)) (not (hasKey $numbers $key)) -}}
      {{- $ports = append $ports (dict "name" .name "containerPort" .targetPort "protocol" $extraProtocol) -}}
      {{- $_ := set $names .name true -}}
      {{- $_ := set $numbers $key true -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $ports | toJson -}}
{{- end }}

{{/*
The primary port of a deployment's Service: the single home of its four
defaults (`port` 80, `name` "http", `protocol` TCP, `targetPort` following the
name). Consumed by service.yaml, containerPorts, validateServiceTargetPorts,
validateServicePorts,
resolveBackend and the connection test — every place that used to carry its own
copy of one of them.

The default targetPort follows the port's name, not the literal "http": with a
custom portName and no targetPort, "http" would name a port nothing declares.

Only the primary port is here. extraPorts entries have name/port/targetPort all
required by the schema; their one default, the protocol, lives in
extraPortProtocol.
Every consumer of a deployment's ports reaches this helper before it prints
one, so it runs rejectNullServicePorts first: the one call that covers them all.
Usage: {{ $primary := include "global-chart.servicePrimaryPort" (dict "service" $svc "errCtx" (printf "%s.service" $errCtx)) | fromJson }}
Input: the deployment's service map, already defaulted to (dict) by the caller,
and errCtx, its values path.
Output: JSON of the form {"port":80,"name":"http","protocol":"TCP","targetPort":"http"}
Numbers come back float64: see the file header.
*/}}
{{- define "global-chart.servicePrimaryPort" -}}
{{- $svc := .service -}}
{{- include "global-chart.rejectNullServicePorts" (dict "service" $svc "errCtx" (required "servicePrimaryPort: errCtx is required (the values path of the service)" .errCtx)) -}}
{{- $name := ternary $svc.portName "http" (hasKey $svc "portName") -}}
{{- dict
      "port" (ternary $svc.port 80 (hasKey $svc "port"))
      "name" $name
      "protocol" (ternary $svc.protocol "TCP" (hasKey $svc "protocol") | upper)
      "targetPort" (ternary $svc.targetPort $name (hasKey $svc "targetPort"))
    | toJson -}}
{{- end }}

{{/*
Fail on a null in a deployment's Service ports, naming its key (issue #191): a
port, targetPort, portName or protocol of the primary port, and any key of an
extraPorts entry. The single home of that check. servicePrimaryPort runs it,
because every consumer of the ports (service.yaml, containerPorts, the
validators, resolveBackend, the connection test) reaches servicePrimaryPort
before it prints one; so they print the ports bare, already checked.
Usage: {{- include "global-chart.rejectNullServicePorts" (dict "service" $svc "errCtx" "deployments.web.service") -}}
*/}}
{{- define "global-chart.rejectNullServicePorts" -}}
{{- $svc := .service -}}
{{- $errCtx := .errCtx -}}
{{- range $key := list "port" "targetPort" "portName" "protocol" -}}
  {{- if hasKey $svc $key -}}
    {{- include "global-chart.rejectNull" (dict "value" (index $svc $key) "errCtx" (printf "%s.%s" $errCtx $key)) -}}
  {{- end -}}
{{- end -}}
{{- range $i, $port := (default (list) $svc.extraPorts) -}}
  {{- range $key, $value := $port -}}
    {{- include "global-chart.rejectNull" (dict "value" $value "errCtx" (printf "%s.extraPorts[%d].%s" $errCtx $i $key)) -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
The protocol of a service.extraPorts entry: its own, uppercased, or TCP. The one
home of that default, read by service.yaml, containerPorts and
validateServicePorts.
Usage: {{ include "global-chart.extraPortProtocol" $extraPort }}
*/}}
{{- define "global-chart.extraPortProtocol" -}}
{{- default "TCP" .protocol | upper -}}
{{- end }}

{{/*
The type of a deployment's Service: its own, or ClusterIP. The one home of that
default, read by service.yaml and validateServicePorts.
Usage: {{ include "global-chart.serviceType" $svc }}
Input: the deployment's service map, already defaulted to (dict) by the caller.
*/}}
{{- define "global-chart.serviceType" -}}
{{- ternary .type "ClusterIP" (hasKey . "type") -}}
{{- end }}

{{/*
The spec body of an ExternalSecret, at indent 0, with the validation of its
values. Single home for the real ExternalSecret and its hook-prerequisite copy
(ADR 0007): a copy that re-derived the body inline would diverge in silence,
for the reason ADR 0005 gives for the ConfigMap/Secret copies.
Knows nothing about hooks: the copy's two differences arrive as overrides.
Params:
  root, key, secret - the chart context, the externalSecrets key and its map
  targetName        - optional; overrides target.name (the copy's own Secret)
  creationPolicy    - optional; overrides target.creationPolicy (the copy's Owner)
*/}}
{{- define "global-chart.renderExternalSecretSpec" -}}
{{- $key := .key -}}
{{- $secret := .secret -}}
{{- $target := default (dict) $secret.target -}}
{{- $hasData := hasKey $secret "data" -}}
{{- $hasDataFrom := hasKey $secret "dataFrom" -}}
{{- if and (or $hasData $hasDataFrom) (or (hasKey $secret "remote") (hasKey $secret "secretkey")) -}}
{{- fail (printf "externalSecrets.%s: single-key form ('remote'/'secretkey') cannot be combined with 'data' or 'dataFrom'" $key) -}}
{{- end -}}
{{/* A dataFrom whose every entry carries its own sourceRef (generatorRef or
     per-item storeRef) needs no spec-level store: the CRD makes secretStoreRef
     optional. An empty list is not self-contained — it would render a
     store-less, data-less ExternalSecret. */}}
{{- $selfContainedDataFrom := false -}}
{{- if and $hasDataFrom (not $hasData) (gt (len (default (list) $secret.dataFrom)) 0) -}}
{{- $selfContainedDataFrom = true -}}
{{- range $item := $secret.dataFrom -}}
{{- $sourceRef := default (dict) $item.sourceRef -}}
{{- if not (or (hasKey $sourceRef "generatorRef") (hasKey $sourceRef "storeRef")) -}}
{{- $selfContainedDataFrom = false -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $secretStore := $secret.secretstore -}}
{{- if not $selfContainedDataFrom -}}
{{- $secretStore = required (printf "externalSecrets.%s.secretstore: mandatory unless every dataFrom entry carries its own sourceRef (generatorRef or storeRef)" $key) $secret.secretstore -}}
{{- end -}}
{{- if or $hasData $hasDataFrom }}
{{- if $hasData }}
data:
  {{- range $i, $item := $secret.data }}
  {{- $itemRemote := required (printf "externalSecrets.%s.data[%d].remote: mandatory" $key $i) $item.remote }}
  - remoteRef:
      {{- include "global-chart.renderExternalSecretRemoteRef" (dict "remote" $itemRemote "errCtx" (printf "externalSecrets.%s.data[%d].remote" $key $i)) | nindent 6 }}
    secretKey: {{ required (printf "externalSecrets.%s.data[%d].secretkey: mandatory" $key $i) $item.secretkey | quote }}
  {{- end }}
{{- end }}
{{- if $hasDataFrom }}
dataFrom:
  {{- toYaml $secret.dataFrom | nindent 2 }}
{{- end }}
{{- else }}
{{- $remote := required (printf "externalSecrets.%s.remote: mandatory" $key) $secret.remote }}
data:
  - remoteRef:
      {{- include "global-chart.renderExternalSecretRemoteRef" (dict "remote" $remote "errCtx" (printf "externalSecrets.%s.remote" $key)) | nindent 6 }}
    secretKey: {{ required (printf "externalSecrets.%s.secretkey: mandatory" $key) $secret.secretkey | quote }}
{{- end }}
refreshInterval: {{ ternary $secret.refreshInterval "1h" (hasKey $secret "refreshInterval") | quote }}
{{- /* Emitted whenever a store is required — so an incomplete secretstore
       still fails on the store-backed path — and also when a self-contained
       dataFrom supplies one anyway: ESO lets a per-item sourceRef override a
       spec-level store. A self-contained dataFrom with an empty secretstore
       is the one case that renders neither: nothing to emit, nothing needed. */}}
{{- if or (not $selfContainedDataFrom) $secretStore }}
secretStoreRef:
  kind: {{ required (printf "externalSecrets.%s.secretstore.kind: mandatory" $key) $secretStore.kind | quote }}
  name: {{ required (printf "externalSecrets.%s.secretstore.name: mandatory" $key) $secretStore.name | quote }}
{{- end }}
target:
  creationPolicy: {{ default (include "global-chart.externalSecretCreationPolicy" $secret) .creationPolicy | quote }}
  deletionPolicy: {{ ternary $target.deletionPolicy "Retain" (hasKey $target "deletionPolicy") | quote }}
  name: {{ default (include "global-chart.externalSecretTargetName" .) .targetName | quote }}
  {{- if hasKey $target "immutable" }}
  immutable: {{ $target.immutable }}
  {{- end }}
  {{- with $target.template }}
  template:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}

{{/*
Resolve a list of externalSecrets references ({name, mountPath?}) to what a pod
consumes, split by form: `env` holds the Secret names to inject as envFrom
sources, `mounted` the {key, secretName, volumeName, mountPath} of the entries that
carry a mountPath. `specs` holds the real ExternalSecret spec of every entry,
in list order, rendered by renderExternalSecretSpec whatever `hook` says: the
input of the Deployment's checksum/external-secrets (issue #174), ignored by the
jobs. `targets` holds every Secret name the pod reads, env and mounted, in list
order, each once: the input of the Deployment's Reloader annotation (ADR 0016).
Returns JSON {env: [...], mounted: [...], specs: [...], targets: [...]}; callers do
`include ... | fromJson` and render `mounted` through
containerVolumeMounts / renderExternalSecretVolumes.
A reference names a key of the root externalSecrets map, never a Secret name:
the generated names are not a public interface (ADR 0007). Fails at render
time, rather than at apply time far from the cause, on a key that names
nothing, on a mounted key that is not a DNS-1123 label, and on a generated
volume name the pod already declares — a user volume or the same key mounted
twice.
Params:
  root    - chart context
  refs    - the list of references
  hook    - true to read the hook-prerequisite copy's Secret instead of the real one
  volumes - the volumes the pod declares itself, for the collision check
  errCtx  - values path of the list's owner, for the fail message
*/}}
{{- define "global-chart.resolveExternalSecretRefs" -}}
{{- $root := .root -}}
{{- $readsCopy := and (hasKey . "hook") .hook -}}
{{- $taken := dict -}}
{{- range (default (list) .volumes) -}}{{- $_ := set $taken (toString .name) true -}}{{- end -}}
{{- $out := dict "env" (list) "mounted" (list) "specs" (list) "targets" (list) -}}
{{- range $ref := (default (list) .refs) -}}
  {{- $secret := index (default (dict) $root.Values.externalSecrets) $ref.name -}}
  {{- if not $secret -}}
    {{- if hasKey (default (dict) $root.Values.externalSecrets) $ref.name -}}
      {{- fail (printf "%s.externalSecrets: references '%s', which is empty: an empty externalSecrets entry renders no ExternalSecret. Fill the entry, or drop the reference." $.errCtx $ref.name) -}}
    {{- end -}}
    {{- fail (printf "%s.externalSecrets: references '%s', which is not a key of externalSecrets. Name the key of the externalSecrets entry, not the Secret it produces." $.errCtx $ref.name) -}}
  {{- end -}}
  {{- $nameCtx := dict "root" $root "key" $ref.name "secret" $secret -}}
  {{- $_ := set $out "specs" (append $out.specs (include "global-chart.renderExternalSecretSpec" $nameCtx)) -}}
  {{- $secretName := include (ternary "global-chart.externalSecretHookTargetName" "global-chart.externalSecretTargetName" $readsCopy) $nameCtx -}}
  {{- $_ := set $out "targets" (append $out.targets $secretName | uniq) -}}
  {{- if $ref.mountPath -}}
    {{- $volumeName := include "global-chart.externalSecretVolumeName" (dict "key" $ref.name) -}}
    {{- if or (gt (len $volumeName) 63) (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $volumeName)) -}}
      {{- fail (printf "externalSecrets.%s: cannot be mounted, its volume name '%s' is not a DNS-1123 label of at most 63 characters. Rename the key, or inject it without a mountPath." $ref.name $volumeName) -}}
    {{- end -}}
    {{- if hasKey $taken $volumeName -}}
      {{- fail (printf "%s.externalSecrets: the volume '%s' generated for '%s' is already declared in this pod. Mount a key once, and do not name your own volumes after it." $.errCtx $volumeName $ref.name) -}}
    {{- end -}}
    {{- $_ := set $taken $volumeName true -}}
    {{- $_ := set $out "mounted" (append $out.mounted (dict "key" $ref.name "secretName" $secretName "volumeName" $volumeName "mountPath" $ref.mountPath)) -}}
  {{- else -}}
    {{- $_ := set $out "env" (append $out.env $secretName) -}}
  {{- end -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{/*
The volumeMounts of a pod's main container, in render order, as a JSON list of
volumeMount maps: the user's volumeMounts, the mountedConfigFiles files and
bundles (a Deployment's only), then the mounted externalSecrets entries, the
inherited before the own. The single home of which mounts land on the
container: deployment.yaml and jobPodSpec render this list, and
validateMountPaths checks it for a repeated mountPath (issue #182), so a new
mount source cannot reach the manifest unchecked.
Callers do `include ... | fromJsonArray` and toYaml the result.
Params:
  errCtx             - values path of the container's owner (a job's from jobValuesPath)
  volumeMounts       - the container's own volumeMounts, rendered verbatim
  mountedConfigFiles - the Deployment's mountedConfigFiles (optional)
  inherited          - the resolveExternalSecretRefs `mounted` list a job inherits (optional)
  inheritedCtx       - values path it is inherited from
  externalSecrets    - the container's own resolveExternalSecretRefs `mounted` list
*/}}
{{- define "global-chart.containerVolumeMounts" -}}
{{- $mounts := list -}}
{{- range $i, $m := (default (list) .volumeMounts) -}}
  {{- $mounts = append $mounts (dict "mount" $m "owner" (printf "volumeMounts[%d]" $i)) -}}
{{- end -}}
{{- $mcf := default (dict) .mountedConfigFiles -}}
{{- range $i, $f := (default (list) $mcf.files) -}}
  {{- $path := required (printf "%s.mountedConfigFiles.files[%d].targetPath: required" $.errCtx $i) $f.targetPath -}}
  {{- $mount := dict "name" (include "global-chart.mountedFileVolumeName" (dict "fileName" $f.name)) "mountPath" $path "subPath" (default "" $f.filename) "readOnly" true -}}
  {{- $mounts = append $mounts (dict "mount" $mount "owner" (printf "mountedConfigFiles.files[%d] (%s)" $i $f.name)) -}}
{{- end -}}
{{- range $i, $b := (default (list) $mcf.bundles) -}}
  {{- $path := required (printf "%s.mountedConfigFiles.bundles[%d].mountDir: required" $.errCtx $i) $b.mountDir -}}
  {{- $mount := dict "name" (include "global-chart.mountedBundleVolumeName" (dict "bundleIndex" $i)) "mountPath" $path "readOnly" true -}}
  {{- $mounts = append $mounts (dict "mount" $mount "owner" (printf "mountedConfigFiles.bundles[%d]" $i)) -}}
{{- end -}}
{{- range (default (list) .inherited) -}}
  {{- $mounts = append $mounts (dict "mount" (dict "name" .volumeName "mountPath" .mountPath "readOnly" true) "owner" (printf "externalSecrets '%s' (inherited from %s)" .key $.inheritedCtx)) -}}
{{- end -}}
{{- range (default (list) .externalSecrets) -}}
  {{- $mounts = append $mounts (dict "mount" (dict "name" .volumeName "mountPath" .mountPath "readOnly" true) "owner" (printf "externalSecrets '%s'" .key)) -}}
{{- end -}}
{{- include "global-chart.validateMountPaths" (dict "errCtx" .errCtx "mounts" $mounts) -}}
{{- $out := list -}}
{{- range $mounts -}}{{- $out = append $out .mount -}}{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{/*
The volumes of the mounted externalSecrets entries, one per entry of a
resolveExternalSecretRefs `mounted` list, as list items at indent 0. Shared by
deployment.yaml and jobPodSpec, so the two render the same Secret volume.
Usage: {{- include "global-chart.renderExternalSecretVolumes" $mounted | nindent 2 }}
*/}}
{{- define "global-chart.renderExternalSecretVolumes" -}}
{{- $out := list -}}
{{- range . -}}
{{- $out = append $out (dict "name" .volumeName "secret" (dict "secretName" .secretName)) -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{/*
The effective creationPolicy of an externalSecrets entry: its own, or Owner.
The ONE place the default is spelled out — renderExternalSecretSpec renders it
and validateNameCollisions decides from it whether the entry owns its target.
Usage: {{ include "global-chart.externalSecretCreationPolicy" $secret }}
*/}}
{{- define "global-chart.externalSecretCreationPolicy" -}}
{{- $target := default (dict) .target -}}
{{- ternary $target.creationPolicy "Owner" (hasKey $target "creationPolicy") -}}
{{- end -}}

{{/*
Whether an externalSecrets entry rewrites its target: clears the Secret's data
down to its own keys on every refresh, owner or not (Owner, Orphan). Merge and
CreateOrMerge keep the keys they did not write, and None writes nothing. A
rewritten Secret cannot also be one the chart renders (issue #161, ADR 0013);
validateNameCollisions reads this. Returns "true" or "false".
Usage: {{ include "global-chart.externalSecretRewritesTarget" $secret }}
*/}}
{{- define "global-chart.externalSecretRewritesTarget" -}}
{{- has (include "global-chart.externalSecretCreationPolicy" .) (list "Owner" "Orphan") -}}
{{- end -}}
