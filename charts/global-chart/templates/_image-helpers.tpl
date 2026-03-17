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
{{- if kindIs "string" $img }}
  {{- $trimmed := $img | trim -}}
  {{- if $trimmed }}
    {{- $needsRegistry := true -}}
    {{- if contains "/" $trimmed -}}
      {{- $firstSegment := index (splitList "/" $trimmed) 0 -}}
      {{- if or (contains "." $firstSegment) (contains ":" $firstSegment) (eq $firstSegment "localhost") -}}
        {{- $needsRegistry = false -}}
      {{- end -}}
    {{- end -}}
    {{- if and $globalRegistry $needsRegistry }}
      {{- printf "%s/%s" $globalRegistry $trimmed -}}
    {{- else }}
      {{- $trimmed -}}
    {{- end }}
  {{- end }}
{{- else if and (kindIs "map" $img) $img.repository }}
  {{- $repo := $img.repository | trim -}}
  {{- $needsRegistry := true -}}
  {{- if contains "/" $repo -}}
    {{- $firstSegment := index (splitList "/" $repo) 0 -}}
    {{- if or (contains "." $firstSegment) (contains ":" $firstSegment) (eq $firstSegment "localhost") -}}
      {{- $needsRegistry = false -}}
    {{- end -}}
  {{- end -}}
  {{- if and $globalRegistry $needsRegistry }}
    {{- $repo = printf "%s/%s" $globalRegistry $repo -}}
  {{- end -}}
  {{- $digest := default "" $img.digest | trim -}}
  {{- $tag := default "" $img.tag | trim -}}
  {{- if $repo }}
    {{- if $digest }}
      {{- printf "%s@%s" $repo $digest -}}
    {{- else if $tag }}
      {{- printf "%s:%s" $repo $tag -}}
    {{- else }}
      {{- $repo -}}
    {{- end }}
  {{- end }}
{{- else if and (kindIs "map" $img) $img.digest }}
  {{- fail "image definitions that set a digest must also provide a repository (expected repository@digest)" -}}
{{- end }}
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
