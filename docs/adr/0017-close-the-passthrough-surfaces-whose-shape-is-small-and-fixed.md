---
status: accepted
---

# Close the passthrough surfaces whose shape is small and fixed

ADR 0006 closed the chart's own definitions. It left one question open: how much
of a Kubernetes or operator shape to admit on a *passthrough surface* (see
`CONTEXT.md`), a values node the chart hands to a manifest verbatim. Issue #180
asks it for four such surfaces: `networkPolicy.ingress` / `egress`, `probe`,
`volumes` and `externalSecrets.<name>.dataFrom[].sourceRef`.

**The criterion: a passthrough surface whose shape is small and fixed is closed
in full. A surface whose shape is large or still growing stays open, and it
declares only the fields a template reads.** The amendment for issue #145
already applied this criterion to `dnsConfigOption`, `tolerations[]` and
`hostAliases[]` ("small, fixed Kubernetes or KEDA shapes"). This ADR writes it
down as the rule.

## Why a criterion, and why this one

A typo on these surfaces can fail in two ways, and the two cost different
amounts.

**A typo accepted.** `livenessProbe.httpGet.prot: 8080` reaches the API server.
Only server-side apply rejects it (`field not declared in schema`). That covers
a fresh `helm install` on Helm 4 and Argo CD with `ServerSideApply=true`. Every
client-side apply path sends no `fieldValidation`, so the server applies `Warn`:
it drops the field, stores the object and returns a warning. The result is a
line on stderr (Helm 3, or a Helm 4 `upgrade --server-side=auto` of a release
that Helm 3 installed) or a line in the controller log (Argo CD by default).
The sync is green, and the probe checks the wrong port. Pruned CRD fields, such
as `sourceRef` on the ESO ExternalSecret, behave the same. On these paths the
schema is the only thing that sees the typo.

**A valid field rejected.** If Kubernetes adds a field that a closed schema does
not list, every consumer who uses it is blocked until a chart release lists it.

Closing a small, fixed shape buys the first protection at almost no risk of the
second. Closing a large or growing shape puts the second risk on every consumer.
Uniform closure fails on `volumes`. Uniform openness gives up protection on
shapes that have not changed in years. Closing only the top level of each
surface (issue option 2) misses the typo that motivated the issue:
`httpGet.prot` is one level down.

## Applied

- **`networkPolicy.ingress` / `egress`: closed.** Rule (`from`/`to`, `ports`),
  peer (`podSelector`, `namespaceSelector`, `ipBlock`), `ipBlock` (`cidr`
  required, `except`), port (`protocol` TCP/UDP/SCTP, `port` integer or string,
  `endPort`). The two selectors share a new `$defs/labelSelector`
  (`matchLabels`, and `matchExpressions[]` with `key`, `operator`
  In/NotIn/Exists/DoesNotExist, `values`). NetworkPolicy v1 is the most stable
  of the four; its last addition was `endPort`, GA in 1.25.
- **`probe`: closed, handler bodies included.** Top level: `exec`, `httpGet`,
  `tcpSocket`, `grpc`, `initialDelaySeconds`, `periodSeconds`,
  `timeoutSeconds`, `successThreshold`, `failureThreshold`,
  `terminationGracePeriodSeconds`. Bodies: `httpGet` (`host`, `path`, `port`
  required, `scheme` HTTP/HTTPS, `httpHeaders[]` with `name`/`value`),
  `tcpSocket` (`host`, `port`), `exec` (`command`), `grpc` (`port`, `service`).
  Kubernetes' rule "exactly one handler" stays with the API server.
- **`dataFrom[].sourceRef`: closed.** `storeRef` (`name`, `kind`) and
  `generatorRef` (`apiVersion`, `kind`, `name`), with no `enum` on the `kind`s.
  ESO adds generator types; it does not add fields to the reference. We close the
  shape, not the vocabulary. The chart already reads both keys to decide whether
  `secretstore` is required.
- **`volumes`: open.** About thirty volume sources, and the list grows (`image`
  arrived in 1.31). Each item declares `name`, required, because the
  externalSecrets volume collision check reads it.
- **`volumeMounts`: open, now in the register.** ADR 0006's register left it
  out. It is small but not fixed: `recursiveReadOnly` arrived in 1.30. Small
  alone is not enough.

**A probe inside `extraContainers` is still open.** That is not a contradiction.
`$defs/container` stays open under issue #148 because a Container is large and
growing. The criterion applies to the surface the value sits on, and that surface
is the Container.

**Fields a template reads are the chart's own.** On a surface left open, every
field a template reads is declared anyway, as `CLAUDE.md` already requires:
`volumes[].name`, `sourceRef.storeRef`, `sourceRef.generatorRef`. That is the
same shape as `container` with `env`: an open node that declares a property.

## Considered options

**Close all four against a hand-written Kubernetes subset (issue option 1).**
Rejected for `volumes`: the subset would fall behind every Kubernetes release.

**Close only the top level of each item (issue option 2).** Rejected: it does
not catch `httpGet.prot`.

**Leave all four open and document them (issue option 3).** Rejected: the
client-side apply paths drop the typo in silence, and three of the four shapes
carry almost no risk of a wrong rejection.

**An escape key in the schema per surface.** Rejected: it reopens the surface
in another place, and the protection is lost for exactly the consumer who did
not notice the typo.

## Consequences

- A consumer blocked by a field that Kubernetes added after we closed the shape
  can run `helm install --skip-schema-validation` (Helm 4, and Helm 3 from
  3.16) until a chart release lists the field. The CHANGELOG names the flag.
- Ships as a minor release with an **Action:** line in the CHANGELOG, as issue
  #145 did in 2.8.0. A values file that is now rejected carried a key that
  Kubernetes was dropping, or a key that does not exist.
- Every new closed node gets its own `# covers:` fixture in
  `tests/bad-values/schema/`, and `check-closure-coverage.py` checks each one
  by mutation (ADR 0006, issues #177, #179).
- A future passthrough surface is decided by this criterion, not by a new
  discussion.
