---
status: accepted
---

# Basic Auth credentials are random on every render, and Argo CD keeps them

An HTTPRoute with `basicAuth.enabled` gets a Secret holding a username, a
password and its `.htpasswd` hash. The password has to come from somewhere
that values authors never write down, and the chart renders through
`helm template` in Argo CD, where `lookup` sees no cluster.

**The password is a new `randAlphaNum 32` on every render, and stable
credentials are supported only under Argo CD with `ignoreDifferences` on the
Secret's `/data` plus `RespectIgnoreDifferences=true`.** Argo CD creates the
Secret once and then keeps the whole tuple, so the hash always matches the
password. A plain `helm upgrade`, or deleting the Secret, rotates the
credentials; the README and the CHANGELOG say so before the first sync.

The tuple is kept whole: ignoring only `password` would leave `.htpasswd`
describing a password that no longer exists. The cost is that Argo CD stops
repairing any drift in that Secret, a later username edit included.

The hash is `{SHA}`, base64 of SHA-1, because that is the htpasswd format
Envoy Gateway reads. It is computed in the template from Sprig's hex digest
(`_basicauth-helpers.tpl`), since Sprig's `htpasswd` emits bcrypt.

## Considered options

- **`lookup` of the live Secret, reused when present.** Returns nothing under
  `helm template` and Argo CD, so every sync would still rotate; it works only
  for direct `helm upgrade`.
- **A hook Job that creates the Secret once.** A Job, its ServiceAccount and
  RBAC to write Secrets, all for one value, and a runtime step that
  `helm template` cannot check.
- **An ExternalSecret with a password generator.** Needs ESO and a generator
  on every cluster that enables Basic Auth, for a dev-route feature.
- **A password in values.** Puts the credential in Git.
