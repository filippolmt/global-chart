{{/*
Image helpers for global-chart.
*/}}

{{/*
Render an image reference from either a plain string or a map with repository/tag/digest.
Supports two calling conventions:
  Legacy: {{ include "global-chart.imageString" $deploy.image }}
  New:    {{ include "global-chart.imageString" (dict "image" $deploy.image "global" $root.Values.global) }}
When global.imageRegistry is set, the registry is prepended to both string and map images
unless the first path segment already looks like a registry (contains "." or ":" or equals "localhost").
Examples: "nginx" → "registry/nginx", "myorg/myapp" → "registry/myorg/myapp", "ghcr.io/org/app" → unchanged.
The registry test is the one values.schema.json's host alternative mirrors (issue #173):
a first segment is a host only with a ".", a ":" or as "localhost", so the schema never
accepts as a host what this helper would prefix. Values are used as written, not
trimmed: the schema patterns reject surrounding whitespace.
*/}}
{{- define "global-chart.imageString" -}}
{{- $img := . -}}
{{- $globalRegistry := "" -}}
{{- if and (kindIs "map" .) (hasKey . "image") -}}
  {{- /* New dict format */ -}}
  {{- $img = .image -}}
  {{- $global := default (dict) .global -}}
  {{- $globalRegistry = default "" $global.imageRegistry -}}
{{- end -}}
{{- $name := "" -}}
{{- $suffix := "" -}}
{{- if kindIs "string" $img -}}
  {{- $name = $img -}}
{{- else if and (kindIs "map" $img) $img.repository -}}
  {{- $name = $img.repository -}}
  {{- if $img.digest -}}
    {{- $suffix = printf "@%s" $img.digest -}}
  {{- else if $img.tag -}}
    {{- $suffix = printf ":%s" $img.tag -}}
  {{- end -}}
{{- else if and (kindIs "map" $img) $img.digest -}}
  {{- fail "image definitions that set a digest must also provide a repository (expected repository@digest)" -}}
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
