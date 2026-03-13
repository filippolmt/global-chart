# Changelog

All notable changes to this chart are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versioning follows [Semantic Versioning](https://semver.org/).

---

## [1.3.0] — 2026-03-13

### Migration guide from 1.2.x

> **This release contains no blocking breaking changes**, but includes behavioral changes that may cause pod restarts or rendering differences. Read carefully before running `helm upgrade`.

#### 1. Expected rolling restart on first upgrade

The upgrade adds new annotations and labels to pod templates, which Kubernetes interprets as a spec change → rolling restart:

| Change | Effect |
|--------|--------|
| Added `checksum/secret` in pod annotations | Deployment pods are recreated on first upgrade |
| Added `app.kubernetes.io/version` label on all resources | Metadata labels change (not selectors, no impact on existing ReplicaSets) |

**Action:** schedule the upgrade during a maintenance window. After the first upgrade, subsequent restarts only happen when configMap/secret/mountedConfigFiles actually change.

#### 2. CronJob/Hook inheritance fix (potential behavior change)

Previous versions had a bug: explicitly setting an empty field (`nodeSelector: {}`, `tolerations: []`, `affinity: {}`, `imagePullSecrets: []`) on a deployment-level CronJob or Hook **did not override** the parent deployment value — it inherited it anyway.

This is now fixed: an explicit empty value **overrides** inheritance.

**Who is affected:** only users who explicitly set empty fields on deployment-level CronJob/Hook while the parent deployment has those fields populated. If you don't use hooks/cronJobs inside deployments, there is no impact.

**Action:** review your values for deployment-level CronJob/Hook. If you relied on the buggy behavior (empty field still inheriting from parent), remove the field to preserve inheritance.

```yaml
# Before (1.2.x) — empty nodeSelector inherited from deployment (bug)
deployments:
  backend:
    nodeSelector:
      disktype: ssd
    cronJobs:
      cleanup:
        nodeSelector: {}  # Bug: inherited disktype: ssd

# After (1.3.0) — empty nodeSelector correctly overrides
deployments:
  backend:
    nodeSelector:
      disktype: ssd
    cronJobs:
      cleanup:
        nodeSelector: {}  # Correct: no nodeSelector
        # To inherit: remove the nodeSelector line entirely
```

#### 3. Default resources for CronJob/Hook are now configurable

Default resources (100m CPU, 128Mi memory) for CronJobs and Hooks are **no longer hardcoded** in templates. They are read from `defaults.resources` in values.yaml.

The default value in values.yaml is identical to the previous hardcoded value, so **no change unless you override `defaults`**. If you override `defaults: {}` without specifying `resources`, CronJobs/Hooks without explicit resources will have no resource requests.

**Action:** none, unless you completely override the `defaults` section.

#### 4. Volumes: native Kubernetes support (no change required)

Volumes now accept both native Kubernetes spec and the legacy `.type` format. The legacy format continues to work without modifications.

```yaml
# Legacy format (still works)
volumes:
  - name: data
    type: emptyDir

# Native format (new, recommended)
volumes:
  - name: data
    emptyDir: {}
  - name: certs
    csi:
      driver: secrets-store.csi.k8s.io
```

**Action:** no migration required. Gradually adopting the native format for new volumes is recommended.

#### 5. Global values (optional, no change required)

New `global` section in values.yaml to share `imageRegistry` and `imagePullSecrets` across all resources. Completely opt-in.

**Action:** none. To centralize registry or pull secrets, add:

```yaml
global:
  imageRegistry: registry.example.com
  imagePullSecrets:
    - name: my-regcred
```

#### Migration checklist

- [ ] Read the points above and verify applicability
- [ ] Verify that deployment-level CronJob/Hook do not depend on the inheritance bug (point 2)
- [ ] Schedule the upgrade during a maintenance window (point 1)
- [ ] Run `helm diff upgrade` to inspect differences before applying
- [ ] Run `helm upgrade`
- [ ] Verify that pods restart correctly

---

### Added

- **PodDisruptionBudget** — new `pdb.yaml` template, enable per deployment with `pdb.enabled: true` and `minAvailable`/`maxUnavailable`
- **NetworkPolicy** — new `networkpolicy.yaml` template, enable per deployment with `networkPolicy.enabled: true` and ingress/egress rules
- **Helm test** — `helm test <release>` verifies connectivity to the first enabled service (`templates/tests/test-connection.yaml`)
- **Deployment strategy** — configurable `strategy` (RollingUpdate/Recreate) per deployment
- **revisionHistoryLimit** — optional field per deployment
- **progressDeadlineSeconds** — optional field per deployment
- **topologySpreadConstraints** — optional field per deployment
- **Global values** — `global.imageRegistry` (shared registry prefix) and `global.imagePullSecrets` (fallback pull secrets)
- **Native volume spec** — volumes now accept native Kubernetes spec directly (hostPath, CSI, downwardAPI, projected, etc.) alongside the legacy `.type` format
- **Configurable default resources** — `defaults.resources` section in values.yaml for CronJob/Hook without explicit resources
- **Secret checksum** — `checksum/secret` annotation in pod template for automatic restart when secrets change
- **Version label** — `app.kubernetes.io/version` added to all labels (deployment, hook, common)
- **hostAliases and dnsConfig for root CronJob** — added for parity with root Hook and deployment-level CronJob
- **dnsConfig for root Hook** — added for parity with deployment-level Hook
- **NOTES.txt** — sections for Hooks, PDB, and NetworkPolicy in post-install output
- **values.yaml documentation** — complete documentation for strategy, revisionHistoryLimit, progressDeadlineSeconds, topologySpreadConstraints, pdb, networkPolicy, native volumes
- **Chart.yaml** — added keywords (pdb, network-policy, hpa, autoscaling) and maintainer URL

### Changed

- **imageString helper** — now accepts a dict with `global` context to support `global.imageRegistry`. Backward compatible with direct invocation
- **imagePullSecrets** — extended fallback chain: deployment/job-level → global.imagePullSecrets (in deployment, cronjob, hook)
- **Default resources CronJob/Hook** — moved from hardcoded in template to `defaults.resources` in values.yaml (same value: 100m CPU, 128Mi memory)
- **renderVolume helper** — new centralized helper for volume rendering, used by deployment, cronjob, and hook
- **HPA validation** — `minReplicas` and `maxReplicas` now use `required()` for a clear error when omitted with HPA enabled

### Fixed

- **CronJob deployment-level inheritance** — `nodeSelector`, `affinity`, `tolerations`, `imagePullSecrets` with explicit empty value now correctly override parent deployment (switched from `if not` to `hasKey`/`ternary`)
- **Hook deployment-level inheritance** — same fix for the same 4 fields
- **Resources null** — the `resources` field is no longer rendered as `resources: null` when not specified in deployment

### Removed

- **Dead ingress code** — removed all `semverCompare` code for Kubernetes <1.19 in `ingress.yaml` (chart already requires `kubeVersion: >=1.19.0-0`)

---

## [1.2.1] — 2026-03-05

### Added

- `enabled` flag support on all templates (deployment, service, serviceaccount, hpa, configmap, secret, mounted-configmap, cronjob, hook, NOTES.txt)

---

## [1.2.0] — 2026-03-04

### Added

- Complete test suite (14 suites, 174 tests)
- Template improvements and Makefile enhancements

---

## [1.1.0] — 2026-02-28

### Changed

- ServiceAccount handling update and version bump

---

## [1.0.0] — 2026-02-15

### Added

- Initial release with multi-deployment support
- Deployment, Service, Ingress, CronJob, Hook, ExternalSecret, RBAC
- Inheritance pattern for deployment-level Hook/CronJob
