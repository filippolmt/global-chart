{{/*
Envoy Gateway JWT authentication on an HTTPRoute (securitypolicy.yaml, issue
#261). Rules:
- the SecurityPolicy takes the route's own name and targets only that route;
  jwt and basicAuth never share a route (securitypolicy.yaml fails first)
- providers render verbatim, without their null map values
  (toYamlWithoutNulls); the schema holds their shape, bounds and Envoy's CEL
  rules, this helper what the API server accepts and Envoy Gateway refuses:
  no provider, two providers of one name (the policy is dropped and the route
  serves unauthenticated)
- a null name, issuer or audiences fails: dropped, issuer or audiences would
  render a policy without the check the schema requires

Returns the policy's jwt block, for spec. ctx is the values path of the jwt
block, jwt the block itself.
Usage: {{- $spec := include "global-chart.jwtSpec" (dict "ctx" "httpRoute.jwt" "jwt" $jwt) -}}
*/}}
{{- define "global-chart.jwtSpec" -}}
{{- $ctx := .ctx -}}
{{- $providers := default (list) .jwt.providers -}}
{{- if not $providers -}}
  {{- fail (printf "%s.providers: needs at least one provider when %s.enabled is true." $ctx $ctx) -}}
{{- end -}}
{{- include "global-chart.rejectNullItems" (dict "list" $providers "errCtx" (printf "%s.providers" $ctx) "required" (list "name" "issuer" "audiences")) -}}
{{- $seen := dict -}}
{{- range $i, $p := $providers -}}
  {{- if eq (include "global-chart.isSet" (list $p "name")) "true" -}}
    {{- $name := toString $p.name -}}
    {{- if hasKey $seen $name -}}
      {{- fail (printf "%s.providers[%d].name: %q is also the name of providers[%d]; Envoy Gateway drops a policy whose providers share a name, and the route serves unauthenticated." $ctx $i $name (index $seen $name)) -}}
    {{- end -}}
    {{- $_ := set $seen $name $i -}}
  {{- end -}}
{{- end -}}
{{- printf "jwt:\n  providers:\n%s" (include "global-chart.toYamlWithoutNulls" $providers | indent 4) -}}
{{- end -}}
