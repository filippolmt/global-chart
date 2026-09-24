---
status: accepted
---

# `rbacs.roles[].name` is a required DNS-1123 subdomain

`rbacs.roles[].name` was `{"type": "string"}`, so no value was rejected (issue
#121). It becomes three names: the Role and the RoleBinding, which Kubernetes
validates only as path segments, and — when `serviceAccount` has no `name` of
its own — the ServiceAccount `<name>-sa`, which must be a DNS-1123 subdomain.
`Reader_Role` with `serviceAccount: {}` rendered, passed `helm lint`, and was
rejected by the API server.

## Decisions

**The name is a *Chiave nominante*, although it is a list field and not a map
key.** It plays the same part — it identifies the entry and becomes a name — so
the glossary entry was widened rather than a second term coined.

**The constraint is `$defs/dns1123Subdomain` with `maxLength: 253`, applied
whether or not a `serviceAccount` sits next to it.** The SA subdomain is the
tightest place the value lands; the constraint must not depend on neighbours.
The name is used verbatim, without the fullname, so unlike the
`externalSecrets` keys it can carry a real length bound.

**No `maxLength: 60`.** A name longer than 60 makes `<name>-sa` truncate to 63,
a shorter but valid ServiceAccount. The glossary rejects only what could never be
applied, and that name applies. The risk truncation carries is a collision, not
invalidity — see below.

**`required: [name]` stays; the default `<fullname>-role-<index>` is deleted.**
The default was unreachable since the schema required `name`. Activating it
would be a feature, and a bad one: a name derived from the list position renames
every later Role, SA and RoleBinding when an entry is inserted ahead of them,
breaking every external reference to the SA.

## Out of scope, as follow-up issues

- **Collisions between roles.** Three cases render and lint, then conflict or
  share a resource at install: two entries with the same `name`; `foo` and
  `foo-role`, which both yield the RoleBinding `foo-rolebinding` because of the
  `trimSuffix "-role"`; two names over 60 characters sharing a prefix, which
  yield the same default SA. JSON Schema cannot express per-field uniqueness, so
  this is a `fail` in `validateNameCollisions` with `bad-values/fail/` fixtures —
  another mechanism, another issue.
- **An explicit `serviceAccount.name`** has the same defect (`Reader_SA`), but
  `$defs/serviceAccount` is shared with `deployments.<name>.serviceAccount`.
  Constraining it touches deployments too, and it is a name given as a value,
  not a *Chiave nominante*.

## Implementation

- `values.schema.json`: `rbacs.roles.items.properties.name` becomes
  `{"$ref": "#/$defs/dns1123Subdomain", "maxLength": 253}`; update the
  `dns1123Subdomain` description, which lists its callers.
- `rbac.yaml`: drop `$defaultRoleName` and the `ternary`; `$roleName` is
  `$role.name`.
- Fixture `tests/bad-values/schema/rbacs-role-invalid-name.yaml` (e.g.
  `Reader_Role`), after the #114 ones. It is not a closure fixture, so no
  `# covers:` line.
- `CHANGELOG.md`: a `### Fixed` entry under `## [Unreleased]`. **No release**:
  no version bump in `Chart.yaml`, no tag.
- Run `make lint-chart`, `make unit-test`, `make validate-bad-values`,
  `make generate-docs`.
