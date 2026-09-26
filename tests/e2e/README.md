# Runtime tests — `make e2e`

`helm-unittest` renders YAML; it cannot see the *runtime* half of this chart —
hook ordering, hook-weight sorting, `hook-delete-policy` cleanup, whether a
resource exists at the moment a hook Job schedules. Anything touching
`hook.yaml`, hook weights, delete policies or ServiceAccount lifecycle needs
`make e2e`.

## What the target does

`make e2e` downloads `kind` into `.bin/` (gitignored), creates a throwaway
cluster, installs KEDA (operator + CRDs, `kind-keda`) so the whole autoscaling
chain is exercised for real, installs External Secrets Operator with a
fake-provider `ClusterSecretStore` (`kind-eso`, `cluster-secret-store.yaml`),
installs `values.yaml` from this directory, then asserts: release deployed →
pre-install hook Job succeeded running as the chart-created SA's hook copy
`<sa>-hook` (ADR 0011), reading an
ExternalSecret's value through its hook copy by envFrom and by volume → the
copy and its Secret are gone after the hook phase → the surviving SA is the
real one, not the hook copy →
deployment `command`/`args` rendered → the SA a root-level `cronJobs` entry
references exists in the cluster → every Service `targetPort` resolved to a
container port and got endpoints → ScaledObject/TriggerAuthentication applied
with the `authenticationRef` resolved → KEDA marked the ScaledObject `Ready` and
created the derived HPA with the rendered bounds → the `cron` trigger actually
scaled the Deployment to its `desiredReplicas` → upgrade ran the pre-upgrade hook as `<sa>-hook` and kept the real SA's UID
(issue #141) →
upgrade did **not** reset `spec.replicas` on the KEDA-scaled Deployment →
rollback ran the pre-rollback hook as the `rbacs.roles` SA copy, reading the
ExternalSecret copy, the copies are gone and both real SAs kept their UID
(issue #143) →
post-delete hook read the ExternalSecret through its copy → uninstall leaves no orphaned
ConfigMap/Secret/ServiceAccount/ScaledObject/TriggerAuthentication/ExternalSecret, and the
derived HPA is garbage-collected with its ScaledObject.

Before all that, `check-helm-floor` runs `helm install --dry-run=client` through
`alpine/helm:3.18.5` and asserts that `NOTES.txt` warns about the Helm floor
(issue #116). It needs the cluster only because Helm 3 checks it is reachable
even on a client dry-run; nothing is applied. It reaches the API server on the
`kind` Docker network by the control-plane container's name, through its own
copy of the kubeconfig, so it never touches `~/.kube/config` either.

It also runs in CI as its own job in `.github/workflows/helm-ci.yml`.

Extend `values.yaml` and the assertion block in the `e2e` target when adding
runtime behaviour.

## `make e2e-argocd`

The same kind cluster, with Argo CD core (`kind-argocd`, version pinned in the
Makefile) and ESO instead of Helm running the hooks: under Argo CD `pre-install`
is `PreSync` and runs on every sync, and a failed operation marks every hook
`HookFailed`. `argocd/run.sh` packages the chart under a unique version, serves
it from an in-cluster Helm repository (`argocd/chart-repo.yaml`), applies
`argocd/application.yaml` and drives each sync itself (no automated sync), then
asserts: two syncs → the `pre-install` hook ran as `<sa>-hook`, the real SA kept
its UID, the copies are gone (issues #141, #149) → a PreSync hook that fails
after the copies (`argocd/break.yaml`) → the copies are gone at the failure
(`hook-failed`, ADR 0015) → with the failing hook fixed (`argocd/unbreak.yaml`)
the next sync passes (issue #164). The race itself depends on the garbage
collector's timing and is not reproduced: what is asserted is that no copy
survives the failure for the next attempt to race against.

It is a script rather than a Makefile recipe because it waits on Argo CD
operations; the kubeconfig pinning is the Makefile's, as for `make e2e`.

## Deliberate, and easy to undo by accident

- Hook bodies **assert** their environment instead of echoing it — `echo` exits
  0 whatever the prereq copies contain, which would make the "hook Job
  succeeded" assertion vacuous.
- The endpoint assertions read the **EndpointSlice ports**, not just whether the
  Service exists. A Service whose `targetPort` names nothing is created happily
  and its pod reports `serving: true`; only `ports: null` on the slice reveals
  it. Asserting on the Service object alone would be vacuous in the same way.
- One `pre-install` hook carries a **negative** `weight`, which drives the
  derived prereq weights negative too. That is the only runtime coverage of the
  never-floor-at-0 rule: with a floor, the prereq ConfigMap sorts after the Job
  and the Job starts without it. Keep a negative-weight hook in the scenario.
- The `cron` trigger is deliberate: no network, no external metric source. Its
  window covers the whole day bar one minute, so a run started in that blind
  minute before midnight UTC will fail the scale assertion.

## Noise that is not a bug

Installing KEDA logs `Warning: unrecognized format "int32"` (and `int64`). It
comes from KEDA's own CRDs — the ScaledJob schema embeds `batch/v1` JobSpec,
which carries many such formats — and Kubernetes warns on any format outside its
closed list while validating on `type: integer` regardless. Not worth filtering:
suppressing it means swallowing the install's stderr, which would hide real
server warnings too.

## Never a hand-rolled `helm install`

**Never run `helm install` against whatever `kubectl` context happens to be
selected** — it can be production. `make e2e` pins `KUBECONFIG` to
`.bin/kind-kubeconfig` and can only ever reach its own kind cluster; keep it
that way. The target also repoints the API server at the control-plane
container's address when it runs inside a container, where the kubeconfig's
`127.0.0.1` is the Docker host rather than the caller.
