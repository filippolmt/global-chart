---
status: accepted
---

# Duplicate an rbacs.roles entry as a hook prerequisite, under its own names

A hook Job can run as the ServiceAccount of an `rbacs.roles` entry and use that
entry's rules: a `pre-upgrade` hook that scales a Deployment down, for example.
The SA, the Role and the RoleBinding are normal resources, so Helm applies them
after the `pre-*` hooks and deletes them before `post-delete`.

- **On the first install**, the Job names a SA that does not exist yet, and its
  pod never schedules.
- **Under Argo CD**, both `pre-install` and `pre-upgrade` map to `PreSync`, so
  the first sync of a new Application waits for a SA that nothing creates.
- **When the role binds a SA that already exists**, the pod starts but runs
  without the Role's rules: every call it makes is forbidden.

This is the same class of problem that ADR 0002 solved for the deployment's SA and
ADR 0007 for ExternalSecrets.

For every `rbacs.roles` entry whose SA a `pre-install`, `pre-upgrade`,
`pre-rollback` or `post-delete` hook runs as, we emit a hook-prerequisite copy: the Role, the RoleBinding, and the SA as well when
the entry creates it. The hook runs as whatever SA the copy binds.

## The decision

- **Which phases.** The ones `hookReadsPrereqCopy` names, the same cut as ADR
  0007:
  - `pre-install`, `pre-upgrade` and `pre-rollback` run before the revision's
    normal resources are applied. On an upgrade or a rollback the chart cannot
    tell whether that revision adds the entry, and ADR 0002 rejects `lookup`.
  - `post-delete` runs after they are gone.
  - `pre-delete` is **not** one. It runs before Helm deletes anything, against
    the release that is still installed, so the real resources are in place. A
    copy there would only move the pod off the SA an identity binding is keyed
    on. This narrows ADR 0007's cut as well, which included `pre-delete` without
    needing it: a `pre-delete` hook reads the real Secret.
- **Who reads the copy.** A hook of one of those phases, in either scope. Its
  resolved ServiceAccount must meet two conditions:
  - it is bound, not created by the hook itself (`create: false`);
  - its name is the SA of at least one `rbacs.roles` entry, whether the entry
    creates that SA or binds an existing one.

  The match is by resolved name, so a hook that inherits its deployment's SA
  matches a role that binds that SA. It lives in one helper, `hookRbacCopy`,
  over one scan of the entries by SA name, `rbacServiceAccounts`, both in
  `_serviceaccount-helpers.tpl`. Both the consumer scan `rbacHookConsumers`
  (which emits the copies) and `hookServiceAccountName` (which `hook.yaml` calls
  to pick the pod's SA) go through it, so they cannot disagree. Any other phase
  finds the real resources in place.
- **Own names, never the real ones.** The copies are named `<role>-hook`,
  `<binding>-hook` and `<sa>-hook`, each truncated to the real name's own limit:
  253 for the Role, 63 for the RoleBinding and the SA. One name helper per kind
  in `_helpers.tpl` (`rbacRoleHookName`, `rbacRoleBindingHookName`,
  `rbacServiceAccountHookName`), each the home of its constant. *Amended by ADR
  0011:* the SA one is now `serviceAccountHookName`, shared with the copy of a
  deployment's SA.
  - The reason is Argo CD, which runs `pre-install` on every sync. A copy
    sharing the real name would be applied over the live resource and then
    deleted by `hook-succeeded`, and the live resource would go with it.
  - `validateNameCollisions` registers all three names, so a copy that lands on
    another entry's name fails the render. So does a copy that truncates back
    onto its own real name. The message tells the user to change the name: the
    copy takes its name from the real resource, so an explicit
    `serviceAccount.name` or `create: false` would not move it.
- **Which SA the copy binds.** If an `rbacs.roles` entry creates the SA, the copy
  binds `<sa>-hook` and the hook's pod is redirected to it. If not, the SA exists
  outside the release: the copy binds it as is and the hook keeps its identity.
  *Amended by ADR 0011:* "creates" now means the release creates it, a
  deployment's SA included, and the helper is `serviceAccountCopyName`.
  The choice lives in one helper, `serviceAccountCopyName` (originally
  `rbacCopyServiceAccountName`), for the copy's
  subject, for the pod and for the validator alike. *Amended by ADR 0011:* the
  SA copy itself is rendered by hook.yaml, with every other SA copy. When several entries share one SA, each entry's
  copied RoleBinding binds the same SA the hook runs as.
- **One copy per entry, whatever the number of hooks.** The copy's phases are the
  union of its consumers' phases. Its weight comes from the earliest consumer, on
  the `prereq` row (w-7, `before-hook-creation,hook-succeeded`), keyed by role
  name the way ADR 0007 keys by ExternalSecret. The SA copy carries the real SA's
  annotations and automount, and the Role copy's rules come from the same
  `renderRoleRules` as the real Role's.
- **One enumeration of the hooks.** `prereqCopyHooks` walks both scopes once, for
  the ExternalSecret scan and the `rbacs.roles` scan alike, keyed by the hook's
  values path (`jobValuesPath`).

## Considered options

- **The same name as the real resources, as in ADR 0002.** Rejected, for the
  Argo CD reason above. This design keeps the identity of every SA that exists
  outside the release, and changes it only for a SA the release itself creates.
- **Redirect only on `pre-install`, where the real SA is absent.** Rejected. Under
  Argo CD `pre-install` and `pre-upgrade` are the same `PreSync`, and
  `.Release.IsInstall` does not tell them apart.
- **Keep `pre-delete` in the phase cut, as ADR 0007 had it.** Rejected. The real
  resources are there in that phase, so the copy buys nothing and costs the
  identity of a SA the entry creates.
- **`lookup` to find out whether the real resources exist.** Rejected for the
  reason ADR 0002 gives: it returns nothing under `helm template`, so the
  rendered output would differ between dry-run and install.

## Consequences

- **A SA the role creates loses an identity keyed on its name.** A Workload
  Identity or IRSA binding on `system:serviceaccount:<ns>:<sa>` does not reach
  `<sa>-hook`. This holds in every copy phase, the upgrades and rollbacks
  included. The fix is
  to create the SA outside the release (Terraform, say) and bind it with
  `create: false`.
- **ADR 0007 loses `pre-delete`.** An ExternalSecret referenced only by a
  `pre-delete` hook no longer gets a copy, and the hook reads the real Secret,
  which is still there.
- **ADR 0002 has the same Argo CD exposure.** Its same-name copy of a deployment's
  SA runs on every `PreSync`. This ADR does not change it; the question is filed
  as issue #141, and answered by ADR 0011.
- `make e2e` runs a `pre-install`, a `pre-upgrade` and a `post-delete` hook that
  list ConfigMaps with their own token. That call fails without the Role copy, and the pod never
  schedules without the SA copy. The run then checks that the copies are gone
  after the hook phase and that nothing is left behind after uninstall.
