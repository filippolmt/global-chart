# Helm Chart Bug Fixes & Improvements

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix 7 confirmed bugs/improvements in the global-chart Helm chart templates.

**Architecture:** Each fix targets a specific template file with a corresponding unit test. Fixes are ordered by severity (critical first). All changes are backward-compatible — no values.yaml schema changes needed.

**Tech Stack:** Helm templates (Go templates), helm-unittest (Docker-based via `make unit-test`), `make lint-chart` for validation.

---

### Task 1: Fix HPA nil pointer dereference (CRITICAL)

**Files:**
- Modify: `charts/global-chart/templates/hpa.yaml:4-6`
- Test: `charts/global-chart/tests/hpa_test.yaml` (create)

**Step 1: Create the test file with failing tests**

Create `charts/global-chart/tests/hpa_test.yaml`:

```yaml
suite: hpa template tests
templates:
  - templates/hpa.yaml
tests:
  # ====== Nil safety: deployment without autoscaling key ======
  - it: should not render HPA when autoscaling is not defined
    set:
      deployments:
        main:
          image: nginx:1.25
    asserts:
      - hasDocuments:
          count: 0

  # ====== Nil safety: autoscaling enabled without metrics ======
  - it: should not render HPA when enabled but no metrics set
    set:
      deployments:
        main:
          image: nginx:1.25
          autoscaling:
            enabled: true
            minReplicas: 2
            maxReplicas: 5
    asserts:
      - hasDocuments:
          count: 0

  # ====== Basic HPA with CPU metric ======
  - it: should render HPA with CPU metric
    set:
      deployments:
        main:
          image: nginx:1.25
          autoscaling:
            enabled: true
            minReplicas: 2
            maxReplicas: 10
            targetCPUUtilizationPercentage: 80
    asserts:
      - isKind:
          of: HorizontalPodAutoscaler
      - equal:
          path: spec.minReplicas
          value: 2
      - equal:
          path: spec.maxReplicas
          value: 10
      - equal:
          path: spec.metrics[0].resource.name
          value: cpu
      - equal:
          path: spec.metrics[0].resource.target.averageUtilization
          value: 80

  # ====== HPA with both CPU and Memory metrics ======
  - it: should render HPA with both CPU and memory metrics
    set:
      deployments:
        main:
          image: nginx:1.25
          autoscaling:
            enabled: true
            minReplicas: 1
            maxReplicas: 5
            targetCPUUtilizationPercentage: 70
            targetMemoryUtilizationPercentage: 85
    asserts:
      - isKind:
          of: HorizontalPodAutoscaler
      - equal:
          path: spec.metrics[0].resource.name
          value: cpu
      - equal:
          path: spec.metrics[1].resource.name
          value: memory
```

**Step 2: Run tests to verify they fail**

Run: `make unit-test`

Expected: The first test (no autoscaling key) will FAIL with a nil pointer error, confirming the bug.

**Step 3: Fix hpa.yaml with nil-safe defaults**

In `charts/global-chart/templates/hpa.yaml`, replace lines 4-6:

```
{{- $hpa := $deploy.autoscaling }}
{{- $cpu := int $hpa.targetCPUUtilizationPercentage }}
{{- $mem := int $hpa.targetMemoryUtilizationPercentage }}
```

With:

```
{{- $hpa := default (dict) $deploy.autoscaling }}
{{- $cpu := int (default 0 $hpa.targetCPUUtilizationPercentage) }}
{{- $mem := int (default 0 $hpa.targetMemoryUtilizationPercentage) }}
```

**Step 4: Run tests to verify they pass**

Run: `make unit-test`

Expected: All HPA tests PASS. All existing tests still PASS.

**Step 5: Commit**

```bash
git add charts/global-chart/templates/hpa.yaml charts/global-chart/tests/hpa_test.yaml
git commit -m "fix(hpa): nil pointer dereference when autoscaling not defined"
```

---

### Task 2: Fix missing hostAliases inheritance in deployment-level CronJobs (HIGH)

