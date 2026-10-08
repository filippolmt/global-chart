# Global-chart

Reusable Helm chart providing multi-deployment Kubernetes building blocks. This file is only a glossary: no implementation details and no design decisions (those live in `docs/adr/`).

## Language

**Vendor-neutral**:
The property that no third-party operator or CRD is *required* to use the chart. Vendor-specific resources are allowed as long as they are opt-in and guarded by a capability check that fails the render when the CRD is not registered. It does not mean "core Kubernetes APIs only": the chart already renders KEDA and External Secrets resources under these conditions. An annotation aimed at an external controller is not a resource and has no CRD to check: it is allowed as long as it is opt-in, and without the controller it stays inert. It breaks nothing, but it does nothing either, and the chart cannot tell.
_Avoid_: vendor-agnostic, portable, neutral

**Root scope / deployment scope**:
The two places where a CronJob or a hook can be declared. In the *root scope* the Job is standalone: it inherits nothing and references explicitly what it needs. In the *deployment scope* the Job belongs to a Deployment and inherits its image, configuration, ServiceAccount and placement on the cluster, unless overridden. Placement is where and with which precedence the pod is scheduled: the nodes it may occupy and the priority with which it competes for them with other pods. The scope says where the values come from, never which rule interprets them: a rule whose outcome changes with the scope is a defect, not a feature.
_Avoid_: top-level, standalone (for the root scope, when the contrast is with the deployment scope), nested

**Hook role**:
What a resource is within Helm's hook sequence: the Job to run, the ServiceAccount that runs it, or a hook prerequisite copy. It is an axis orthogonal to the scope: the scope says where the values come from, the role says when the resource must exist relative to the others.
_Avoid_: hook type (that is `helm.sh/hook`, i.e. the phase: pre-install, post-upgrade…), category, kind

**Hook prerequisite copy**:
A hook-annotated duplicate of a resource that a hook's Job must find already in place. It exists because Helm creates the normal resources only after the hooks, so the original is not there yet when the Job is scheduled. It lives only for the duration of the hook phase, whether the phase succeeds or fails: a copy that survives a failed attempt is what the next attempt collides with. The copy's content is that of the real resource. The copy differs only in its metadata and, when the resource produces another one, in the name of what it produces and in owning it: what the Job must find is the produced resource, and the data it resolves stay the same. Owning it is what makes it disappear together with the copy: a copy that writes into something another resource owns, or that leaves it behind, is no longer just a copy. A copy whose content diverges from the original is not a copy. It is a second resource, and the divergence does not show, because no manifest becomes invalid.
A copy never carries the real resource's name: it exists in every phase where the real resource might be missing, and in at least one of those phases the real resource is already there. A tool that reruns the hooks on every sync would overwrite it and then delete it. The price is the identity bound to the name: a Job that runs as the copy of a release-created ServiceAccount does not inherit its external identity.
_Avoid_: temporary copy, shadow resource, support resource

**Release-created ServiceAccount**:
A ServiceAccount that the chart itself creates, for a deployment or for a role entry, as opposed to one the chart merely binds because it already exists outside the release. The distinction decides whether a hook that must find it before the normal resources runs as the copy or as the original: a release-created ServiceAccount is copied, an external one is used as is. Who creates it does not change the answer: the same question has one answer for every hook, in both scopes.
_Avoid_: managed SA, chart SA, internal SA

**Primary port**:
The port a deployment's Service exposes when no other is declared. It is the only one with defaults of its own: number, name, protocol and target port exist even when nobody writes them, while every extra port must be declared in full. A default that holds for the primary port does not automatically hold for an extra port, nor for the port of a Service the chart does not create.
_Avoid_: default port, first port, http port

**HTTP routing layer**:
The single point of the release through which HTTP traffic reaches the deployments: an Ingress or the Gateway's HTTP routes, never both. There can be more than one HTTP route (one per hostname or per Gateway) and they remain a single layer: what counts is the resource kind, not the number. One per release, because two layers on the same hostnames are two answers to the same question, and which one wins is decided by the infrastructure, not by the chart. It concerns HTTP only: L4 routes are not a routing layer and do not compete with it.
_Avoid_: routing layer (without "HTTP"), ingress layer, exposure layer

**L4 route**:
A Gateway route that forwards a TCP or UDP port to a Service without interpreting its application protocol: no hostname, no path, no header to decide on. It exists for protocols that are not HTTP. A release can have as many as it needs, even on different Gateways, and they coexist with the HTTP routing layer because they serve different ports. An L4 route forwards only to a port of the same protocol: a TCP route to a UDP port is not an unusual configuration but an error, because Kubernetes accepts it and the traffic never arrives.
_Avoid_: TCP ingress, stream route, non-HTTP route

**Replica owner**:
What decides how many pods a Deployment runs: the Deployment itself, with the fixed number it declares, or an autoscaler, either the one the chart renders or the one KEDA derives for itself. The owner is always exactly one. The Deployment gives up the number only to an autoscaler that really exists and has something to measure: a configuration where the Deployment gives up the number without anyone taking it is not a reasonable default but an error, because Kubernetes fills the gap with a single pod and nobody reports it. Likewise, two autoscalers on the same Deployment are not redundancy but two owners.
_Avoid_: who scales, replica manager

