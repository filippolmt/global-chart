---
status: accepted
---

# Duplicate an ExternalSecret as a hook prerequisite, under its own target name

A hook Job that reads a Secret produced by an `externalSecrets` entry of the same
release cannot start on the first install or sync (issue #110). The ExternalSecret is a
normal resource, so Helm applies it after the `pre-*` hooks. The pod of the hook waits
for a Secret that nothing creates until the hook finishes. Under Helm the release stays
in `pending-install` until `--timeout`. Under Argo CD both `pre-install` and
`pre-upgrade` map to `PreSync`, the `Sync` phase never starts, and the operation waits
indefinitely. It is the class of problem that ADR 0002 solved for the ServiceAccount.

We emit a hook-prerequisite copy of every ExternalSecret that a hook declares it
consumes, and the hook reads the Secret that the copy produces. It is the same shape as
the ConfigMap/Secret copies: the chart generates the name of the copy and injects it,
so the user never writes a generated name.

## The decision

- **An explicit reference, not name matching.** A job declares
  `externalSecrets: [<key>]`, where `<key>` is a key of the root `externalSecrets` map.
  The chart resolves the key to a Secret name. A key that does not exist in
  `externalSecrets` is a template `fail`.
- **Both scopes.** A root-level hook or cronjob declares `externalSecrets` like any other
  explicit reference. A deployment declares `externalSecrets` too, and its hooks and
  cronjobs inherit the list like every other inheritable field (`hasKey`, and `[]`
  stops the inheritance). The rule is the same in both scopes; only the source of the
  list differs.
- **Who reads which Secret.** The Deployment and every cronjob read the real Secret. A
  hook reads the copy. That is the only difference, and it is the one that
  `configMapRef` / `secretRef` already make for the deployment's own ConfigMap and
  Secret.
- **Two forms of an entry.** `- name: <key>` injects the Secret as an `envFrom` source.
  `- name: <key>` with `mountPath: <path>` mounts it as a volume. The chart generates
  the volume and the mount. The name of the generated volume is not a public interface,
  as for `mountedConfigFiles`.
- **Order in `envFrom`.** An `externalSecrets` entry is a secret source. The Deployment
  places it in the secret group (order by type). A job places it by proximity:
  inherited entries first, then its own. See *Sorgente d'ambiente* in `CONTEXT.md`.
- **The target name of the copy is its own**: `<target>-hook`, where `<target>` is the
  target name of the real ExternalSecret (`target.name`, or `<fullname>-<key>`).
  `validateNameCollisions` must cover the new name.
- **The content of the copy.** The `spec` of the copy is the `spec` of the real
  ExternalSecret, with exactly two changes: `target.name` is the name of the copy, and
  `target.creationPolicy` is forced to `Owner`. `deletionPolicy` is not overridden: the
  copy carries the original's (or the chart's `Retain` when the original sets none).
  The `spec` body moves into one helper that both `externalsecret.yaml` and the copy
  call, for the reason in ADR 0005: a copy that re-derives the body inline diverges in
  silence.
- **Lifecycle.** The copy takes the `prereq` row of the role table in
  `hookAnnotations`: weight Job − 7, `before-hook-creation,hook-succeeded`. No new row.
  *Amended by ADR 0015:* the row now adds `hook-failed`.
  The copy is keyed by ExternalSecret, not by deployment. One copy serves every hook
  that references the key, with `helm.sh/hook` aggregated across those hooks and the
  weight derived from the minimum of their Job weights.
- **Phases.** The copy is emitted for every `pre-*` phase of a hook that references it,
  not only for `pre-install`, and for `post-delete`. *Amended by ADR 0010:*
  `pre-delete` is no longer one. It runs before Helm deletes anything, so the real
  Secret is in place. Its own name means it never touches
  the real Secret, so it is safe on every phase. The chart cannot know at render time
  whether an upgrade adds the ExternalSecret (ADR 0002 rejects `lookup`). A
  `post-delete` hook runs after Helm has deleted the real ExternalSecret, and the
  garbage collector its Secret with it, so it has the same problem from the other end.
  Every other phase finds the real Secret in place, and its hooks read it: a hook reads
  the copy exactly when a copy is emitted for its phase. One predicate,
  `hookReadsPrereqCopy`, makes that cut for both sides.