**Files:**
- Modify: `charts/global-chart/templates/cronjob.yaml:267-282` (Part 2, after imagePullSecrets)
- Test: `charts/global-chart/tests/cronjob_test.yaml` (append)

**Step 1: Add failing test to cronjob_test.yaml**

Append to `charts/global-chart/tests/cronjob_test.yaml`:

```yaml
  # ====== Deployment-level CronJob hostAliases inheritance ======
  - it: should inherit hostAliases from deployment in deployment-level cronjob
    set:
      deployments:
        backend:
          image: myapp:v1
          hostAliases:
            - ip: "127.0.0.1"
              hostnames:
                - "foo.local"
                - "bar.local"
          cronJobs:
            cleanup:
              schedule: "0 4 * * *"
              command: ["./cleanup.sh"]
    asserts:
      - isKind:
          of: CronJob
        documentIndex: 0
      - equal:
          path: spec.jobTemplate.spec.template.spec.hostAliases[0].ip
          value: "127.0.0.1"
        documentIndex: 0
      - equal:
          path: spec.jobTemplate.spec.template.spec.hostAliases[0].hostnames[0]
          value: "foo.local"
        documentIndex: 0

  - it: should allow cronjob to override inherited hostAliases
    set:
      deployments:
        backend:
          image: myapp:v1
          hostAliases:
            - ip: "127.0.0.1"
              hostnames:
                - "foo.local"
          cronJobs:
            cleanup:
              schedule: "0 4 * * *"
              command: ["./cleanup.sh"]
              hostAliases:
                - ip: "10.0.0.1"
                  hostnames:
                    - "custom.local"
    asserts:
      - equal:
          path: spec.jobTemplate.spec.template.spec.hostAliases[0].ip
          value: "10.0.0.1"
        documentIndex: 0
```

**Step 2: Run tests to verify they fail**

Run: `make unit-test`

Expected: FAIL — hostAliases path not found in rendered CronJob.

**Step 3: Add hostAliases inheritance to cronjob.yaml Part 2**

In `charts/global-chart/templates/cronjob.yaml`, after the imagePullSecrets block (after line 282, before `initContainers`), add:

```
          {{- /* HostAliases: explicit > inherited from deployment */ -}}
          {{- $hostAliases := $job.hostAliases -}}
          {{- if not $hostAliases -}}
            {{- $hostAliases = $deploy.hostAliases -}}
          {{- end -}}
          {{- with $hostAliases }}
          hostAliases:
            {{- toYaml . | nindent 12 }}
          {{- end }}
```

**Step 4: Run tests to verify they pass**

Run: `make unit-test`

Expected: All tests PASS.

**Step 5: Commit**

```bash
git add charts/global-chart/templates/cronjob.yaml charts/global-chart/tests/cronjob_test.yaml
git commit -m "fix(cronjob): add missing hostAliases inheritance from deployment"
```

---

### Task 3: Fix ingress annotations mutation and nil safety (MEDIUM)

**Files:**
- Modify: `charts/global-chart/templates/ingress.yaml:3-11`
- Test: `charts/global-chart/tests/ingress_test.yaml` (append)

**Step 1: Add failing test to ingress_test.yaml**

Append to `charts/global-chart/tests/ingress_test.yaml`:

```yaml
  # ====== Ingress annotations nil safety ======
  - it: should render ingress without annotations defined
    set:
      deployments:
        main:
          image: nginx:1.25
          service:
            port: 80
      ingress:
        enabled: true
        className: nginx
        hosts:
          - host: example.com
            deployment: main
            paths:
              - path: /
                pathType: Prefix
    asserts:
      - isKind:
          of: Ingress
```

**Step 2: Run tests to verify they fail**

Run: `make unit-test`

Expected: Likely PASS (annotations defaults to `{}`), but the mutation issue is a correctness problem. Continue to step 3.

**Step 3: Fix ingress.yaml to avoid value mutation**