**Mounted config file**:
A configuration file whose content lives in the values and that the chart materialises in a dedicated ConfigMap, mounted in the Deployment's pod. It describes the *Deployment's runtime*: it is neither release configuration nor shared material, and for this reason no job of the deployment scope inherits it. A migration hook is not that runtime. The two forms in which it is declared (a single file with its target path, or a bundle mounted as a directory) are ways of mounting it, not different things: they share one namespace, and two entries with the same name are a collision, not two files.
_Avoid_: mounted file, config file, configuration volume

**Watched source**:
A configuration source that the chart renders and that a Deployment's pod reads, whose change must replace the pods. The boundary is what the chart sees: a source the chart only references by name, or a value that lives in an external store, is not watched, and changing it replaces nothing. Something outside the chart is needed. A source rendered but not watched is a defect: the resource changes, the pods do not, and the release's hooks, which read the freshly created copy, run with a configuration different from the pods'. Watching a source says that the pods are replaced, not that the new pods already read the new content: when an operator produces the resource, the pods can start before the operator has updated it. The chart can hand a source it does not see to an external controller, telling it which resources to watch, but handed over does not mean watched: the chart does not know whether the controller exists or whether it reacts.
_Avoid_: checksum, rollout trigger, config watch

**Naming key**:
A key of a values map, a field that identifies a list entry, or a scalar values field (a name override) that becomes part of the name of something Kubernetes or Helm validate: a resource, a container, a label, a hook's type. Its constraint is the set of what the tightest place it lands in accepts, not a stricter uniform rule: only what could never be applied is rejected. The constraint is the same in both scopes, even when one of them truncates and the other does not, and it does not depend on what sits next to it in the values: adding a hook must not invalidate a key that was valid before. A name override is an exception only in appearance: it names the whole release, not a resource, so its tightest place is what the release actually renders, and a value that is valid as a name but not as a label is rejected only when the release renders something that uses it as a label. The neighbour does not change the constraint: it changes what the value names.
_Avoid_: map name, id, map key (when the key that generates names is meant)

**Common annotation**:
An annotation that applies to every resource the chart creates, as opposed to the per-resource annotation that specialises only one of them. The two are not alternatives: when both name the same key, the per-resource value is the one that counts, always and regardless of the order in which the two sources are emitted. A resource that exposes them as separate keys rather than as one value is not applying a precedence. It is deferring the choice to whoever reads the manifest, and the reader is not always the same.
_Avoid_: global annotation, default annotation, annotation merge

**Environment source**:
One of the blocks from which a container receives environment variables in bulk, as opposed to a single variable declared by name. A container's sources are ordered and the last one wins on a shared key, so the order is a domain rule, not a rendering detail. The Deployment and the jobs that come with it do not order them by the same criterion, and the difference is intended. The Deployment orders **by type**: first every non-secret source, then every secret one, so that a secret always beats a plaintext configuration. A job orders **by proximity**: first what it receives from the Deployment, then what it declares itself, so that the nearest declarer wins. The two criteria cannot be reconciled because they do not count the same levels: the job has one more, its own, and ordering it by type would make it lose to a source that is not its own. The difference shows only on a key present in both a secret and a non-secret source: elsewhere the two orders give the same environment.
_Avoid_: envFrom inheritance, env precedence, environment merge

**Rewritten Secret**:
A Secret whose data an ExternalSecret reduces to its own, deleting everything it did not write. It does so on every refresh, whether it owns the Secret or not. What counts is what the ExternalSecret does to the data, not who owns the Secret. A rewritten Secret cannot also be a Secret the chart renders: the two writers erase each other on every upgrade and every refresh, and neither notices. An ExternalSecret that adds its own keys and leaves the others in place does not rewrite the Secret, so it can write into a chart Secret.
_Avoid_: owned target, adopted Secret, ownership conflict

**Passthrough surface**:
A values node that the chart hands to a manifest as is, whose shape belongs to Kubernetes or to an operator and not to the chart. It is not fully opaque: the chart can read some of its fields for its own rules, and those fields are the chart's. It declares them and answers for them like any other value. The rest is not the chart's: only the owner of the shape knows what to expect there, and the shape changes at its owner's pace, not the chart's.
_Avoid_: free field, raw section, blob, pass-through (with the hyphen)

**Backstop guard**:
A chart check that rejects a value the schema already rejects, and that therefore never fires under normal conditions. It is not dead code: when the installer skips schema validation (the way out foreseen for when Kubernetes adds a field before the chart knows it), it is the only protection left, and its message is the only one the user sees. A backstop guard is worth as much as its test: if no test makes it fire, nobody knows whether it still works. A guard that could never fire even without the schema, because the condition is excluded elsewhere in the chart, is dead code instead.
_Avoid_: dead guard, redundant guard, duplicate check

**Values author**:
Whoever writes a release's values without knowing the chart's internal rules, typically assisted by an LLM. The chart guides them only through what it rejects and what it describes: an error that does not name the path, or a field without a description, does not exist for them. A field where the chart accepts anything is, for them, the place to move what is rejected elsewhere.
_Avoid_: user, consumer, developer (when whoever writes the values is meant)
