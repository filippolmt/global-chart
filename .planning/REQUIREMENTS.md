# Requirements: Global Chart — Quality Audit & Hardening

**Defined:** 2026-03-15
**Core Value:** Ogni configurazione valida produce manifest Kubernetes corretti e sicuri; ogni configurazione invalida fallisce in modo chiaro al momento del rendering

## v1 Requirements

Requirements for the quality audit and hardening milestone. Each maps to roadmap phases.

### Template Logic & Correctness

- [ ] **TMPL-01**: Audit di tutti i `default` calls per verificare che non mascherino valori falsy (false, 0, "", [])
- [ ] **TMPL-02**: Fix CronJob ServiceAccount inheritance per allinearla al comportamento dei Hooks
- [ ] **TMPL-03**: Verifica truncation guards su tutti i nomi risorse (63 chars standard, 52 chars CronJobs)
- [ ] **TMPL-04**: Estrazione helper condiviso per inheritance logic eliminando duplicazione hook.yaml/cronjob.yaml

### Test Coverage

- [ ] **TEST-01**: Test di regressione per ogni bug fixato durante l'audit
- [ ] **TEST-02**: Negative tests per tutti i path `fail` (PDB, NetworkPolicy, Ingress, volumes, images)
- [ ] **TEST-03**: Seven-category test pattern per ogni risorsa (default, enabled, disabled, inheritance, override, explicit-empty, failure)
- [ ] **TEST-04**: Boundary tests per truncation limits (nomi a 63 e 52 chars)

### Kubernetes Best Practices

- [ ] **K8S-01**: Generare `values.schema.json` per validazione input Helm
- [ ] **K8S-02**: Security context defaults non-vuoti conformi a Pod Security Standards Restricted
- [ ] **K8S-03**: Supporto ExternalSecret multi-key (più chiavi per singola risorsa)
- [ ] **K8S-04**: `automountServiceAccountToken: false` come default sicuro per tutti i pod

### CI Pipeline

- [ ] **CI-01**: Aggiungere kubeconform alla CI pipeline per validazione manifest Kubernetes
- [ ] **CI-02**: Promuovere kube-linter a gate obbligatorio nella CI pipeline
- [ ] **CI-03**: Aggiungere Trivy scan advisory per vulnerabilità security sui manifest
- [ ] **CI-04**: Implementare matrix testing su multiple versioni Kubernetes

## v2 Requirements

Deferred to future release. Tracked but not in current roadmap.

### Refactoring

- **REF-01**: Rimozione legacy volume `.type` format (breaking change)
- **REF-02**: Fix RBAC positional naming (breaking change)

### Advanced Features

- **ADV-01**: Conftest/OPA policy integration
- **ADV-02**: CHANGELOG automation
- **ADV-03**: Helm 4 compatibility verification

## Out of Scope

| Feature | Reason |
|---------|--------|
| Riscrittura architetturale | Il chart è maturo, si tratta di hardening non di redesign |
| Migrazione a Helm SDK/altri tool | Il team usa Helm v3 con Go templates |
| Supporto multi-cluster/GitOps | Il chart è agnostico rispetto al deployment method |
| Chart-testing (ct) integration | Richiede cluster reale, fuori scope per questo milestone |
| CRD management nel chart | Best practice Helm: CRD installati separatamente |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| TMPL-01 | TBD | Pending |
| TMPL-02 | TBD | Pending |
| TMPL-03 | TBD | Pending |
| TMPL-04 | TBD | Pending |
| TEST-01 | TBD | Pending |
| TEST-02 | TBD | Pending |
| TEST-03 | TBD | Pending |
| TEST-04 | TBD | Pending |
| K8S-01 | TBD | Pending |
| K8S-02 | TBD | Pending |
| K8S-03 | TBD | Pending |
| K8S-04 | TBD | Pending |
| CI-01 | TBD | Pending |
| CI-02 | TBD | Pending |
| CI-03 | TBD | Pending |
| CI-04 | TBD | Pending |

**Coverage:**
- v1 requirements: 16 total
- Mapped to phases: 0
- Unmapped: 16 ⚠️

---
*Requirements defined: 2026-03-15*
*Last updated: 2026-03-15 after initial definition*
