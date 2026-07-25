---
status: accepted
---

# Duplicate a deployment's ServiceAccount as a pre-install hook resource

Helm creates normal resources **after** `pre-install` hooks, so a deployment-level
`pre-install` hook Job that binds a chart-created ServiceAccount references an
object that does not exist yet and can never schedule its pod — the release stays
stuck in `pending-install` (issue #71). `hook.yaml` PART 2 therefore emits a
hook-prerequisite copy of that ServiceAccount, alongside the ConfigMap/Secret
copies that already exist for the same reason.

The copy carries the **same name**, annotations and automount as the real
ServiceAccount, is annotated `helm.sh/hook: pre-install` with weight
`minPreInstallJobWeight - 5` (keeping the invariant `prereq w-7 < SA w-5 < Job w`),
and uses `helm.sh/hook-delete-policy: hook-succeeded,hook-failed`. It is emitted
only for deployments whose `pre-install` hooks actually bind the deployment's
chart-created SA.

## Considered options

- **A dedicated name (`…-hook-sa`)**, mirroring the `-hook-config` / `-hook-secret`
  prereq copies — rejected. GCP Workload Identity and AWS IRSA bind an identity to
  `system:serviceaccount:<ns>:<name>`, so a differently-named ServiceAccount would
  strip the Job of exactly the permissions the operator is trying to give it, which
  is the use case in the issue. Sharing the name is the point; it is what forces the
  delete-policy choice below.
- **`before-hook-creation`** (Helm's default when the annotation is absent) —
  rejected. The copy would survive into the normal phase, where Helm has to create a
  ServiceAccount that already exists, and the pre-delete would be destructive the
  moment the copy is emitted for anything but a fresh install: deleting a live
  ServiceAccount mid-upgrade invalidates the bound tokens of running pods.
  `hook-succeeded,hook-failed` instead scopes the copy to the hook phase — Helm
  deletes `hook-succeeded` resources after all hooks of the phase have run, so the
  copy is gone before the real ServiceAccount is created and the two never collide.
- **Emitting the copy for `pre-upgrade` / `pre-rollback` too** — rejected. On those
  phases the ServiceAccount already exists, so creating the copy fails with
  `AlreadyExists`; making it work would require `before-hook-creation` and its
  destructive pre-delete.
- **Fail fast at template time** — rejected as the primary fix. It is honest but
  leaves the use case (chart-managed Workload Identity SA + `pre-install` migration)
  unsolved, and it cannot distinguish the broken combination from the many
  `pre-upgrade` releases where the SA already exists.
- **`lookup` to detect whether the ServiceAccount exists** — rejected. It returns
  nothing during `helm template` and `helm lint`, so rendering would differ between
  dry-run and install and the unit-test suite could not pin the output.

## Consequences

- One case stays uncovered and is documented rather than solved: a deployment added
  **in an upgrade**, with `serviceAccount.create: true` and a `pre-upgrade` hook. The
  chart cannot tell at template time that the deployment is new. Workarounds: bind a
  pre-existing SA (`create: false` + `name`), or move the job to `pre-install`.
- Root-level hooks (`.Values.hooks`) with an explicit `serviceAccountName` pointing
  at a chart-created deployment SA fail the same way and are deliberately left out:
  an explicit name means "an SA I manage", and ADR 0001 keeps root-level jobs
  standalone.
- The copy is correct only because Helm deletes `hook-succeeded` resources after the
  whole hook phase rather than per resource. Verified against Helm v4.2.3,
  `pkg/action/hooks.go`: the default `before-hook-creation` is applied only when no
  delete policy is set at all; `hook-succeeded` deletions run after every hook of the
  phase has executed; and when a hook Job fails, the already-successful hook
  resources are deleted under their `hook-succeeded` policy, so the copy is not
  leaked either way. If that ordering ever changes, the SA would vanish before the
  Job starts and this ADR must be superseded.
