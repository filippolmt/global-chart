---
status: accepted
---

# One module for ConfigMap and Secret data bodies

A deployment's ConfigMap and Secret are duplicated as hook-prerequisite copies, so
that a hook Job finds them already present (ADR 0002 explains why the copies have to
exist before Helm creates the real resources). The contract of a copy is that its
`data` is byte-identical to the real resource's: only the metadata differs. Nothing
enforces that contract. `hook.yaml` re-derives both serialization rules inline —
`kindIs "map"/"slice" → toYaml, else toString | quote` for the ConfigMap,
`kindIs "string" → b64enc, else toYaml | b64enc` for the Secret — byte-for-byte
identical to `configmap.yaml` and `secret.yaml`. A change to either real resource
does not reach its copy, and the failure is silent: the manifest stays valid, the
hook Job runs, and it reads values that differ from the ones the Deployment will get.

We move the two `data` bodies into `renderConfigMapData` and `renderSecretData` in
`_render-helpers.tpl`. Four call sites, two rules, one home each.

The helpers render the *body* only — the `key: value` lines at indent 0 — and each
caller keeps its own `data:` key and applies `nindent 2`. They are pure serialization
of a map: they take the map, read nothing from the root context, and know nothing
about hooks. The guards that decide whether a `data:` block is emitted at all stay at
the call sites, unchanged; on an empty map a helper returns the empty string, which
those guards already make unreachable.

## Considered options

- **One parametrised helper**, `renderDataBlock(data · encode=plain|b64)` — rejected.
  The two rules are not one rule with a flag: the ConfigMap discriminates on
  `map`/`slice` and the Secret on `string`, and the non-matching branch differs in
  both directions. The parameter would re-expose the branch to the caller, which is
  the definition of a shallow module.
- **Let the helper own the `data:` key** — rejected. In the Secret, `type: Opaque`
  sits between `metadata` and `data`, so the two callers would still have to differ
  around it; and every other helper in `_render-helpers.tpl` emits a fragment its
  caller places.
- **Extract the whole prerequisite copy, metadata included, from a single
  template** — rejected. The metadata is where the copy legitimately differs (hook
  labels with component, the three `helm.sh/hook*` annotations), so a single
  template would need an "am I the copy?" flag: the seam moved inside the module
  instead of removed.
- **Replace the duplicated assertions with one equality test,
  `prereq.data == real.data`**, as the review report proposed — rejected.
  `helm-unittest` asserts one document at a time; an equality between two documents
  can only be written by restating the expected value twice, which is the same
  duplication moved into the tests, with less coverage than the per-document
  assertions it would replace.
- **Do nothing: 8 duplicated lines are cheap** — rejected. The cost is not the
  8 lines, it is that the divergence they permit is undetectable at render time.

## Consequences

- The rendered manifests are unchanged. That is the acceptance criterion, and it is
  checked with a `helm template` diff over the lint scenarios, before and after.

  *Amended after the fact:* the extraction itself left the output identical, and the
  diff confirmed it. A separate bug the extraction made visible was then fixed in the
  same PR, and it does change one branch of the output: a map/slice `configMap` value
  rendered as a nested YAML mapping, which `ConfigMap.data` (`map[string]string`)
  cannot hold — the manifest was rejected at apply time, at the real ConfigMap and at
  its prerequisite copy alike. It renders as a block scalar now. No lint scenario
  exercised that branch, which is why the diff was silent about it and kubeconform
  never saw it; `tests/deployment-hooks-cronjobs.yaml` exercises it now.
- A coverage gap surfaced while deciding this, and it is the more valuable half of
  the change: **no test asserts `data` on the prerequisite copies at all** (the
  existing prereq cases in `hook_test.yaml` assert kind, hook type, weight and
  presence), and the non-string branch is untested at every one of the four sites —
  `configmap_test.yaml` covers only string and numeric values, `secret_test.yaml`
  only string values. The PR adds a map/slice case for the ConfigMap, a non-string
  case for the Secret, and `data` assertions on both copies with the same values.
  Those tests, not the extraction, are what would have caught a divergence.
- ADR 0002 is untouched: only the two `data:` bodies move, never the ServiceAccount
  copy.
- CLAUDE.md gains the two helpers in the `_render-helpers.tpl` row.
- No version bump; a `Changed` entry accumulates in `## [Unreleased]`.