In `charts/global-chart/templates/ingress.yaml`, replace lines 3-11:

```
{{- $ing := $root.Values.ingress }}
{{- $fullName := include "global-chart.fullname" $root }}

{{- /* ingressClass compatibility for K8s <1.18 */}}
{{- if and $ing.className (not (semverCompare ">=1.18-0" $root.Capabilities.KubeVersion.GitVersion)) }}
  {{- if not (hasKey $ing.annotations "kubernetes.io/ingress.class") }}
    {{- $_ := set $ing.annotations "kubernetes.io/ingress.class" $ing.className }}
  {{- end }}
{{- end }}
```

With:

```
{{- $ing := $root.Values.ingress }}
{{- $fullName := include "global-chart.fullname" $root }}
{{- $annotations := default (dict) (deepCopy $ing.annotations) }}

{{- /* ingressClass compatibility for K8s <1.18 */}}
{{- if and $ing.className (not (semverCompare ">=1.18-0" $root.Capabilities.KubeVersion.GitVersion)) }}
  {{- if not (hasKey $annotations "kubernetes.io/ingress.class") }}
    {{- $_ := set $annotations "kubernetes.io/ingress.class" $ing.className }}
  {{- end }}
{{- end }}
```

Then also update the annotations reference later in the template — find where `$ing.annotations` is used for rendering and replace with `$annotations`. Search for `{{- with $ing.annotations }}` or `toYaml $ing.annotations` and replace with `$annotations`.

**Step 4: Run tests to verify they pass**

Run: `make unit-test && make lint-chart`

Expected: All tests PASS, all linting PASS.

**Step 5: Commit**

```bash
git add charts/global-chart/templates/ingress.yaml charts/global-chart/tests/ingress_test.yaml
git commit -m "fix(ingress): avoid mutating input values and add nil safety for annotations"
```

---

### Task 4: Add podSecurityContext and securityContext to CronJob and Hook templates (MEDIUM)

**Files:**
- Modify: `charts/global-chart/templates/cronjob.yaml` (root-level ~line 68 and deployment-level ~line 267)
- Modify: `charts/global-chart/templates/hook.yaml` (root-level ~line 88 and deployment-level ~line 302)
- Test: `charts/global-chart/tests/cronjob_test.yaml` (append)

**Step 1: Add failing tests**

Append to `charts/global-chart/tests/cronjob_test.yaml`:

```yaml
  # ====== Root-level CronJob securityContext ======
  - it: should render podSecurityContext on root-level cronjob
    set:
      deployments:
        main:
          image: nginx:1.25
      cronJobs:
        backup:
          schedule: "0 2 * * *"
          fromDeployment: main
          command: ["echo", "backup"]
          podSecurityContext:
            runAsUser: 1000
            fsGroup: 2000
    asserts:
      - equal:
          path: spec.jobTemplate.spec.template.spec.securityContext.runAsUser
          value: 1000
        documentIndex: 0

  - it: should render container securityContext on root-level cronjob
    set:
      deployments:
        main:
          image: nginx:1.25
      cronJobs:
        backup:
          schedule: "0 2 * * *"
          fromDeployment: main
          command: ["echo", "backup"]
          securityContext:
            runAsNonRoot: true
            readOnlyRootFilesystem: true
    asserts:
      - equal:
          path: spec.jobTemplate.spec.template.spec.containers[0].securityContext.runAsNonRoot
          value: true
        documentIndex: 0

  # ====== Deployment-level CronJob securityContext inheritance ======
  - it: should inherit podSecurityContext from deployment in deployment-level cronjob
    set:
      deployments:
        backend:
          image: myapp:v1
          podSecurityContext:
            runAsUser: 1000
            fsGroup: 2000
          cronJobs:
            cleanup:
              schedule: "0 4 * * *"
              command: ["./cleanup.sh"]
    asserts:
      - equal:
          path: spec.jobTemplate.spec.template.spec.securityContext.runAsUser
          value: 1000
        documentIndex: 0
```

