# Global Chart — Quality Audit & Enhancement

## What This Is

Un Helm chart riutilizzabile che fornisce building block Kubernetes configurabili: Deployments, Services, Ingress, CronJobs, Hook Jobs, ExternalSecrets e RBAC. Supporta multi-deployment (più deployment indipendenti in un singolo release). Usato internamente dal team su GKE (K8s 1.29+). Versione corrente: 1.3.0.

## Core Value

Il chart deve generare manifesti Kubernetes corretti e prevedibili in ogni scenario di configurazione — zero sorprese in produzione.

## Requirements

### Validated

<!-- Shipped and confirmed valuable. -->

- ✓ Multi-deployment con risorse indipendenti per deployment — existing
- ✓ Hook/CronJob inheritance da parent deployment (image, configMap, secret, SA, envFrom, nodeSelector, tolerations, affinity, podSecurityContext, securityContext, dnsConfig, imagePullSecrets, hostAliases) — existing
- ✓ Root-level hooks/cronJobs con fromDeployment — existing
- ✓ Mounted ConfigMap (files + bundles) — existing
- ✓ ExternalSecret CRD support — existing
- ✓ RBAC (Roles, RoleBindings) — existing
- ✓ HPA, PDB, NetworkPolicy per deployment — existing
- ✓ Global imageRegistry con smart registry detection — existing
- ✓ Volume rendering (native K8s spec + legacy format) — existing
- ✓ Fail-fast validation con `fail`/`required` — existing
- ✓ helm-unittest suite (220+ test, 16 suite) — existing

### Active

<!-- Current scope: audit, bug fix, deduplication, enhancement -->

**Bug Fixes**
- [ ] Fix falsy masking su `successfulJobsHistoryLimit`/`failedJobsHistoryLimit` (0 → 2)
- [ ] Fix falsy masking su root-level CronJob `automountServiceAccountToken` (false → true)
- [ ] Ingress: validare `service.enabled: false` su deployment referenziato
- [ ] Hook prerequisite Secret/ConfigMap per pre-upgrade ordering

**Deduplication & Best Practices**
- [ ] Estrarre shared helper `inheritedJobPodSpec` per eliminare duplicazione hook/cronjob
- [ ] Audit completo hasKey vs default su tutti i campi booleani/zero-value
- [ ] Verificare naming convention e troncamento consistente

**Test Coverage**
- [ ] Negative tests per tutti i 30 `fail`/`required` paths (23 mancanti)
- [ ] Seven-category inheritance tests per CronJob, Hook, Deployment

**New Features (suggerimenti)**
- [ ] Hook prerequisite resources (Secret/ConfigMap come hook con weight basso)
- [ ] Probe configuration per deployment (liveness, readiness, startup)
- [ ] Init containers support per deployment
- [ ] Sidecar containers support
- [ ] TopologySpreadConstraints defaults da global values
- [ ] Graceful shutdown (preStop hook + terminationGracePeriodSeconds)

### Out of Scope

- Supporto multi-cluster — complessità eccessiva per un chart generico
- Istio/service mesh annotations — troppo vendor-specific
- CRD management — non è responsabilità di un application chart
- Supporto K8s < 1.29 — non necessario per l'ambiente target (GKE)

## Context

- **Ambiente target:** GKE con K8s 1.29+
- **Utenti:** team interno, deployment via CI/CD (GitHub Actions)
- **Phase 01 completata:** template logic audit e bug fixes (troncamento, hasKey patterns)
- **Phase 02 iniziata:** ricerca e contesto per test coverage hardening sono pronti
- **Lavoro in corso:** fix hook prerequisite Secret/ConfigMap (branch main, commit 252f48b) con errore YAML da risolvere
- **Codebase map:** disponibile in `.planning/codebase/` con 7 documenti strutturati

## Constraints

- **Helm compatibility:** Chart deve funzionare con Helm 3.x
- **helm-unittest:** Test via Docker, nessun plugin locale necessario
- **Backward compatibility:** Evitare breaking changes nei values esistenti
- **No GSD traces in git:** L'utente non vuole tracce GSD nei commit/git history

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| hasKey + ternary per booleani | `default` maschera false/0, hasKey distingue "non impostato" da "impostato vuoto" | ✓ Good |
| Hook-specific Secret/ConfigMap (-hook suffix) | Evita conflitti tra hook resources e regular resources | — Pending |
| Fail-fast validation in templates | Errori a render-time invece che a runtime in cluster | ✓ Good |
| 52 char limit per CronJob names | K8s aggiunge 11 char suffix per Job da CronJob | ✓ Good |

---
*Last updated: 2026-03-17 after initialization*
