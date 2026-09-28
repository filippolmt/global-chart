{{/*
Image helpers for global-chart.
*/}}

{{/*
Render an image reference from either a plain string or a map with repository/tag/digest.
  {{ include "global-chart.imageString" (dict "image" $deploy.image "global" $root.Values.global "errCtx" "deployments.web.image") }}
errCtx (required) is the values path of the image and leads every fail message, in the
shape "<values path>: <problem>" (issues #188, #190): deployments.<name>.image, a job's
<jobValuesPath>.image, or, for an inherited image, "deployments.<name>.image (inherited
by <jobValuesPath>)", which jobImageString builds.
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
rejects the pair first; this fail is the backstop under --skip-schema-validation. A tag
that starts with @ fails too: it would render repo:@<digest>, and the schema's non-empty
tag before the @ has the same backstop.
*/}}
{{- define "global-chart.imageString" -}}
{{- $errCtx := required "imageString: errCtx is required (the values path of the image)" .errCtx -}}
{{- $img := .image -}}
{{- $globalRegistry := default "" (default (dict) .global).imageRegistry -}}
{{- $name := "" -}}
{{- $suffix := "" -}}
{{- if kindIs "string" $img -}}
  {{- $name = $img -}}
{{- else if and (kindIs "map" $img) $img.repository -}}
  {{- $name = $img.repository -}}
  {{- if and (kindIs "string" $img.tag) (hasPrefix "@" $img.tag) -}}
    {{- fail (printf "%s.tag: %q has no tag before the @<digest>: it would render %s:%s, which the kubelet rejects as InvalidImageName. Set the tag before the @, or move the digest to digest (ADR 0018)" $errCtx $img.tag $img.repository $img.tag) -}}
  {{- end -}}
  {{- if and $img.digest (kindIs "string" $img.tag) (contains "@" $img.tag) -}}
    {{- fail (printf "%s: sets a digest in tag (%s) and in digest (%s): two sources for one pin, keep one (ADR 0018)" $errCtx $img.tag $img.digest) -}}
  {{- end -}}
  {{- if $img.digest -}}
    {{- $suffix = printf "@%s" $img.digest -}}
  {{- else if $img.tag -}}
    {{- $suffix = printf ":%s" $img.tag -}}
  {{- end -}}
{{- else if and (kindIs "map" $img) $img.digest -}}
  {{- fail (printf "%s: sets a digest without a repository (expected repository@digest)" $errCtx) -}}
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
