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

For every `rbacs.roles` entry whose SA a `pre-*` or `post-delete` hook runs as, we
emit a hook-prerequisite copy: the Role, the RoleBinding, and the SA as well when
the entry creates it. The hook runs as whatever SA the copy binds.

## The decision

- **Who reads the copy.** A hook of a phase that `hookReadsPrereqCopy` names, the
  same phase cut as ADR 0007, in either scope. Its resolved ServiceAccount must
  meet two conditions:
  - it is bound, not created by the hook itself (`create: false`);
  - its name is the SA of at least one `rbacs.roles` entry, whether the entry
    creates that SA or binds an existing one.

  The match is by resolved name, so a hook that inherits its deployment's SA
  matches a role that binds that SA. It lives in one helper,
  `hookRbacServiceAccount`. Both the consumer scan (which emits the copies) and
  `hook.yaml` (which redirects the pod) call it, so they cannot disagree. Any
  other phase finds the real resources in place.
- **Own names, never the real ones.** The copies are named `<role>-hook`,
  `<binding>-hook` and `<sa>-hook`, each truncated like the real name
  (`rbacHookName`).
  - The reason is Argo CD, which runs `pre-install` on every sync. A copy
    sharing the real name would be applied over the live resource and then
    deleted by `hook-succeeded`, and the live resource would go with it.
  - `validateNameCollisions` registers all three names, so a copy that lands on
    another entry's name fails the render. So does a copy that truncates back
    onto its own real name.
- **Which SA the copy binds.** If an `rbacs.roles` entry creates the SA, the copy
  binds `<sa>-hook` and the hook's pod is redirected to it. If not, the SA exists
  outside the release: the copy binds it as is and the hook keeps its identity.
  The choice lives in one helper, `rbacCopyServiceAccountName`, for the copy's
  subject and for the pod alike. When several entries share one SA, each entry's
  copied RoleBinding binds the same SA the hook runs as.
- **One copy per entry, whatever the number of hooks.** The copy's phases are the
  union of its consumers' phases. Its weight comes from the earliest consumer, on
  the `prereq` row (w-7, `before-hook-creation,hook-succeeded`), keyed by role
  name the way ADR 0007 keys by ExternalSecret. The SA copy carries the real SA's
  annotations and automount.

## Considered options

- **The same name as the real resources, as in ADR 0002.** Rejected, for the
  Argo CD reason above. This design keeps the identity of every SA that exists
  outside the release, and changes it only for a SA the release itself creates.
- **Redirect only on `pre-install`, where the real SA is absent.** Rejected. Under
  Argo CD `pre-install` and `pre-upgrade` are the same `PreSync`, and
  `.Release.IsInstall` does not tell them apart.
- **`lookup` to find out whether the real resources exist.** Rejected for the
  reason ADR 0002 gives: it returns nothing under `helm template`, so the
  rendered output would differ between dry-run and install.

## Consequences

- **A SA the role creates loses an identity keyed on its name.** A Workload
  Identity or IRSA binding on `system:serviceaccount:<ns>:<sa>` does not reach
  `<sa>-hook`. This holds in every copy phase, the upgrades included. The fix is
  to create the SA outside the release (Terraform, say) and bind it with
  `create: false`.
- **ADR 0002 has the same Argo CD exposure.** Its same-name copy of a deployment's
  SA runs on every `PreSync`. This ADR does not change it; the question is filed
  as issue #141.
- `make e2e` runs a `pre-install` and a `pre-upgrade` hook that list ConfigMaps
  with their own token. That call fails without the Role copy, and the pod never
  schedules without the SA copy. The run then checks that the copies are gone
  after the hook phase and that nothing is left behind after uninstall.