**Step 2: Run tests to verify they fail**

Run: `make unit-test`

Expected: FAIL — securityContext paths not found.

**Step 3: Add securityContext support to cronjob.yaml**

**Root-level cronjob (Part 1):** After imagePullSecrets block (~line 78), before initContainers, add:

```
          {{- with $job.podSecurityContext }}
          securityContext:
            {{- toYaml . | nindent 12 }}
          {{- end }}
```

And in the container spec, after args block (~line 94), before envFrom, add:

```
            {{- with $job.securityContext }}
            securityContext:
              {{- toYaml . | nindent 14 }}
            {{- end }}
```

**Deployment-level cronjob (Part 2):** After hostAliases (added in Task 2), before initContainers, add:

```
          {{- /* PodSecurityContext: explicit > inherited from deployment */ -}}
          {{- $podSecCtx := $job.podSecurityContext -}}
          {{- if not $podSecCtx -}}
            {{- $podSecCtx = $deploy.podSecurityContext -}}
          {{- end -}}
          {{- with $podSecCtx }}
          securityContext:
            {{- toYaml . | nindent 12 }}
          {{- end }}
```

And in the container spec, after args, before envFrom, add:

```
            {{- /* Container securityContext: explicit > inherited from deployment */ -}}
            {{- $secCtx := $job.securityContext -}}
            {{- if not $secCtx -}}
              {{- $secCtx = $deploy.securityContext -}}
            {{- end -}}
            {{- with $secCtx }}
            securityContext:
              {{- toYaml . | nindent 14 }}
            {{- end }}
```

**Step 4: Apply same pattern to hook.yaml**

**Root-level hooks:** After hostAliases (~line 103), before restartPolicy, add pod securityContext. In the container, after args (~line 116), add container securityContext.

**Deployment-level hooks:** After hostAliases (~line 327), add inherited pod securityContext. In the container, after args (~line 340), add inherited container securityContext.

Follow the same explicit > inherited pattern as cronjob.yaml deployment-level.

**Step 5: Run tests to verify they pass**

Run: `make unit-test && make lint-chart`

Expected: All tests PASS.

**Step 6: Commit**

```bash
git add charts/global-chart/templates/cronjob.yaml charts/global-chart/templates/hook.yaml charts/global-chart/tests/cronjob_test.yaml
git commit -m "feat(security): add podSecurityContext and securityContext to cronjob and hook templates"
```

---

### Task 5: Add dnsConfig inheritance to deployment-level CronJobs (LOW)

**Files:**
- Modify: `charts/global-chart/templates/cronjob.yaml` (Part 2, after securityContext from Task 4)
- Test: `charts/global-chart/tests/cronjob_test.yaml` (append)

**Step 1: Add failing test**

Append to `charts/global-chart/tests/cronjob_test.yaml`:

```yaml
  # ====== Deployment-level CronJob dnsConfig inheritance ======
  - it: should inherit dnsConfig from deployment in deployment-level cronjob
    set:
      deployments:
        backend:
          image: myapp:v1
          dnsConfig:
            nameservers:
              - "8.8.8.8"
            searches:
              - "svc.cluster.local"
          cronJobs:
            cleanup:
              schedule: "0 4 * * *"
              command: ["./cleanup.sh"]
    asserts:
      - equal:
          path: spec.jobTemplate.spec.template.spec.dnsConfig.nameservers[0]
          value: "8.8.8.8"
        documentIndex: 0
```

**Step 2: Run tests to verify they fail**

Run: `make unit-test`

Expected: FAIL — dnsConfig path not found.

**Step 3: Add dnsConfig inheritance to cronjob.yaml Part 2**

After the podSecurityContext block (added in Task 4), add:

