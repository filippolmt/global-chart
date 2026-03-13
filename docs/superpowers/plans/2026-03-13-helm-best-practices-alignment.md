# Helm Best Practices Alignment — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Align global-chart to Helm best practices: fix inheritance bugs, remove dead code, add missing standard features (PDB, strategy, topology, NetworkPolicy, helm test), add standard labels, improve resource handling.

**Architecture:** The chart is a multi-deployment Helm chart at `charts/global-chart/`. Templates iterate over a `deployments` map. Each deployment generates its own Deployment, Service, ConfigMap, Secret, ServiceAccount, HPA. Hooks and CronJobs can be root-level or inside deployments (with inheritance). Tests use helm-unittest via Docker (`make unit-test`). Linting uses `make lint-chart`.

**Tech Stack:** Helm 3, Go templates, helm-unittest, Docker, Make

**Baseline:** 14 suites, 174 tests, all green. `kubeVersion: ">=1.19.0-0"`.

**Validation after every task:**
```bash
make lint-chart && make unit-test
```

---

## File Map

| Action | File | Responsibility |
|--------|------|---------------|
| Modify | `charts/global-chart/templates/cronjob.yaml` | Fix inheritance for nodeSelector, affinity, tolerations, imagePullSecrets |
| Modify | `charts/global-chart/templates/hook.yaml` | Same inheritance fix |
| Modify | `charts/global-chart/templates/ingress.yaml` | Remove K8s <1.19 dead code |
| Modify | `charts/global-chart/templates/deployment.yaml` | Add strategy, revisionHistoryLimit, topologySpreadConstraints, fix resources null, add secret checksum |
| Modify | `charts/global-chart/templates/_helpers.tpl` | Add `app.kubernetes.io/version` to labels |
| Modify | `charts/global-chart/values.yaml` | Add new fields: strategy, pdb, topologySpreadConstraints, revisionHistoryLimit, global, default resources |
| Create | `charts/global-chart/templates/pdb.yaml` | PodDisruptionBudget per deployment |
| Create | `charts/global-chart/templates/tests/test-connection.yaml` | helm test pod |
| Modify | `charts/global-chart/templates/NOTES.txt` | Show helm test instructions |
| Modify | `charts/global-chart/Chart.yaml` | Bump version, add maintainer email |
| Modify | `CLAUDE.md` | Update test count, architecture docs |
| Modify | `charts/global-chart/tests/cronjob_test.yaml` | Tests for inheritance fix |
| Modify | `charts/global-chart/tests/hook_test.yaml` | Tests for inheritance fix |
| Modify | `charts/global-chart/tests/ingress_test.yaml` | Tests for simplified apiVersion |
| Modify | `charts/global-chart/tests/deployment_test.yaml` | Tests for strategy, revisionHistoryLimit, topologySpreadConstraints, resources, secret checksum |
| Create | `charts/global-chart/tests/pdb_test.yaml` | Tests for PDB |
| Modify | `charts/global-chart/tests/helpers_test.yaml` | Tests for version label |
| Modify | `charts/global-chart/tests/notes_test.yaml` | Test for helm test instruction |

---

## Chunk 1: Bug Fixes

### Task 1: Fix inheritance pattern in cronjob.yaml (nodeSelector, affinity, tolerations, imagePullSecrets)

**Files:**
- Modify: `charts/global-chart/templates/cronjob.yaml:278-281,440-465`
- Test: `charts/global-chart/tests/cronjob_test.yaml`

