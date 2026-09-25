---
status: accepted
---

# Copy a ServiceAccount the release creates under its own name, in every copy phase

Supersedes ADR 0002.

A hook Job bound to a ServiceAccount the release creates — a deployment's, or
an `rbacs.roles` entry's — references a normal resource. Helm applies it after
the `pre-*` hooks and deletes it before `post-delete`, so the pod never
schedules (issue #71). ADR 0002 answered this for `pre-install` only, with a
copy under the **same name** as the real SA and the delete policy
`hook-succeeded,hook-failed`, gone before Helm creates the real one.

That design holds under Helm, which runs `pre-install` once. It does not hold
under Argo CD (issue #141). Argo CD maps `pre-install` to `PreSync` and runs it
on **every** sync. From the second sync on, the same-name copy is applied over
the live SA, deleted with it by `hook-succeeded`, and the real SA is recreated
with a new UID in the Sync phase. The bound tokens of the running pods go with
it. ADR 0010 already avoided this for the `rbacs.roles` copy by giving it its
own names; this ADR does the same for every SA the release creates — a
deployment's, an `rbacs.roles` entry's and a cronjob's — and takes over the SA
copy ADR 0010 rendered for an `rbacs.roles` entry.

## The decision

- **Own name.** The copy is `<sa>-hook`, truncated to 63 like the real name,
  from the one `serviceAccountHookName` in `_helpers.tpl` — the helper ADR 0010
  introduced as `rbacServiceAccountHookName`, now shared by every SA copy.
  `validateNameCollisions` registers it, so a copy landing on another created
  SA fails the render, as does one that truncates back onto its own real name,
  with ADR 0010's message.
- **The hook runs as the copy.** `hookServiceAccountName` points the pod at
  `<sa>-hook` whenever `hookReadsServiceAccountCopy` matches.
- **Which phases.** `hookReadsPrereqCopy`'s: `pre-install`, `pre-upgrade`,
  `pre-rollback` and `post-delete`, not `pre-delete`. ADR 0002 excluded
  `pre-upgrade` because a same-name copy fails there with `AlreadyExists`; an
  own name removes the reason, and a revision that adds the deployment was the
  case ADR 0002 left uncovered.
- **Which lifecycle.** The `prereq` row of `hookAnnotations`: w-7 from the
  earliest consumer, `before-hook-creation,hook-succeeded`. The
  `pre-install-sa` row, and its `hook-succeeded,hook-failed` policy, are gone:
  both existed only because the copy shared the real SA's name. A failed hook
  does not leave the copy behind: when a Job fails, Helm deletes the hooks of
  the phase that ran before it under their `hook-succeeded` policy
  (`pkg/action/hooks.go`, `deleteHooksByPolicy(executingHooks[0:i],
  HookSucceeded)`), and the copy, at w-7, always ran before it. Argo CD does
  not: a failed `PreSync` deletes only the `HookFailed` resources, so the copy
  (with the real SA's annotations) stays until the next sync replaces it
  through `BeforeHookCreation`. The prereq ConfigMap and Secret, and the
  ExternalSecret and `rbacs.roles` copies, behave the same there.
- **One answer to "the release creates this SA".** `releaseServiceAccounts`
  scans every SA the release creates: an enabled deployment's, an
  `rbacs.roles` entry's, and a cronjob's own SA in either scope — a normal
  resource like the others, which a hook can name. `releaseCreatesServiceAccount`
  asks it. `serviceAccountCopyName`
  (the SA a copy binds, for rbac.yaml, hook.yaml and the validator) and
  `hookReadsServiceAccountCopy` (whether a hook runs as the copy) both read it.
  So a deployment that creates `app`, an `rbacs.roles` entry that binds `app`
  with `create: false`, and a `pre-install` hook running as `app` end up with
  one SA copy `app-hook`, bound by the RoleBinding copy
  and run as by the pod. That case used to work only because the ADR 0002 copy
  had the real name.
- **Both scopes.** The match is by resolved name, so a root-level hook naming
  the deployment's SA gets the copy too, even from a deployment with no hooks
  of its own. ADR 0002 left root-level hooks out, reading an explicit name as
  "an SA I manage"; the name is what the pod runs as, and the SA is missing all
  the same. One copy per SA, whatever the number of hooks and their scope, with
  the phases aggregated — the scan is `serviceAccountHookConsumers`.
- **One emitter.** hook.yaml renders every SA copy, whoever creates the SA,
  from the one consumer scan; `validateNameCollisions` registers each copy from
  the same scan and blames the SA's creator. This moves the copy of an
  `rbacs.roles` entry's SA out of rbac.yaml, where ADR 0010 had put it: two
  emitters would keep the phase and weight rules of one kind of copy in two
  places.

## Considered options

- **Keep the same name and document that Argo CD users must bind an existing
  SA** — rejected. The failure is silent and repeats on every sync, and the
  chart cannot tell that it runs under Argo CD.
- **Same name for `pre-install` only, own name elsewhere** — rejected, for the
  reason ADR 0010 gives: under Argo CD `pre-install` and `pre-upgrade` are the
  same `PreSync`, and `.Release.IsInstall` does not tell them apart.
- **`lookup` to see whether the SA exists** — rejected, as in ADR 0002: it
  returns nothing under `helm template`.

## Consequences

- **Behaviour change.** A hook bound to a SA the release creates no longer runs
  under that SA's name in the copy phases, so a Workload Identity or IRSA
  binding on `system:serviceaccount:<ns>:<sa>` does not reach it. This is the
  identity ADR 0002 kept by sharing the name. The copy carries the real SA's
  annotations, but a binding keyed on the name is not moved by them. The fix is
  the one ADR 0010 gives: create the SA outside the release and bind it with
  `create: false`.
- Hooks in the other phases (`post-*`, `pre-delete`, `test`) keep the real SA.
- `make e2e` runs a `pre-install` and a `pre-upgrade` hook bound to the
  deployment's chart-created SA, asserts that both ran as `<sa>-hook`, that the
  copy is gone after each hook phase, and that the real SA's UID survives the
  upgrade.