- **`envFromSecrets` with a literal name stays valid.** It gets no copy and does not
  protect the first install. The README documents it as the path that does not.

## Considered options

- **Name matching** — rejected. The chart would compare every Secret reference of a Job
  (`envFromSecrets`, `volumes[].secret.secretName`, `env[].valueFrom.secretKeyRef`) with
  every target name, and then rewrite the user's string to point at the copy. That turns
  a generated name into a public interface, and CLAUDE.md says it is not one.
- **Copy every ExternalSecret whenever a `pre-*` hook exists** — rejected. It needs no
  detection, but it creates one extra Secret per ExternalSecret, including the ones no
  hook reads.
- **A copy that shares the target name of the real ExternalSecret** — rejected, and not
  a matter of taste. When one ExternalSecret owns a Secret under `Owner`, a second one
  that targets it gets `ErrSecretIsOwned` and goes `Ready=False`. When the copy owns it,
  the deletion of the copy (`hook-succeeded`, or `before-hook-creation` at the next
  upgrade) garbage-collects the live Secret through its ownerReference. With `Orphan`
  on both sides there is no detection at all: each refresh overwrites the other.
- **Keep the `creationPolicy` of the original** — rejected. `Merge` and `None` never
  create the Secret, so the copy would produce nothing. `Orphan` would leave the Secret
  of the copy behind after the hook phase. `Owner` is what makes the Secret disappear
  with the copy, and the plumbing has to clean itself up (the Secret holds the secret
  data of the release).
- **An initContainer that waits for the Secret** — rejected. It needs an image and RBAC
  that the chart does not otherwise require, and the kubelet already does the waiting.
- **Per-resource `annotations` on `externalSecrets.<name>` and on the Deployment**, so
  that Argo CD users order the sync with `argocd.argoproj.io/sync-wave` — not rejected,
  but out of scope. It fixes nothing under Helm, and it only helps users who wire the
  waves themselves. It is a separate issue. (Since built, issue #112: both take
  `annotations`, and the hook copy deliberately does **not** inherit the
  ExternalSecret's own — it is a hook resource, ordered by phase and weight, and a
  sync-wave copied onto it would contradict them.)

## Consequences

- **Under Helm, a broken store hangs the hook until `--timeout`.** Helm waits only for
  Job and Pod hooks, so it moves to the Job as soon as the copy is created. The pod of
  the hook stays in `CreateContainerConfigError` (`envFrom`) or `ContainerCreating`
  (volume) and the kubelet retries. The pod never reaches `Failed`, so `backoffLimit`
  does not bound the wait. `--timeout` (default 5m) and the Job's
  `activeDeadlineSeconds` do; hooks accept `activeDeadlineSeconds` for this reason. The
  README documents it.
- **Under Argo CD, a broken store fails the sync fast.** Argo CD checks the health of
  hook resources that are not Jobs before the next wave, and its built-in
  `ExternalSecret` check maps `Ready=False` to Degraded. A transient provider error
  during the hook phase therefore fails the sync, where Helm would have waited it out.
- **The Secret of the copy is removed asynchronously.** Helm (or Argo CD) deletes the
  copy after the whole hook phase, and the Kubernetes garbage collector deletes its
  Secret afterwards through the ownerReference. *Amended by ADR 0015:* a copy created
  while that removal is still pending finds its target taken (`already exists`), which
  under Argo CD `retry` is the attempt after any failure. The copy now deletes itself on
  failure as well, so the removal runs during the retry backoff.
- **The facts this ADR rests on** were verified on 2026-09-24 against
  `external-secrets/external-secrets` (`pkg/controllers/externalsecret/externalsecret_controller.go`,
  `applyOwnership`; `docs/guides/ownership-deletion-policy.md`), `helm/helm`
  (`pkg/kube/statuswait.go`, `pkg/kube/wait.go`: `WatchUntilReady` waits only for Job and
  Pod), and `argoproj/argo-cd` (`gitops-engine/pkg/sync/sync_context.go`;
  `resource_customizations/external-secrets.io/ExternalSecret/health.lua`). If ESO stops
  refusing a second owner, or Helm starts waiting for custom resources, revisit it.