**Context:** In deployment-level cronJobs, `nodeSelector`, `affinity`, `tolerations` and `imagePullSecrets` use `if not $var` to check for inheritance. This treats `{}` and `[]` as falsy, so an explicit empty override (to clear the parent's value) is ignored. Must switch to `hasKey`/`ternary` pattern, consistent with hostAliases, podSecurityContext, securityContext which already use it correctly.

- [ ] **Step 1: Write failing tests for empty-override inheritance**

Add tests in `cronjob_test.yaml` that set `nodeSelector: {}`, `affinity: {}`, `tolerations: []`, `imagePullSecrets: []` on a deployment-level cronjob whose parent deployment defines non-empty values. Assert the cronjob renders the empty value (not the parent's).

```yaml
  - it: should allow cronjob to override nodeSelector with empty map
    set:
      deployments:
        backend:
          image: "myapp:v1"
          nodeSelector:
            disktype: ssd
          cronJobs:
            cleanup:
              schedule: "0 2 * * *"
              command: ["./cleanup.sh"]
              nodeSelector: {}
    asserts:
      - template: cronjob.yaml
        documentSelector:
          path: metadata.name
          value: RELEASE-NAME-global-chart-backend-cleanup
        notExists:
          path: spec.jobTemplate.spec.template.spec.nodeSelector

  - it: should allow cronjob to override tolerations with empty list
    set:
      deployments:
        backend:
          image: "myapp:v1"
          tolerations:
            - key: "dedicated"
              operator: "Equal"
              value: "backend"
              effect: "NoSchedule"
          cronJobs:
            cleanup:
              schedule: "0 2 * * *"
              command: ["./cleanup.sh"]
              tolerations: []
    asserts:
      - template: cronjob.yaml
        documentSelector:
          path: metadata.name
          value: RELEASE-NAME-global-chart-backend-cleanup
        notExists:
          path: spec.jobTemplate.spec.template.spec.tolerations

  - it: should allow cronjob to override affinity with empty map
    set:
      deployments:
        backend:
          image: "myapp:v1"
          affinity:
            nodeAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                nodeSelectorTerms:
                  - matchExpressions:
                      - key: zone
                        operator: In
                        values: ["us-east-1a"]
          cronJobs:
            cleanup:
              schedule: "0 2 * * *"
              command: ["./cleanup.sh"]
              affinity: {}
    asserts:
      - template: cronjob.yaml
        documentSelector:
          path: metadata.name
          value: RELEASE-NAME-global-chart-backend-cleanup
        notExists:
          path: spec.jobTemplate.spec.template.spec.affinity

  - it: should allow cronjob to override imagePullSecrets with empty list
    set:
      deployments:
        backend:
          image: "myapp:v1"
          imagePullSecrets:
            - name: regcred
          cronJobs:
            cleanup:
              schedule: "0 2 * * *"
              command: ["./cleanup.sh"]
              imagePullSecrets: []
    asserts:
      - template: cronjob.yaml
        documentSelector:
          path: metadata.name
          value: RELEASE-NAME-global-chart-backend-cleanup
        notExists:
          path: spec.jobTemplate.spec.template.spec.imagePullSecrets
```

- [ ] **Step 2: Run tests — verify they FAIL**

```bash
make unit-test
```

Expected: The 4 new tests fail because `{}` and `[]` are treated as falsy, inheriting from parent.

- [ ] **Step 3: Fix cronjob.yaml — replace `if not` with `hasKey`/`ternary`**

Replace lines for imagePullSecrets (around line 278-281):
```yaml
# BEFORE:
{{- $imagePullSecrets := $job.imagePullSecrets -}}
{{- if not $imagePullSecrets -}}
  {{- $imagePullSecrets = $deploy.imagePullSecrets -}}
{{- end -}}

# AFTER:
{{- $imagePullSecrets := ternary $job.imagePullSecrets $deploy.imagePullSecrets (hasKey $job "imagePullSecrets") -}}
```

Replace lines for nodeSelector (around line 440-443):
```yaml
# BEFORE:
{{- $nodeSelector := $job.nodeSelector -}}
{{- if not $nodeSelector -}}
  {{- $nodeSelector = $deploy.nodeSelector -}}
{{- end -}}

# AFTER:
{{- $nodeSelector := ternary $job.nodeSelector $deploy.nodeSelector (hasKey $job "nodeSelector") -}}
```

Replace lines for affinity (around line 449-452):
```yaml
# BEFORE:
{{- $affinity := $job.affinity -}}
{{- if not $affinity -}}
  {{- $affinity = $deploy.affinity -}}
{{- end -}}

# AFTER:
{{- $affinity := ternary $job.affinity $deploy.affinity (hasKey $job "affinity") -}}
```

Replace lines for tolerations (around line 458-461):
```yaml
# BEFORE:
{{- $tolerations := $job.tolerations -}}
{{- if not $tolerations -}}
  {{- $tolerations = $deploy.tolerations -}}
{{- end -}}

# AFTER:
{{- $tolerations := ternary $job.tolerations $deploy.tolerations (hasKey $job "tolerations") -}}
```

- [ ] **Step 4: Run tests — verify they PASS**

```bash
make lint-chart && make unit-test
```

Expected: All 178+ tests pass.


---

### Task 2: Fix same inheritance pattern in hook.yaml

**Files:**
- Modify: `charts/global-chart/templates/hook.yaml:313-316,440-465`
- Test: `charts/global-chart/tests/hook_test.yaml`

**Context:** Exact same bug as Task 1 but in hook.yaml deployment-level section. Same 4 fields: `imagePullSecrets`, `nodeSelector`, `affinity`, `tolerations`.

- [ ] **Step 1: Write failing tests for empty-override inheritance in hooks**

Add 4 tests in `hook_test.yaml` (same pattern as Task 1 but for hooks):

```yaml
  - it: should allow hook to override nodeSelector with empty map
    set:
      deployments:
        backend:
          image: "myapp:v1"
          nodeSelector:
            disktype: ssd
          hooks:
            post-upgrade:
              migrate:
                command: ["./migrate.sh"]
                nodeSelector: {}
    asserts:
      - template: hook.yaml
        documentSelector:
          path: kind
          value: Job
        notExists:
          path: spec.template.spec.nodeSelector

  - it: should allow hook to override tolerations with empty list
    set:
      deployments:
        backend:
          image: "myapp:v1"
          tolerations:
            - key: "dedicated"
              operator: "Equal"
              value: "backend"
              effect: "NoSchedule"
          hooks:
            post-upgrade:
              migrate:
                command: ["./migrate.sh"]
                tolerations: []
    asserts:
      - template: hook.yaml
        documentSelector:
          path: kind
          value: Job
        notExists:
          path: spec.template.spec.tolerations

  - it: should allow hook to override affinity with empty map
    set:
      deployments:
        backend:
          image: "myapp:v1"
          affinity:
            nodeAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                nodeSelectorTerms:
                  - matchExpressions:
                      - key: zone
                        operator: In
                        values: ["us-east-1a"]
          hooks:
            post-upgrade:
              migrate:
                command: ["./migrate.sh"]
                affinity: {}
    asserts:
      - template: hook.yaml
        documentSelector:
          path: kind
          value: Job
        notExists:
          path: spec.template.spec.affinity

  - it: should allow hook to override imagePullSecrets with empty list
    set:
      deployments:
        backend:
          image: "myapp:v1"
          imagePullSecrets:
            - name: regcred
          hooks:
            post-upgrade:
              migrate:
                command: ["./migrate.sh"]
                imagePullSecrets: []
    asserts:
      - template: hook.yaml
        documentSelector:
          path: kind
          value: Job
        notExists:
          path: spec.template.spec.imagePullSecrets
```

- [ ] **Step 2: Run tests — verify they FAIL**

```bash
make unit-test
```

- [ ] **Step 3: Fix hook.yaml — same `hasKey`/`ternary` replacements**

Replace imagePullSecrets (around line 313-316):
```yaml
# AFTER:
{{- $imagePullSecrets := ternary $command.imagePullSecrets $deploy.imagePullSecrets (hasKey $command "imagePullSecrets") -}}
```

Replace nodeSelector (around line 440-443):
```yaml
# AFTER:
{{- $nodeSelector := ternary $command.nodeSelector $deploy.nodeSelector (hasKey $command "nodeSelector") -}}
```

Replace affinity (around line 449-452):
```yaml
# AFTER:
{{- $affinity := ternary $command.affinity $deploy.affinity (hasKey $command "affinity") -}}
```

Replace tolerations (around line 458-461):
```yaml
# AFTER:
{{- $tolerations := ternary $command.tolerations $deploy.tolerations (hasKey $command "tolerations") -}}
```

- [ ] **Step 4: Run tests — verify they PASS**

```bash
make lint-chart && make unit-test
```


---

### Task 3: Fix deployment resources rendering null

**Files:**
- Modify: `charts/global-chart/templates/deployment.yaml:119-120`
- Test: `charts/global-chart/tests/deployment_test.yaml`

**Context:** When `resources` is not defined, `toYaml $deploy.resources` renders `null`, producing `resources: null` in the manifest. This triggers kube-linter warnings and is not intentional. Wrap with `{{- if $deploy.resources }}`.

- [ ] **Step 1: Write failing test**

Add test in `deployment_test.yaml`:

```yaml
  - it: should not render resources key when not specified
    set:
      deployments:
        main:
          image: "nginx:1.25"
    asserts:
      - template: deployment.yaml
        notExists:
          path: spec.template.spec.containers[0].resources
```

- [ ] **Step 2: Run test — verify it FAILS**

```bash
make unit-test
```

Expected: Fails because `resources: null` is rendered.

- [ ] **Step 3: Fix deployment.yaml**

Replace lines 119-120:
```yaml
# BEFORE:
          resources:
            {{- toYaml $deploy.resources | nindent 12 }}

# AFTER:
          {{- with $deploy.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
```

- [ ] **Step 4: Run tests — verify they PASS**

```bash
make lint-chart && make unit-test
```


---

### Task 4: Add secret checksum to pod annotations

**Files:**
- Modify: `charts/global-chart/templates/deployment.yaml:28-29`
- Test: `charts/global-chart/tests/deployment_test.yaml`

**Context:** ConfigMap and mountedConfigFiles have checksums in pod annotations, but secret does not. A secret change won't trigger pod restart without this.

- [ ] **Step 1: Write failing test**

```yaml
  - it: should include secret checksum in pod annotations
    set:
      deployments:
        main:
          image: "nginx:1.25"
          secret:
            DB_PASSWORD: "s3cret"
    asserts:
      - template: deployment.yaml
        exists:
          path: spec.template.metadata.annotations.checksum/secret
```

- [ ] **Step 2: Run test — verify it FAILS**

```bash
make unit-test
```

- [ ] **Step 3: Add secret checksum annotation**

In `deployment.yaml`, after line 29 (`checksum/mounted-config-files:`), add:

```yaml
        checksum/secret: {{ toYaml $deploy.secret | sha256sum }}
```

- [ ] **Step 4: Run tests — verify they PASS**

```bash
make lint-chart && make unit-test
```


---

## Chunk 2: Cleanup & Standard Labels

### Task 5: Remove dead K8s <1.19 code from ingress.yaml

**Files:**
- Modify: `charts/global-chart/templates/ingress.yaml:7-21,79-91`
- Test: `charts/global-chart/tests/ingress_test.yaml`

**Context:** `Chart.yaml` declares `kubeVersion: ">=1.19.0-0"` but the ingress template has dead branches for `extensions/v1beta1` and `networking.k8s.io/v1beta1`. Also has unnecessary `semverCompare` checks for `pathType` and `ingressClassName`. Remove all of this.

- [ ] **Step 1: Write test asserting clean apiVersion**

```yaml
  - it: should always use networking.k8s.io/v1 apiVersion
    set:
      deployments:
        main:
          image: "nginx:1.25"
      ingress:
        enabled: true
        hosts:
          - host: example.com
            deployment: main
            paths:
              - path: /
                pathType: Prefix
    asserts:
      - template: ingress.yaml
        equal:
          path: apiVersion
          value: networking.k8s.io/v1
```

- [ ] **Step 2: Run test — verify it PASSES (sanity check, since we're on K8s 1.19+)**

```bash
make unit-test
```

- [ ] **Step 3: Simplify ingress.yaml**

Remove the `semverCompare` blocks and hardcode:
- `apiVersion: networking.k8s.io/v1` directly
- `ingressClassName` directly (no semver check)
- `pathType` directly (no semver check)
- `backend.service.name/port.number` directly (no v1beta1 fallback)
- Remove the `kubernetes.io/ingress.class` annotation compatibility block

Simplified template top:
```yaml
{{- if .Values.ingress.enabled }}
{{- $root := . }}
{{- $ing := $root.Values.ingress }}
{{- $fullName := include "global-chart.fullname" $root }}
{{- $annotations := deepCopy (default (dict) $ing.annotations) }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ $fullName }}
  labels:
    {{- include "global-chart.labels" $root | nindent 4 }}
  {{- with $annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- if $ing.className }}
  ingressClassName: {{ $ing.className | quote }}
  {{- end }}
```

Simplified backend:
```yaml
            backend:
              service:
                name: {{ $svcName }}
                port:
                  number: {{ $svcPort }}
```

Simplified pathType (always render):
```yaml
          - path: {{ $path.path }}
            pathType: {{ $path.pathType | default "ImplementationSpecific" }}
```

- [ ] **Step 4: Run tests — verify they PASS**

```bash
make lint-chart && make unit-test
```


---

### Task 6: Add `app.kubernetes.io/version` label

**Files:**
- Modify: `charts/global-chart/templates/_helpers.tpl:36-40,75-79`
- Test: `charts/global-chart/tests/helpers_test.yaml`

**Context:** Standard Kubernetes recommended label `app.kubernetes.io/version` is missing from both `global-chart.labels` and `global-chart.deploymentLabels`.

- [ ] **Step 1: Write failing test**

```yaml
  - it: should include version label in common labels
    set:
      deployments:
        main:
          image: "nginx:1.25"
    asserts:
      - template: deployment.yaml
        equal:
          path: metadata.labels["app.kubernetes.io/version"]
          value: "1.2.1"
```

- [ ] **Step 2: Run test — verify it FAILS**

```bash
make unit-test
```

- [ ] **Step 3: Add version label to both helpers**

In `_helpers.tpl`, modify `global-chart.labels` (around line 38):
```yaml
{{- define "global-chart.labels" -}}
helm.sh/chart: {{ include "global-chart.chart" . }}
{{ include "global-chart.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
```

Modify `global-chart.deploymentLabels` (around line 76):
```yaml
{{- define "global-chart.deploymentLabels" -}}
helm.sh/chart: {{ include "global-chart.chart" .root }}
{{ include "global-chart.deploymentSelectorLabels" . }}
app.kubernetes.io/version: {{ .root.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- end }}
```

- [ ] **Step 4: Run tests — verify they PASS**

```bash
make lint-chart && make unit-test
```

Note: Some existing snapshot/assertion tests may need adjustment for the new label.


---

### Task 7: Update Chart.yaml maintainer info

**Files:**
- Modify: `charts/global-chart/Chart.yaml:32-33`

- [ ] **Step 1: Add email and url to maintainer**

```yaml
maintainers:
  - name: Filippo Merante Caparrotta
    email: filippo.merante@example.com
    url: https://github.com/filippolmt
```

Note: Replace email with actual preferred email.

- [ ] **Step 2: Run lint — verify passes**

```bash
make lint-chart
```


---

## Chunk 3: New Features — Deployment Enhancements

### Task 8: Add configurable `strategy` to Deployment

**Files:**
- Modify: `charts/global-chart/templates/deployment.yaml`
- Modify: `charts/global-chart/values.yaml`
- Test: `charts/global-chart/tests/deployment_test.yaml`

**Context:** Deployment strategy (RollingUpdate vs Recreate) is not configurable. Add optional `strategy` field to each deployment.

- [ ] **Step 1: Write failing tests**

```yaml
  - it: should render strategy when configured
    set:
      deployments:
        main:
          image: "nginx:1.25"
          strategy:
            type: RollingUpdate
            rollingUpdate:
              maxSurge: 1
              maxUnavailable: 0
    asserts:
      - template: deployment.yaml
        equal:
          path: spec.strategy.type
          value: RollingUpdate
        equal:
          path: spec.strategy.rollingUpdate.maxSurge
          value: 1

  - it: should not render strategy when not configured
    set:
      deployments:
        main:
          image: "nginx:1.25"
    asserts:
      - template: deployment.yaml
        notExists:
          path: spec.strategy
```

- [ ] **Step 2: Run tests — verify they FAIL**

```bash
make unit-test
```

- [ ] **Step 3: Add strategy to deployment.yaml**

After `replicas` block (around line 21), add:

```yaml
  {{- with $deploy.strategy }}
  strategy:
    {{- toYaml . | nindent 4 }}
  {{- end }}
```

- [ ] **Step 4: Add to values.yaml comments**

Add in the commented deployment example:
```yaml
  #   # -- Deployment strategy configuration
  #   strategy:
  #     type: RollingUpdate
  #     rollingUpdate:
  #       maxSurge: 1
  #       maxUnavailable: 0
```

- [ ] **Step 5: Run tests — verify they PASS**

```bash
make lint-chart && make unit-test
```


---

### Task 9: Add configurable `revisionHistoryLimit`

**Files:**
- Modify: `charts/global-chart/templates/deployment.yaml`
- Modify: `charts/global-chart/values.yaml`
- Test: `charts/global-chart/tests/deployment_test.yaml`

- [ ] **Step 1: Write failing test**

```yaml
  - it: should render revisionHistoryLimit when configured
    set:
      deployments:
        main:
          image: "nginx:1.25"
          revisionHistoryLimit: 3
    asserts:
      - template: deployment.yaml
        equal:
          path: spec.revisionHistoryLimit
          value: 3

  - it: should not render revisionHistoryLimit when not configured
    set:
      deployments:
        main:
          image: "nginx:1.25"
    asserts:
      - template: deployment.yaml
        notExists:
          path: spec.revisionHistoryLimit
```

- [ ] **Step 2: Run tests — verify they FAIL**

- [ ] **Step 3: Add to deployment.yaml**

After strategy block, add:

```yaml
  {{- if hasKey $deploy "revisionHistoryLimit" }}
  revisionHistoryLimit: {{ $deploy.revisionHistoryLimit }}
  {{- end }}
```

- [ ] **Step 4: Add to values.yaml comments**

```yaml
  #   # -- (int) Number of old ReplicaSets to retain for rollback (K8s default: 10)
  #   revisionHistoryLimit: 3
```

- [ ] **Step 5: Run tests — verify they PASS**

```bash
make lint-chart && make unit-test
```


---

### Task 10: Add `topologySpreadConstraints` support

**Files:**
- Modify: `charts/global-chart/templates/deployment.yaml`
- Modify: `charts/global-chart/values.yaml`
- Test: `charts/global-chart/tests/deployment_test.yaml`

- [ ] **Step 1: Write failing test**

```yaml
  - it: should render topologySpreadConstraints when configured
    set:
      deployments:
        main:
          image: "nginx:1.25"
          topologySpreadConstraints:
            - maxSkew: 1
              topologyKey: topology.kubernetes.io/zone
              whenUnsatisfiable: DoNotSchedule
              labelSelector:
                matchLabels:
                  app: web
    asserts:
      - template: deployment.yaml
        equal:
          path: spec.template.spec.topologySpreadConstraints[0].maxSkew
          value: 1
        equal:
          path: spec.template.spec.topologySpreadConstraints[0].topologyKey
          value: topology.kubernetes.io/zone
```

- [ ] **Step 2: Run tests — verify they FAIL**

- [ ] **Step 3: Add to deployment.yaml**

After `tolerations` block (around line 226), add:

```yaml
      {{- with $deploy.topologySpreadConstraints }}
      topologySpreadConstraints:
        {{- toYaml . | nindent 8 }}
      {{- end }}
```

- [ ] **Step 4: Add to values.yaml comments**

```yaml
  #   # -- Pod topology spread constraints for zone-aware scheduling
  #   topologySpreadConstraints: []
```

- [ ] **Step 5: Run tests — verify they PASS**

```bash
make lint-chart && make unit-test
```


---

## Chunk 4: New Templates (PDB, Helm Test)

### Task 11: Create PodDisruptionBudget template

**Files:**
- Create: `charts/global-chart/templates/pdb.yaml`
- Modify: `charts/global-chart/values.yaml`
- Create: `charts/global-chart/tests/pdb_test.yaml`

- [ ] **Step 1: Write test file `pdb_test.yaml`**

```yaml
suite: pdb template tests
templates:
  - templates/pdb.yaml
values:
  - ../tests/test01/values.01.yaml
tests:
  - it: should not render PDB by default
    asserts:
      - hasDocuments:
          count: 0

  - it: should render PDB with minAvailable
    set:
      deployments:
        main:
          image: "nginx:1.25"
          pdb:
            enabled: true
            minAvailable: 1
    asserts:
      - hasDocuments:
          count: 1
      - equal:
          path: apiVersion
          value: policy/v1
      - equal:
          path: kind
          value: PodDisruptionBudget
      - equal:
          path: spec.minAvailable
          value: 1
      - notExists:
          path: spec.maxUnavailable

  - it: should render PDB with maxUnavailable
    set:
      deployments:
        main:
          image: "nginx:1.25"
          pdb:
            enabled: true
            maxUnavailable: 1
    asserts:
      - hasDocuments:
          count: 1
      - equal:
          path: spec.maxUnavailable
          value: 1
      - notExists:
          path: spec.minAvailable

  - it: should not render PDB when enabled is false
    set:
      deployments:
        main:
          image: "nginx:1.25"
          pdb:
            enabled: false
            minAvailable: 1
    asserts:
      - hasDocuments:
          count: 0

  - it: should use correct selector labels
    set:
      deployments:
        main:
          image: "nginx:1.25"
          pdb:
            enabled: true
            minAvailable: 1
    asserts:
      - equal:
          path: spec.selector.matchLabels["app.kubernetes.io/component"]
          value: main

  - it: should render PDB for multiple deployments
    set:
      deployments:
        frontend:
          image: "nginx:1.25"
          pdb:
            enabled: true
            minAvailable: 1
        backend:
          image: "myapp:v1"
          pdb:
            enabled: true
            maxUnavailable: "25%"
    asserts:
      - hasDocuments:
          count: 2

  - it: should not render PDB for disabled deployment
    set:
      deployments:
        main:
          enabled: false
          image: "nginx:1.25"
          pdb:
            enabled: true
            minAvailable: 1
    asserts:
      - hasDocuments:
          count: 0
```

- [ ] **Step 2: Run tests — verify they FAIL**

```bash
make unit-test
```

- [ ] **Step 3: Create `pdb.yaml` template**

```yaml
{{- $root := . }}
{{- range $name, $deploy := .Values.deployments }}
{{- if $deploy }}
{{- if eq (include "global-chart.deploymentEnabled" (dict "deploy" $deploy)) "true" }}
{{- $pdb := default (dict) $deploy.pdb }}
{{- if $pdb.enabled }}
{{- $depFullname := include "global-chart.deploymentFullname" (dict "root" $root "deploymentName" $name) }}
{{- $labelCtx := dict "root" $root "deploymentName" $name }}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ $depFullname }}
  labels:
    {{- include "global-chart.deploymentLabels" $labelCtx | nindent 4 }}
spec:
  {{- if $pdb.minAvailable }}
  minAvailable: {{ $pdb.minAvailable }}
  {{- end }}
  {{- if $pdb.maxUnavailable }}
  maxUnavailable: {{ $pdb.maxUnavailable }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "global-chart.deploymentSelectorLabels" $labelCtx | nindent 6 }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
```

- [ ] **Step 4: Add to values.yaml comments**

```yaml
  #   # -- PodDisruptionBudget configuration
  #   pdb:
  #     enabled: false
  #     # -- Minimum number of pods that must remain available
  #     minAvailable: 1
  #     # -- Maximum number of pods that can be unavailable (alternative to minAvailable)
  #     # maxUnavailable: 1
```

- [ ] **Step 5: Run tests — verify they PASS**

```bash
make lint-chart && make unit-test
```


---

### Task 12: Create helm test pod

**Files:**
- Create: `charts/global-chart/templates/tests/test-connection.yaml`
- Modify: `charts/global-chart/templates/NOTES.txt`
- Test: `charts/global-chart/tests/notes_test.yaml`

**Context:** Helm recommends a test pod for `helm test`. This creates a pod that wget's the first enabled service. The `.helmignore` already excludes `tests/` (unit tests dir), but `templates/tests/` is NOT excluded since it's inside `templates/`.

- [ ] **Step 1: Create `test-connection.yaml`**

```yaml
{{- $root := . }}
{{- $firstSvc := "" }}
{{- $firstPort := 80 }}
{{- range $name, $deploy := .Values.deployments }}
{{- if and $deploy (not $firstSvc) }}
{{- if eq (include "global-chart.deploymentEnabled" (dict "deploy" $deploy)) "true" }}
{{- $svc := default (dict) $deploy.service }}
{{- $svcEnabled := ternary $svc.enabled true (hasKey $svc "enabled") }}
{{- if $svcEnabled }}
{{- $firstSvc = include "global-chart.deploymentFullname" (dict "root" $root "deploymentName" $name) }}
{{- $firstPort = default 80 $svc.port }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- if $firstSvc }}
apiVersion: v1
kind: Pod
metadata:
  name: "{{ include "global-chart.fullname" $root }}-test-connection"
  labels:
    {{- include "global-chart.labels" $root | nindent 4 }}
  annotations:
    "helm.sh/hook": test
spec:
  containers:
    - name: wget
      image: busybox:1.36
      command: ['wget']
      args: ['{{ $firstSvc }}:{{ $firstPort }}', '--timeout=5', '-O', '/dev/null']
  restartPolicy: Never
{{- end }}
```

- [ ] **Step 2: Add `helm test` instruction to NOTES.txt**

At the end of NOTES.txt, before the last line, add:

```
Run 'helm test {{ .Release.Name }}' to verify connectivity.
```

- [ ] **Step 3: Run tests — verify they PASS**

```bash
make lint-chart && make unit-test
```


---

## Chunk 5: progressDeadlineSeconds & NetworkPolicy

### Task 13: Add configurable `progressDeadlineSeconds`

**Files:**
- Modify: `charts/global-chart/templates/deployment.yaml`
- Modify: `charts/global-chart/values.yaml`
- Test: `charts/global-chart/tests/deployment_test.yaml`

**Context:** `progressDeadlineSeconds` controls how long Kubernetes waits for a deployment to progress before marking it as failed. Default is 600s (10min). Making it configurable lets teams set tighter SLOs for rollouts.

- [ ] **Step 1: Write failing tests**

```yaml
  - it: should render progressDeadlineSeconds when configured
    set:
      deployments:
        main:
          image: "nginx:1.25"
          progressDeadlineSeconds: 120
    asserts:
      - template: deployment.yaml
        equal:
          path: spec.progressDeadlineSeconds
          value: 120

  - it: should not render progressDeadlineSeconds when not configured
    set:
      deployments:
        main:
          image: "nginx:1.25"
    asserts:
      - template: deployment.yaml
        notExists:
          path: spec.progressDeadlineSeconds
```

- [ ] **Step 2: Run tests — verify they FAIL**

```bash
make unit-test
```

- [ ] **Step 3: Add to deployment.yaml**

After `revisionHistoryLimit` block, add:

```yaml
  {{- if hasKey $deploy "progressDeadlineSeconds" }}
  progressDeadlineSeconds: {{ $deploy.progressDeadlineSeconds }}
  {{- end }}
```

- [ ] **Step 4: Add to values.yaml comments**

```yaml
  #   # -- (int) Seconds before deployment is considered failed (K8s default: 600)
  #   progressDeadlineSeconds: 120
```

- [ ] **Step 5: Run tests — verify they PASS**

```bash
make lint-chart && make unit-test
```


---

### Task 14: Create NetworkPolicy template

**Files:**
- Create: `charts/global-chart/templates/networkpolicy.yaml`
- Modify: `charts/global-chart/values.yaml`
- Create: `charts/global-chart/tests/networkpolicy_test.yaml`

**Context:** NetworkPolicy is a security best practice for limiting pod traffic. Create a per-deployment optional NetworkPolicy that allows ingress from specified sources and egress to specified destinations.

- [ ] **Step 1: Write test file `networkpolicy_test.yaml`**

```yaml
suite: networkpolicy template tests
templates:
  - templates/networkpolicy.yaml
tests:
  - it: should not render NetworkPolicy by default
    set:
      deployments:
        main:
          image: "nginx:1.25"
    asserts:
      - hasDocuments:
          count: 0

  - it: should render NetworkPolicy when enabled
    set:
      deployments:
        main:
          image: "nginx:1.25"
          networkPolicy:
            enabled: true
    asserts:
      - hasDocuments:
          count: 1
      - equal:
          path: apiVersion
          value: networking.k8s.io/v1
      - equal:
          path: kind
          value: NetworkPolicy

  - it: should use correct pod selector labels
    set:
      deployments:
        main:
          image: "nginx:1.25"
          networkPolicy:
            enabled: true
    asserts:
      - equal:
          path: spec.podSelector.matchLabels["app.kubernetes.io/component"]
          value: main

  - it: should render ingress rules when specified
    set:
      deployments:
        main:
          image: "nginx:1.25"
          service:
            port: 8080
          networkPolicy:
            enabled: true
            ingress:
              - from:
                  - namespaceSelector:
                      matchLabels:
                        name: ingress-nginx
                ports:
                  - port: 8080
                    protocol: TCP
    asserts:
      - equal:
          path: spec.ingress[0].from[0].namespaceSelector.matchLabels.name
          value: ingress-nginx
      - equal:
          path: spec.ingress[0].ports[0].port
          value: 8080

  - it: should render egress rules when specified
    set:
      deployments:
        main:
          image: "nginx:1.25"
          networkPolicy:
            enabled: true
            egress:
              - to:
                  - ipBlock:
                      cidr: 10.0.0.0/8
                ports:
                  - port: 5432
                    protocol: TCP
    asserts:
      - equal:
          path: spec.egress[0].to[0].ipBlock.cidr
          value: 10.0.0.0/8

  - it: should render policyTypes based on rules
    set:
      deployments:
        main:
          image: "nginx:1.25"
          networkPolicy:
            enabled: true
            ingress:
              - from:
                  - podSelector: {}
            egress:
              - to:
                  - podSelector: {}
    asserts:
      - contains:
          path: spec.policyTypes
          content: Ingress
      - contains:
          path: spec.policyTypes
          content: Egress

  - it: should not render NetworkPolicy when enabled is false
    set:
      deployments:
        main:
          image: "nginx:1.25"
          networkPolicy:
            enabled: false
    asserts:
      - hasDocuments:
          count: 0

  - it: should not render NetworkPolicy for disabled deployment
    set:
      deployments:
        main:
          enabled: false
          image: "nginx:1.25"
          networkPolicy:
            enabled: true
    asserts:
      - hasDocuments:
          count: 0

  - it: should render NetworkPolicy for multiple deployments
    set:
      deployments:
        frontend:
          image: "nginx:1.25"
          networkPolicy:
            enabled: true
        backend:
          image: "myapp:v1"
          networkPolicy:
            enabled: true
    asserts:
      - hasDocuments:
          count: 2
```

- [ ] **Step 2: Run tests — verify they FAIL**

```bash
make unit-test
```

- [ ] **Step 3: Create `networkpolicy.yaml` template**

```yaml
{{- $root := . }}
{{- range $name, $deploy := .Values.deployments }}
{{- if $deploy }}
{{- if eq (include "global-chart.deploymentEnabled" (dict "deploy" $deploy)) "true" }}
{{- $np := default (dict) $deploy.networkPolicy }}
{{- if $np.enabled }}
{{- $depFullname := include "global-chart.deploymentFullname" (dict "root" $root "deploymentName" $name) }}
{{- $labelCtx := dict "root" $root "deploymentName" $name }}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ $depFullname }}
  labels:
    {{- include "global-chart.deploymentLabels" $labelCtx | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      {{- include "global-chart.deploymentSelectorLabels" $labelCtx | nindent 6 }}
  policyTypes:
    {{- if $np.ingress }}
    - Ingress
    {{- end }}
    {{- if $np.egress }}
    - Egress
    {{- end }}
  {{- with $np.ingress }}
  ingress:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $np.egress }}
  egress:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
```

- [ ] **Step 4: Add to values.yaml comments**

```yaml
  #   # -- NetworkPolicy configuration for traffic control
  #   networkPolicy:
  #     enabled: false
  #     # -- Ingress rules (list of rules allowing inbound traffic)
  #     ingress:
  #       - from:
  #           - namespaceSelector:
  #               matchLabels:
  #                 name: ingress-nginx
  #         ports:
  #           - port: 8080
  #             protocol: TCP
  #     # -- Egress rules (list of rules allowing outbound traffic)
  #     egress:
  #       - to:
  #           - ipBlock:
  #               cidr: 10.0.0.0/8
  #         ports:
  #           - port: 5432
  #             protocol: TCP
```

- [ ] **Step 5: Run tests — verify they PASS**

```bash
make lint-chart && make unit-test
```


---

## Chunk 6: Native Volume Spec Refactor

### Task 15: Refactor volume handling to accept native Kubernetes volume spec

**Files:**
- Modify: `charts/global-chart/templates/deployment.yaml:176-214`
- Modify: `charts/global-chart/templates/cronjob.yaml:131-151,417-437`
- Modify: `charts/global-chart/templates/hook.yaml:153-173,418-437`
- Modify: `charts/global-chart/values.yaml`
- Modify: `charts/global-chart/tests/deployment_test.yaml`
- Modify: `tests/test01/values.01.yaml`
- Modify: `tests/mountedcm1.yaml`
- Modify: `tests/multi-deployment.yaml`
- Modify: `tests/values.02.yaml`

**Context:** Currently volumes use a custom `.type` field (`emptyDir`, `configMap`, `secret`, `persistentVolumeClaim`) that only supports 4 volume types. This locks out `hostPath`, `projected`, `downwardAPI`, `csi`, `nfs`, etc. Refactor to accept native Kubernetes volume spec directly. Keep backward compatibility with the `.type` format during a deprecation period.

**Strategy:** Support both formats:
1. **New (native):** volume objects without `.type` — rendered with `toYaml` as-is
2. **Legacy (custom):** volume objects with `.type` — translated to native format (backward compat)

- [ ] **Step 1: Write failing tests for native volume format**

Add in `deployment_test.yaml`:

```yaml
  - it: should render native volume spec (no .type field)
    set:
      deployments:
        main:
          image: "nginx:1.25"
          volumes:
            - name: data
              hostPath:
                path: /data
                type: DirectoryOrCreate
            - name: downward
              downwardAPI:
                items:
                  - path: labels
                    fieldRef:
                      fieldPath: metadata.labels
          volumeMounts:
            - name: data
              mountPath: /data
            - name: downward
              mountPath: /etc/podinfo
    asserts:
      - template: deployment.yaml
        equal:
          path: spec.template.spec.volumes[0].name
          value: data
        equal:
          path: spec.template.spec.volumes[0].hostPath.path
          value: /data
        equal:
          path: spec.template.spec.volumes[1].name
          value: downward
        exists:
          path: spec.template.spec.volumes[1].downwardAPI

  - it: should still render legacy .type volume spec (backward compat)
    set:
      deployments:
        main:
          image: "nginx:1.25"
          volumes:
            - name: myvolume
              type: secret
              secret:
                secretName: my-secret
            - name: myvolume2
              type: configMap
              configMap:
                name: my-config
          volumeMounts:
            - name: myvolume
              mountPath: /etc/secret
    asserts:
      - template: deployment.yaml
        equal:
          path: spec.template.spec.volumes[0].name
          value: myvolume
        equal:
          path: spec.template.spec.volumes[0].secret.secretName
          value: my-secret
        equal:
          path: spec.template.spec.volumes[1].name
          value: myvolume2
        equal:
          path: spec.template.spec.volumes[1].configMap.name
          value: my-config
```

- [ ] **Step 2: Run tests — verify native format test FAILS**

```bash
make unit-test
```

- [ ] **Step 3: Create helper `global-chart.renderVolume` in `_helpers.tpl`**

This helper detects whether a volume uses the legacy `.type` format or native format and renders accordingly:

```yaml
{{/*
Render a single volume entry. Supports both:
- Legacy format: { name, type, secret/configMap/persistentVolumeClaim/emptyDir }
- Native format: { name, <any-k8s-volume-source> } (no .type field)
*/}}
{{- define "global-chart.renderVolume" -}}
{{- $vol := . -}}
- name: {{ $vol.name }}
{{- if hasKey $vol "type" }}
  {{- /* Legacy format: translate .type to native */ -}}
  {{- if eq $vol.type "emptyDir" }}
  emptyDir: {}
  {{- else if eq $vol.type "configMap" }}
  configMap:
    name: {{ $vol.configMap.name | quote }}
  {{- else if eq $vol.type "secret" }}
  secret:
    secretName: {{ default $vol.secret.secretName $vol.secret.name | quote }}
  {{- else if eq $vol.type "persistentVolumeClaim" }}
  persistentVolumeClaim:
    claimName: {{ default $vol.persistentVolumeClaim.claimName $vol.persistentVolumeClaim.name | quote }}
  {{- end }}
{{- else }}
  {{- /* Native format: render everything except name as-is */ -}}
  {{- range $key, $value := $vol }}
  {{- if ne $key "name" }}
  {{ $key }}:
    {{- toYaml $value | nindent 4 }}
  {{- end }}
  {{- end }}
{{- end }}
{{- end }}
```

- [ ] **Step 4: Refactor deployment.yaml volumes block**

Replace the manual volume rendering (lines 176-213) with the helper:

```yaml
      {{- $userVolumes := default (list) $deploy.volumes }}
      {{- /* ... (keep existing $hasMcfFiles, $hasMcfBundles checks) ... */ -}}
      {{- if or $hasUserVolumes (or $hasMcfFiles $hasMcfBundles) }}
      volumes:
        {{- range $userVolumes }}
        {{- include "global-chart.renderVolume" . | nindent 8 }}
        {{- end }}
        {{- /* ... (keep existing mountedConfigFiles volume logic) ... */ -}}
      {{- end }}
```

- [ ] **Step 5: Refactor cronjob.yaml volumes blocks (both root-level and deployment-level)**

Replace both volume rendering blocks (around lines 131-151 and 417-437) with:

```yaml
          {{- with $job.volumes }}
          volumes:
            {{- range . }}
            {{- include "global-chart.renderVolume" . | nindent 12 }}
            {{- end }}
          {{- end }}
```

- [ ] **Step 6: Refactor hook.yaml volumes blocks (both root-level and deployment-level)**

Replace both volume rendering blocks (around lines 153-173 and 418-437) with:

```yaml
      {{- with $command.volumes }}
      volumes:
        {{- range . }}
        {{- include "global-chart.renderVolume" . | nindent 8 }}
        {{- end }}
      {{- end }}
```

- [ ] **Step 7: Update values.yaml comments**

Show both formats in the documentation:

```yaml
  #   # -- Pod volumes (supports native K8s spec or legacy .type format)
  #   volumes:
  #     # Native format (recommended):
  #     - name: data
  #       hostPath:
  #         path: /data
  #     - name: cache
  #       emptyDir: {}
  #     - name: certs
  #       csi:
  #         driver: secrets-store.csi.k8s.io
  #         readOnly: true
  #     # Legacy format (backward compatible):
  #     - name: myvolume
  #       type: secret
  #       secret:
  #         secretName: my-secret
```

- [ ] **Step 8: Run tests — verify ALL pass (both new native + existing legacy)**

```bash
make lint-chart && make unit-test
```

All existing test scenarios using `.type` format must still pass (backward compat).


---

## Chunk 7: Global Values Support

### Task 16: Add `global` values for shared imageRegistry and imagePullSecrets

**Files:**
- Modify: `charts/global-chart/templates/_helpers.tpl`
- Modify: `charts/global-chart/templates/deployment.yaml`
- Modify: `charts/global-chart/templates/cronjob.yaml`
- Modify: `charts/global-chart/templates/hook.yaml`
- Modify: `charts/global-chart/values.yaml`
- Test: `charts/global-chart/tests/deployment_test.yaml`
- Test: `charts/global-chart/tests/cronjob_test.yaml`

**Context:** The skill recommends a `global:` block for `imageRegistry` (shared registry prefix) and `imagePullSecrets` (shared pull secrets). This avoids repeating the same registry/secrets across every deployment and cronjob.

- [ ] **Step 1: Write failing tests for global imageRegistry**

Add in `deployment_test.yaml`:

```yaml
  - it: should prepend global.imageRegistry to image
    set:
      global:
        imageRegistry: registry.example.com
      deployments:
        main:
          image:
            repository: myapp
            tag: "v1"
    asserts:
      - template: deployment.yaml
        equal:
          path: spec.template.spec.containers[0].image
          value: "registry.example.com/myapp:v1"

  - it: should not prepend imageRegistry when not set
    set:
      deployments:
        main:
          image:
            repository: myapp
            tag: "v1"
    asserts:
      - template: deployment.yaml
        equal:
          path: spec.template.spec.containers[0].image
          value: "myapp:v1"

  - it: should use global.imagePullSecrets when deployment has none
    set:
      global:
        imagePullSecrets:
          - name: global-regcred
      deployments:
        main:
          image: "nginx:1.25"
    asserts:
      - template: deployment.yaml
        equal:
          path: spec.template.spec.imagePullSecrets[0].name
          value: global-regcred

  - it: should prefer deployment imagePullSecrets over global
    set:
      global:
        imagePullSecrets:
          - name: global-regcred
      deployments:
        main:
          image: "nginx:1.25"
          imagePullSecrets:
            - name: local-regcred
    asserts:
      - template: deployment.yaml
        equal:
          path: spec.template.spec.imagePullSecrets[0].name
          value: local-regcred
```

- [ ] **Step 2: Run tests — verify they FAIL**

```bash
make unit-test
```

- [ ] **Step 3: Modify `global-chart.imageString` helper in `_helpers.tpl`**

Update to accept an optional global context and prepend `global.imageRegistry`:

```yaml
{{/*
Render an image reference. When global.imageRegistry is set and image is a map,
prepend the registry to the repository.
Usage: {{ include "global-chart.imageString" (dict "image" $deploy.image "global" $.Values.global) }}
  or legacy: {{ include "global-chart.imageString" $deploy.image }}
*/}}
{{- define "global-chart.imageString" -}}
{{- $img := . -}}
{{- $globalRegistry := "" -}}
{{- if kindIs "map" . -}}
  {{- if hasKey . "image" -}}
    {{- /* New dict format */ -}}
    {{- $img = .image -}}
    {{- $global := default (dict) .global -}}
    {{- $globalRegistry = default "" $global.imageRegistry -}}
  {{- end -}}
{{- end -}}
{{- if kindIs "string" $img }}
  {{- $trimmed := $img | trim -}}
  {{- if $trimmed }}
    {{- if and $globalRegistry (not (contains "/" $trimmed | not)) }}
      {{- $trimmed -}}
    {{- else if $globalRegistry }}
      {{- printf "%s/%s" $globalRegistry $trimmed -}}
    {{- else }}
      {{- $trimmed -}}
    {{- end }}
  {{- end }}
{{- else if and (kindIs "map" $img) $img.repository }}
  {{- $repo := $img.repository | trim -}}
  {{- if and $globalRegistry (not (contains "/" $repo)) }}
    {{- $repo = printf "%s/%s" $globalRegistry $repo -}}
  {{- end -}}
  {{- $digest := default "" $img.digest | trim -}}
  {{- $tag := default "" $img.tag | trim -}}
  {{- if $repo }}
    {{- if $digest }}
      {{- printf "%s@%s" $repo $digest -}}
    {{- else if $tag }}
      {{- printf "%s:%s" $repo $tag -}}
    {{- else }}
      {{- $repo -}}
    {{- end }}
  {{- end }}
{{- else if and (kindIs "map" $img) $img.digest }}
  {{- fail "image definitions that set a digest must also provide a repository (expected repository@digest)" -}}
{{- end }}
{{- end }}
```

- [ ] **Step 4: Update all `imageString` call sites in templates**

In `deployment.yaml`, change:
```yaml
# BEFORE:
{{- $depImageRef := include "global-chart.imageString" $deploy.image }}

# AFTER:
{{- $depImageRef := include "global-chart.imageString" (dict "image" $deploy.image "global" $root.Values.global) }}
```

In `cronjob.yaml` (root-level), change:
```yaml
# BEFORE:
{{- $jobImage = include "global-chart.imageString" $job.image -}}
# and:
{{- $jobImage = include "global-chart.imageString" $deploy.image -}}

# AFTER:
{{- $jobImage = include "global-chart.imageString" (dict "image" $job.image "global" $root.Values.global) -}}
# and:
{{- $jobImage = include "global-chart.imageString" (dict "image" $deploy.image "global" $root.Values.global) -}}
```

Same pattern for all `imageString` calls in `cronjob.yaml` (deployment-level) and `hook.yaml` (both sections).

- [ ] **Step 5: Update deployment.yaml for global.imagePullSecrets**

Replace the imagePullSecrets block in deployment.yaml:

```yaml
      {{- /* ImagePullSecrets: deployment-level > global */ -}}
      {{- $imagePullSecrets := $deploy.imagePullSecrets -}}
      {{- if not $imagePullSecrets -}}
        {{- $global := default (dict) $root.Values.global -}}
        {{- $imagePullSecrets = $global.imagePullSecrets -}}
      {{- end -}}
      {{- with $imagePullSecrets }}
      imagePullSecrets:
        {{- range . }}
          {{- if kindIs "string" . }}
        - name: {{ . | quote }}
          {{- else if hasKey . "name" }}
        - name: {{ .name | quote }}
          {{- else }}
          {{ fail "imagePullSecrets must be a list of strings or objects with a 'name' key." }}
          {{- end }}
        {{- end }}
      {{- end }}
```

- [ ] **Step 6: Add global section to values.yaml**

At the top of values.yaml, before `nameOverride`:

```yaml
# -- Global values shared across all deployments
global:
  # -- Global image registry prefix (e.g., registry.example.com)
  # @default -- `""` (no prefix)
  imageRegistry: ""
  # -- Global imagePullSecrets (used when deployment doesn't specify its own)
  # @default -- `[]`
  imagePullSecrets: []
```

- [ ] **Step 7: Add test for global.imagePullSecrets in cronjobs**

Add in `cronjob_test.yaml`:

```yaml
  - it: should use global.imagePullSecrets when cronjob has none
    set:
      global:
        imagePullSecrets:
          - name: global-regcred
      cronJobs:
        cleanup:
          schedule: "0 2 * * *"
          image: "myapp:v1"
          command: ["./cleanup.sh"]
    asserts:
      - template: cronjob.yaml
        equal:
          path: spec.jobTemplate.spec.template.spec.imagePullSecrets[0].name
          value: global-regcred
```

- [ ] **Step 8: Run tests — verify ALL pass**

```bash
make lint-chart && make unit-test
```

Ensure no existing tests break due to the `imageString` helper change (backward compat with plain string arg).


---

## Chunk 8: Finalization

### Task 17: Move CronJob/Hook default resources to values.yaml

**Files:**
- Modify: `charts/global-chart/values.yaml`
- Modify: `charts/global-chart/templates/cronjob.yaml`
- Modify: `charts/global-chart/templates/hook.yaml`

**Context:** Default resources (100m CPU, 128Mi memory) are hardcoded in templates. Move to a `defaults` section in values.yaml for transparency.

- [ ] **Step 1: Add defaults section to values.yaml**

```yaml
# -- Default resource settings for CronJobs and Hooks when not specified
defaults:
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
```

- [ ] **Step 2: Update cronjob.yaml and hook.yaml**

Replace hardcoded defaults (in both root-level and deployment-level sections) with:
```yaml
            {{- if $job.resources }}
            resources:
              {{- toYaml $job.resources | nindent 14 }}
            {{- else if $root.Values.defaults.resources }}
            resources:
              {{- toYaml $root.Values.defaults.resources | nindent 14 }}
            {{- end }}
```

- [ ] **Step 3: Run tests — verify they PASS**

```bash
make lint-chart && make unit-test
```

---

### Task 18: Bump chart version and update documentation

**Files:**
- Modify: `charts/global-chart/Chart.yaml`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Bump Chart.yaml version**

Bump version and appVersion from `1.2.1` to `1.3.0` (minor bump — new features added).

- [ ] **Step 2: Update CLAUDE.md**

- Update version reference to `1.3.0`
- Update test count to reflect new total
- Add PDB, NetworkPolicy, strategy, topologySpreadConstraints, revisionHistoryLimit, progressDeadlineSeconds to architecture docs
- Add `templates/tests/test-connection.yaml`, `templates/pdb.yaml`, `templates/networkpolicy.yaml` to chart structure
- Add `global` values section to schema docs
- Document native volume spec support

- [ ] **Step 3: Regenerate docs**

```bash
make generate-docs
```

- [ ] **Step 4: Run full validation**

```bash
make lint-chart && make unit-test && make generate-templates
```

---

## Summary

| Task | Chunk | Type | Description | Est. Tests Added |
|------|-------|------|-------------|-----------------|
| 1 | 1 | Bug fix | CronJob inheritance (nodeSelector, affinity, tolerations, imagePullSecrets) | +4 |
| 2 | 1 | Bug fix | Hook inheritance (same 4 fields) | +4 |
| 3 | 1 | Bug fix | Deployment resources null rendering | +1 |
| 4 | 1 | Bug fix | Secret checksum in pod annotations | +1 |
| 5 | 2 | Cleanup | Remove dead K8s <1.19 ingress code | +1 |
| 6 | 2 | Labels | Add `app.kubernetes.io/version` | +1 |
| 7 | 2 | Metadata | Chart.yaml maintainer email/url | 0 |
| 8 | 3 | Feature | Deployment strategy configuration | +2 |
| 9 | 3 | Feature | revisionHistoryLimit | +2 |
| 10 | 3 | Feature | topologySpreadConstraints | +1 |
| 11 | 4 | Feature | PodDisruptionBudget template | +7 |
| 12 | 4 | Feature | Helm test connection pod | 0 |
| 13 | 5 | Feature | progressDeadlineSeconds | +2 |
| 14 | 5 | Feature | NetworkPolicy template | +9 |
| 15 | 6 | Refactor | Native Kubernetes volume spec (backward compat) | +2 |
| 16 | 7 | Feature | global.imageRegistry + global.imagePullSecrets | +5 |
| 17 | 8 | Refactor | Default resources to values.yaml | 0 |
| 18 | 8 | Docs | Version bump + documentation | 0 |
| **Total** | | | | **~+42 tests** |

**Expected final state:** ~216 tests, 17 suites (pdb, networkpolicy new), version 1.3.0

**Note:** I commit sono a carico dell'utente — nessun task include step di commit automatico.
