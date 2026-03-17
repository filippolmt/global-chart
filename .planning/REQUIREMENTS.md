# Requirements: Global Chart Quality Audit & Enhancement

**Defined:** 2026-03-17
**Core Value:** Il chart deve generare manifesti Kubernetes corretti e prevedibili in ogni scenario di configurazione

## v1 Requirements

### Bug Fixes

- [ ] **BUG-01**: Fix falsy masking su `successfulJobsHistoryLimit`/`failedJobsHistoryLimit` in cronjob.yaml (0 → 2 bug)
- [ ] **BUG-02**: Fix falsy masking su root-level CronJob `automountServiceAccountToken` (false → true bug)
- [x] **BUG-03**: Audit completo hasKey vs default su tutti i campi booleani/zero-value nel chart
- [x] **BUG-04**: Ingress deve fare fail se referenzia un deployment con `service.enabled: false`
- [ ] **BUG-05**: Hook prerequisite Secret/ConfigMap — generare copie hook-annotate con weight basso per pre-upgrade ordering
- [ ] **BUG-06**: Name collision guard — fail se nomi troncati collidono tra deployment/cronjob/hook diversi

### Test Coverage

- [ ] **TEST-01**: Negative tests per tutti i 30 `fail`/`required` paths (23 mancanti)
- [ ] **TEST-02**: Seven-category inheritance tests per CronJob deployment-level
- [ ] **TEST-03**: Seven-category inheritance tests per Hook deployment-level
- [ ] **TEST-04**: Seven-category inheritance tests per Deployment fields
- [ ] **TEST-05**: Aggiungere kubeconform in CI per validare manifesti generati contro K8s 1.29 schema

### Refactoring

- [ ] **REFAC-01**: Estrarre shared helper `inheritedJobPodSpec` per eliminare duplicazione hook.yaml/cronjob.yaml (~880 linee → ~200)
- [ ] **REFAC-02**: Dividere `_helpers.tpl` in file per dominio (`_image-helpers.tpl`, `_job-helpers.tpl`, `_volume-helpers.tpl`)

### New Features

- [ ] **FEAT-01**: Probe support — liveness, readiness, startup probes configurabili per deployment
- [ ] **FEAT-02**: Init containers — supporto lista init containers per deployment
- [ ] **FEAT-03**: Global common labels e annotations — applicati a tutte le risorse dal values global
- [ ] **FEAT-04**: `values.schema.json` — JSON Schema per validazione input, IDE autocomplete, errori chiari su typo

## v2 Requirements

### Observability

- **OBS-01**: ServiceMonitor/PodMonitor per Prometheus integration (per-deployment)
- **OBS-02**: VPA (VerticalPodAutoscaler) support per deployment

### Advanced Features

- **ADV-01**: Sidecar containers support per deployment
- **ADV-02**: Extra raw manifests escape hatch (`extraObjects` con tpl rendering)
- **ADV-03**: Default security hardening (securityContext defaults, readOnlyRootFilesystem)
- **ADV-04**: Container command/args override semplificato

## Out of Scope

| Feature | Reason |
|---------|--------|
| StatefulSet/DaemonSet support | Complessità eccessiva, cambia natura del chart |
| Istio/service mesh annotations | Troppo vendor-specific |
| CRD management | Non è responsabilità di un application chart |
| Multi-cluster support | Fuori scope per chart generico |
| K8s < 1.29 support | Non necessario per ambiente target GKE |
| Helm library chart conversion | Cambio architetturale troppo invasivo |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| BUG-01 | Phase 1 | Pending |
| BUG-02 | Phase 1 | Pending |
| BUG-03 | Phase 1 | Complete |
| BUG-04 | Phase 1 | Complete |
| BUG-05 | Phase 1 | Pending |
| BUG-06 | Phase 1 | Pending |
| TEST-01 | Phase 2 | Pending |
| TEST-02 | Phase 2 | Pending |
| TEST-03 | Phase 2 | Pending |
| TEST-04 | Phase 2 | Pending |
| TEST-05 | Phase 4 | Pending |
| REFAC-01 | Phase 3 | Pending |
| REFAC-02 | Phase 3 | Pending |
| FEAT-01 | Phase 4 | Pending |
| FEAT-02 | Phase 4 | Pending |
| FEAT-03 | Phase 4 | Pending |
| FEAT-04 | Phase 5 | Pending |

**Coverage:**
- v1 requirements: 17 total
- Mapped to phases: 17
- Unmapped: 0

---
*Requirements defined: 2026-03-17*
*Last updated: 2026-03-17 after roadmap creation*
