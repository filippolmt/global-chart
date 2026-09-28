{{/*
Image helpers for global-chart.
*/}}

{{/*
Render an image reference from either a plain string or a map with repository/tag/digest.
Supports two calling conventions:
  Legacy: {{ include "global-chart.imageString" $deploy.image }}
  New:    {{ include "global-chart.imageString" (dict "image" $deploy.image "global" $root.Values.global "errCtx" "deployments.web") }}
errCtx (new format, optional) is the values path of the entry that renders the image
(deployments.<name>, or a job's jobValuesPath) and leads every fail message, so the user
can tell which entry is wrong when several share a repository (issue #188). It names the
entry, not the image key: a job may inherit its image from a deployment.
When global.imageRegistry is set, the registry is prepended to both string and map images
unless the first path segment already looks like a registry (contains "." or ":" or equals "localhost").
Examples: "nginx" → "registry/nginx", "myorg/myapp" → "registry/myorg/myapp", "ghcr.io/org/app" → unchanged.
The registry test is the one values.schema.json's host alternative mirrors (issue #173):
a first segment is a host only with a ".", a ":" or as "localhost", so the schema never
accepts as a host what this helper would prefix. Values are used as written, not
trimmed: the schema patterns reject surrounding whitespace.
A tag may carry its own @<digest> (ADR 0018, the form Argo CD Image Updater writes) and
renders as written, repo:<tag>@<digest>. Such a tag with a non-empty digest fails, even
when the two are equal: digest would win and drop the tag's pin in silence. The schema
rejects the pair first; this fail is the backstop under --skip-schema-validation.
*/}}
{{- define "global-chart.imageString" -}}
{{- $img := . -}}
{{- $globalRegistry := "" -}}
{{- $errPrefix := "" -}}
{{- if and (kindIs "map" .) (hasKey . "image") -}}
  {{- /* New dict format */ -}}
  {{- $img = .image -}}
  {{- $global := default (dict) .global -}}
  {{- $globalRegistry = default "" $global.imageRegistry -}}
  {{- with .errCtx -}}{{- $errPrefix = printf "%s: " . -}}{{- end -}}
{{- end -}}
{{- $name := "" -}}
{{- $suffix := "" -}}
{{- if kindIs "string" $img -}}
  {{- $name = $img -}}
{{- else if and (kindIs "map" $img) $img.repository -}}
  {{- $name = $img.repository -}}
  {{- if and $img.digest (kindIs "string" $img.tag) (contains "@" $img.tag) -}}
    {{- fail (printf "%simage %s sets a digest in tag (%s) and in digest (%s): two sources for one pin, keep one (ADR 0018)" $errPrefix $img.repository $img.tag $img.digest) -}}
  {{- end -}}
  {{- if $img.digest -}}
    {{- $suffix = printf "@%s" $img.digest -}}
  {{- else if $img.tag -}}
    {{- $suffix = printf ":%s" $img.tag -}}
  {{- end -}}
{{- else if and (kindIs "map" $img) $img.digest -}}
  {{- fail (printf "%simage definitions that set a digest must also provide a repository (expected repository@digest)" $errPrefix) -}}
{{- end -}}
{{- if $name -}}
  {{- $firstSegment := index (splitList "/" $name) 0 -}}
  {{- $hasRegistry := and (contains "/" $name) (or (contains "." $firstSegment) (contains ":" $firstSegment) (eq $firstSegment "localhost")) -}}
  {{- if and $globalRegistry (not $hasRegistry) -}}
    {{- $name = printf "%s/%s" $globalRegistry $name -}}
  {{- end -}}
  {{- printf "%s%s" $name $suffix -}}
{{- end -}}
{{- end }}

{{/*
Resolve an image pull policy from optional overrides, image map values, and a fallback.
Priority: override > image.pullPolicy > fallback > IfNotPresent (default).
*/}}
{{- define "global-chart.imagePullPolicy" -}}
{{- $ctx := . -}}
{{- $policy := "" -}}
{{- if and (hasKey $ctx "override") (ne $ctx.override nil) }}
  {{- $policy = printf "%v" $ctx.override | trim -}}
{{- end }}
{{- if not $policy }}
  {{- if and (hasKey $ctx "image") (kindIs "map" $ctx.image) (hasKey $ctx.image "pullPolicy") (ne $ctx.image.pullPolicy nil) }}
    {{- $policy = printf "%v" $ctx.image.pullPolicy | trim -}}
  {{- end }}
{{- end }}
{{- if not $policy }}
  {{- if and (hasKey $ctx "fallback") (ne $ctx.fallback nil) }}
    {{- $policy = printf "%v" $ctx.fallback | trim -}}
  {{- end }}
{{- end }}
{{- if $policy -}}
{{- $policy -}}
{{- else -}}
IfNotPresent
{{- end -}}
{{- end }}
