---
status: accepted
---

# The hook-prerequisite copies delete themselves on failure too

Amends ADR 0007 and ADR 0011.

Under Argo CD with `syncPolicy.retry`, the attempt after a failed sync can fail
on the ExternalSecret copy with `secrets "<target>-hook" already exists`
(issue #164). Attempt N fails after the copies were created, so `hook-succeeded`
never fires and the copy stays, with the Secret it owns. Attempt N+1 starts on
its own; `before-hook-creation` deletes the old copy and creates the new one at
once, while the old Secret waits for the garbage collector. The new copy finds
its target taken and is not Ready, and Argo CD checks the health of non-Job hook
resources before the next wave, so the attempt fails. ADR 0011 already recorded
the premise: a failed `PreSync` deletes only the `HookFailed` resources.

## The decision

- **The `sa` and `prereq` rows of the role table in `hookAnnotations` default
  to `before-hook-creation,hook-succeeded,hook-failed`.** Argo CD applies
  `HookFailed` to every hook of the operation on any failure, in the Sync phase
  too, and `HookSucceeded` only when the whole operation succeeds. With
  `hook-failed`, a failed attempt deletes its copies as it ends, and the
  garbage collector has the whole retry backoff to remove what they owned.
- **The `job` row is unchanged.** A failed hook Job is the record of what broke;
  `before-hook-creation` alone keeps it until the next attempt.
- **An explicit `deletePolicy` still wins** for the roles a hook owns (its Job
  and its SA), as ADR 0004 has it.
- Under Helm nothing changes in practice: a failed hook already deleted the
  copies that ran before it through their `hook-succeeded` policy (ADR 0011),
  and now the failing phase's own plumbing goes too.

## Considered options

- **A new target name per attempt**, so two consecutive copies never share one
  — rejected, it cannot be built. Argo CD renders with `helm template`, where
  `.Release.Revision` is always 1, and a hash of the spec is the same on the
  retry that renders the same spec.
- **Foreground deletion of the copy** — not reachable: neither
  `helm.sh/hook-delete-policy` nor Argo CD's hook deletion exposes the
  propagation policy.
- **Document and live with it** — rejected: under `retry` it is the normal path
  after any failure, and one lost attempt is one backoff interval.

## Consequences

- **A residual race remains** with `syncOptions: [PrunePropagationPolicy=background]`
  and a retry faster than the garbage collector: the deletion at `HookFailed`
  returns before the owned Secret is gone. Argo CD deletes with foreground
  propagation by default, which waits for the dependents.
- A failed attempt leaves no copy behind to inspect. The copy is the real
  resource with a different name, so the real resource is the thing to read.
- `make e2e-argocd` asserts the condition the race needs is gone: after a
  PreSync hook fails behind an `externalSecrets` hook, the copies and the
  copy's Secret are deleted, and the next sync passes. It does not reproduce
  the race itself, which depends on the garbage collector's timing; with the
  old policy it fails on the surviving copies.
