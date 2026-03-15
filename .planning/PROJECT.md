# Global Chart — Quality Audit & Hardening

## What This Is

Audit completo a 360° del global-chart Helm, un chart riutilizzabile che genera risorse Kubernetes (Deployments, Services, Ingress, CronJobs, Hook Jobs, ExternalSecrets, RBAC) con supporto multi-deployment. L'obiettivo è portare il chart a livello enterprise: verificare che sia costruito secondo le best practices, coprire tutti gli edge case con test, e identificare funzionalità mancanti.

## Core Value

Ogni configurazione valida produce manifest Kubernetes corretti e sicuri; ogni configurazione invalida fallisce in modo chiaro al momento del rendering — nessuna sorpresa in produzione.

## Requirements

### Validated

<!-- Shipped and confirmed valuable. -->

- ✓ Multi-deployment fan-out con risorse indipendenti per deployment — existing
- ✓ Hook/CronJob inheritance da deployment parent con hasKey-guarded overrides — existing
- ✓ Global fallback chain per imagePullSecrets e imageRegistry — existing
- ✓ Compile-time fail per configurazioni invalide (PDB, NetworkPolicy, Ingress, volumes) — existing
- ✓ 220 test helm-unittest across 16 suites — existing
- ✓ CI/CD con lint, unit test, manifest generation — existing
- ✓ ServiceAccount default creation con override — existing
- ✓ Volume rendering (native + legacy format) — existing

### Active

<!-- Current scope. Building toward these. -->

- [ ] Template logic audit: verificare nil pointer, hasKey correctness, edge cases in tutti i template
- [ ] Test coverage gap analysis: identificare scenari non testati e aggiungere test
- [ ] Kubernetes best practices audit: security context, resource limits, labels, probes defaults
- [ ] Feature gap analysis: funzionalità che un chart enterprise dovrebbe avere e mancano
- [ ] Fix iterativi per ogni issue trovato, con test di regressione

### Out of Scope

- Riscrittura architetturale del chart — l'obiettivo è migliorare, non rifare da zero
- Migrazione a Helm SDK o altri tool — rimaniamo su Helm v3 con Go templates
- Supporto multi-cluster o GitOps specifico — il chart è agnostico rispetto al deployment method

## Context

- Il chart è alla versione 1.3.0, stabile e usato dal team interno per deployare su Kubernetes
- Codebase map disponibile in `.planning/codebase/` con 7 documenti di analisi
- Precedenti fix da PR #44 hanno già corretto diversi issue (renderResources, HPA minReplicas zero, test-connection, hook comments)
- Il chart supporta: Deployments, Services, Ingress, CronJobs, Hooks, ExternalSecrets, RBAC, HPA, PDB, NetworkPolicy, mounted ConfigMaps
- Testing via Docker (helm-unittest), nessun plugin locale richiesto

## Constraints

- **Tech stack**: Helm v3, Go templates, helm-unittest — nessun cambio di tecnologia
- **Backward compatibility**: Le modifiche non devono rompere le configurazioni esistenti dei consumatori
- **Test framework**: helm-unittest via Docker (`make unit-test`)
- **Naming limits**: 63 chars per risorse standard, 52 chars per CronJobs

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Report prima, fix dopo | L'utente vuole approvare le trovate prima di applicare modifiche | — Pending |
| Audit a 360° (4 dimensioni) | Template logic + test coverage + K8s best practices + feature gaps | — Pending |
| Nessuna riscrittura architetturale | Il chart è maturo, si tratta di hardening non di redesign | — Pending |

---
*Last updated: 2026-03-15 after initialization*
