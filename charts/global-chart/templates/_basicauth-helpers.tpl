{{/*
Envoy Basic Auth uses htpasswd's {SHA} format, not Sprig htpasswd's bcrypt.
SHA-1 here is an upstream compatibility requirement, not a password-storage
recommendation: use only with HTTPS and a cryptographically random password.
Sprig exposes SHA-1 as hex; encode its 160 bits directly as base64 (27 sextets
and one padding character), avoiding UTF-8 corruption of bytes above 127.
The public render check verifies the result with Python's hashlib/base64.
Usage: {{ include "global-chart.basicAuthSha" $password }}
*/}}
{{- define "global-chart.basicAuthSha" -}}
{{- $bits := "" -}}
{{- range (regexFindAll "." (sha1sum .) -1) -}}
  {{- $bits = printf "%s%04b" $bits (int (printf "0x%s" .)) -}}
{{- end -}}
{{- $alphabet := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" -}}
{{- range (regexFindAll ".{6}" (printf "%s00" $bits) -1) -}}
  {{- printf "%c" (index $alphabet (int (printf "0b%s" .))) -}}
{{- end -}}
{{- "=" -}}
{{- end -}}
