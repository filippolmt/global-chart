# Global-chart

Reusable Helm chart providing multi-deployment Kubernetes building blocks. This
glossary pins down terms whose meaning is specific to how this chart models
workloads, where the same Kubernetes word can mean two different things.

## Language

**SA-object automount**:
`automountServiceAccountToken` set on a ServiceAccount object the chart
_creates_ (`serviceAccount.create: true`), via `serviceaccount.yaml` /
`rbac.yaml`. Inert when the SA is externally managed (`create: false`) — the
chart doesn't own that object.
_Avoid_: "the automount setting" (ambiguous with pod-level).

**Pod-level automount**:
`automountServiceAccountToken` set directly on a pod spec
(`deployments.<name>.automountServiceAccountToken`). Overrides whatever the bound
ServiceAccount declares, so it is the only lever when the SA is externally
managed. Opt-in: omitted from the rendered pod unless explicitly set.
_Avoid_: "the automount setting" (ambiguous with SA-object).