```
          {{- /* DnsConfig: explicit > inherited from deployment */ -}}
          {{- $dnsConfig := default (dict) $job.dnsConfig -}}
          {{- if not (or $dnsConfig.nameservers $dnsConfig.searches $dnsConfig.options) -}}
            {{- $dnsConfig = default (dict) $deploy.dnsConfig -}}
          {{- end -}}
          {{- if or $dnsConfig.nameservers $dnsConfig.searches $dnsConfig.options }}
          dnsConfig:
            {{- if $dnsConfig.nameservers }}
            nameservers:
              {{- range $dnsConfig.nameservers }}
              - {{ . }}
              {{- end }}
            {{- end }}
            {{- if $dnsConfig.searches }}
            searches:
              {{- range $dnsConfig.searches }}
              - {{ . }}
              {{- end }}
            {{- end }}
            {{- if $dnsConfig.options }}
            options:
              {{- range $dnsConfig.options }}
              - name: {{ .name }}
                {{- if .value }}
                value: {{ .value | quote }}
                {{- end }}
              {{- end }}
            {{- end }}
          {{- end }}
```

**Step 4: Run tests to verify they pass**

Run: `make unit-test && make lint-chart`

Expected: All tests PASS.

**Step 5: Commit**

```bash
git add charts/global-chart/templates/cronjob.yaml charts/global-chart/tests/cronjob_test.yaml
git commit -m "feat(cronjob): add dnsConfig inheritance from deployment"
```

---

### Task 6: Fix RBAC automountServiceAccountToken inconsistency (LOW)

**Files:**
- Modify: `charts/global-chart/templates/rbac.yaml:30-32`
- Test: `charts/global-chart/tests/rbac_test.yaml` (create)

**Step 1: Create test file with failing test**

Create `charts/global-chart/tests/rbac_test.yaml`:

```yaml
suite: rbac template tests
templates:
  - templates/rbac.yaml
tests:
  - it: should default automountServiceAccountToken to true when automount not specified
    set:
      rbacs:
        roles:
          - name: test-role
            serviceAccount:
              create: true
              name: test-sa
            rules:
              - apiGroups: [""]
                resources: ["pods"]
                verbs: ["get"]
    asserts:
      - equal:
          path: automountServiceAccountToken
          value: true
        documentIndex: 0

  - it: should respect automount=false when explicitly set
    set:
      rbacs:
        roles:
          - name: test-role
            serviceAccount:
              create: true
              name: test-sa
              automount: false
            rules:
              - apiGroups: [""]
                resources: ["pods"]
                verbs: ["get"]
    asserts:
      - equal:
          path: automountServiceAccountToken
          value: false
        documentIndex: 0
```

**Step 2: Run tests to verify they fail**

Run: `make unit-test`

Expected: First test FAIL — automountServiceAccountToken not rendered when automount key absent.

**Step 3: Fix rbac.yaml to always render with default**

In `charts/global-chart/templates/rbac.yaml`, replace lines 30-32:

```
{{- if hasKey $sa "automount" }}
automountServiceAccountToken: {{ $sa.automount }}
{{- end }}
```

With:

```
automountServiceAccountToken: {{ hasKey $sa "automount" | ternary $sa.automount true }}
```

**Step 4: Run tests to verify they pass**

Run: `make unit-test && make lint-chart`

Expected: All tests PASS.

**Step 5: Commit**

```bash
git add charts/global-chart/templates/rbac.yaml charts/global-chart/tests/rbac_test.yaml
git commit -m "fix(rbac): default automountServiceAccountToken to true for consistency"
```

---

### Task 7: Final validation and lint

**Step 1: Run full test suite**

Run: `make all`

Expected: All lint scenarios pass, all unit tests pass, all templates generate cleanly.

**Step 2: Run kube-linter if available**

Run: `make kube-linter`

Expected: No new violations from our changes.

**Step 3: Verify test count increased**

Run: `make unit-test 2>&1 | tail -5`

Expected: Test count should be higher than the previous 53 tests (we added ~10+ new tests).

**Step 4: Commit any remaining changes**

If CLAUDE.md or docs need updating:

```bash
git add -A
git commit -m "docs: update test count and document security context support"
```
