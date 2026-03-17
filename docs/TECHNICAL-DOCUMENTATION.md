# global-chart — Documentazione Tecnica Completa

**Versione:** 1.3.0
**Kubernetes minimo:** >= 1.19.0
**Data documento:** 2026-03-13

---

## Indice

1. [Sommario Esecutivo](#1-sommario-esecutivo)
2. [Panoramica dell'Architettura](#2-panoramica-dellarchitettura)
3. [Installazione e Quick Start](#3-installazione-e-quick-start)
4. [Riferimento ai Valori](#4-riferimento-ai-valori)
5. [Architettura dei Template](#5-architettura-dei-template)
6. [Il Sistema di Helper](#6-il-sistema-di-helper)
7. [Pattern Multi-Deployment](#7-pattern-multi-deployment)
8. [CronJob e Hook — Posizionamento e Ereditarietà](#8-cronjob-e-hook--posizionamento-e-ereditariet%C3%A0)
9. [Funzionalità Avanzate](#9-funzionalit%C3%A0-avanzate)
10. [Design Pattern e Insidie](#10-design-pattern-e-insidie)
11. [Testing](#11-testing)
12. [CI/CD](#12-cicd)
13. [Contribuire](#13-contribuire)
14. [Changelog e Migrazione](#14-changelog-e-migrazione)
15. [Appendice — Glossario](#15-appendice--glossario)

---

## 1. Sommario Esecutivo

**global-chart** è un Helm chart riutilizzabile progettato per incapsulare i building block più comuni di Kubernetes in un'unica configurazione dichiarativa. Invece di mantenere un chart separato per ogni microservizio, un singolo chart fornisce la struttura necessaria per deployare applicazioni di qualsiasi complessità — da un semplice nginx a uno stack completo frontend/backend/worker con tutti gli accessori.

### Punti chiave

- **Multi-deployment**: una singola release Helm genera più Deployment indipendenti, ciascuno con il proprio Service, ConfigMap, Secret, ServiceAccount, HPA e PDB.
- **Inheritance model**: CronJob e Hook definiti all'interno di un deployment ereditano automaticamente immagine, variabili d'ambiente, ServiceAccount e configurazione di scheduling.
- **Ergonomia delle immagini**: un campo `image` accetta sia una stringa `"nginx:1.25"` sia un oggetto `{repository, tag, digest}`, con supporto opzionale a un registry globale condiviso.
- **Validazione al render-time**: i template usano `fail` di Go template per produrre messaggi di errore leggibili quando mancano valori obbligatori o la configurazione è incoerente.
- **Test suite integrata**: 16 suite per 220 test con helm-unittest, eseguibili via Docker senza dipendenze locali.

### Per chi è questo documento

| Ruolo | Sezioni consigliate |
|---|---|
| **Utente nuovo** | 1, 2, 3, 4, 7 |
| **Sviluppatore di applicazioni** | 4, 7, 8, 9 |
| **Architetto** | 2, 5, 6, 10 |
| **Contributore** | 5, 6, 10, 11, 12, 13 |
| **Operazioni/SRE** | 9, 12, 14 |

---

## 2. Panoramica dell'Architettura

### 2.1 Struttura del repository

```
global-chart/
├── charts/
│   └── global-chart/
│       ├── Chart.yaml                  # Metadati del chart (versione, descrizione)
│       ├── values.yaml                 # Valori di default documentati
│       ├── templates/
│       │   ├── _helpers.tpl            # Libreria di helper template (nessun output)
│       │   ├── deployment.yaml
│       │   ├── service.yaml
│       │   ├── serviceaccount.yaml
│       │   ├── configmap.yaml
│       │   ├── secret.yaml
│       │   ├── mounted-configmap.yaml
│       │   ├── hpa.yaml
│       │   ├── pdb.yaml
│       │   ├── networkpolicy.yaml
│       │   ├── ingress.yaml
│       │   ├── cronjob.yaml
│       │   ├── hook.yaml
│       │   ├── externalsecret.yaml
│       │   ├── rbac.yaml
│       │   ├── NOTES.txt
│       │   └── tests/
│       │       └── test-connection.yaml
│       └── tests/                      # Suite helm-unittest
│           ├── deployment_test.yaml
│           ├── cronjob_test.yaml
│           └── ... (16 file totali)
├── tests/                              # File di valori per scenari lint
│   ├── test01/
│   │   └── values.01.yaml             # Kitchen-sink: tutti i costrutti
│   ├── multi-deployment.yaml
│   ├── deployment-hooks-cronjobs.yaml
│   └── ... (15 scenari totali)
├── Makefile                            # Comandi operativi
├── .github/workflows/
│   ├── helm-ci.yml                     # Lint, test, genera manifest
│   └── release.yml                     # Pubblica il chart su GitHub Pages
└── CHANGELOG.md
```

### 2.2 Filosofia di progettazione

Il chart è costruito attorno a tre principi:

**1. Convention over configuration**
La maggior parte dei campi ha un valore sensato di default. Un deployment minimale richiede solo il campo `image`. Tutto il resto — ServiceAccount, repliche, policy dell'immagine, porta — viene risolto automaticamente.

**2. Fail fast con messaggi chiari**
Quando un valore obbligatorio manca o la configurazione è inconsistente (es. sia `minAvailable` che `maxUnavailable` sul PDB), il template fallisce al momento del render con un messaggio che indica esattamente dove e perché. Non esistono "silenziosi default sbagliati".

**3. hasKey per distinguere "non impostato" da "impostato a vuoto"**
Go template tratta `false`, `0`, `{}`, e `[]` come falsy. Il chart usa sistematicamente `hasKey` per distinguere un campo mai impostato (che deve ereditare o usare il default) da un campo esplicitamente impostato a un valore vuoto (che deve sovrascrivere l'ereditarietà). Questo pattern è fondamentale per la correttezza dell'inheritance model (vedere sezione 10).

### 2.3 Mappa delle risorse generate

Il diagramma seguente mostra le risorse Kubernetes generate per ogni componente del values e le loro relazioni:

```
values.yaml
│
├── deployments.*                        Per ogni deployment abilitato:
│   ├── → Deployment                     (deployment.yaml)
│   ├── → Service                        (service.yaml, se enabled != false)
│   ├── → ServiceAccount                 (serviceaccount.yaml, se create != false)
│   ├── → ConfigMap                      (configmap.yaml, se configMap non vuoto)
│   ├── → Secret                         (secret.yaml, se secret non vuoto)
│   ├── → HorizontalPodAutoscaler        (hpa.yaml, se autoscaling.enabled)
│   ├── → PodDisruptionBudget            (pdb.yaml, se pdb.enabled)
│   ├── → NetworkPolicy                  (networkpolicy.yaml, se networkPolicy.enabled)
│   ├── → ConfigMap[]/projected          (mounted-configmap.yaml, se mountedConfigFiles)
│   ├── → Job[]                          (hook.yaml, per ogni hooks.*)
│   └── → CronJob[]                      (cronjob.yaml, per ogni cronJobs.*)
│
├── ingress                              → Ingress (se ingress.enabled)
├── cronJobs.*                           → CronJob[] (cronjob.yaml, livello root)
├── hooks.*.*                            → Job[] + ServiceAccount opzionale (hook.yaml)
├── externalSecrets.*                    → ExternalSecret[] (externalsecret.yaml)
└── rbacs.roles[]                        → ServiceAccount + Role + RoleBinding (rbac.yaml)
```

### 2.4 Naming convention delle risorse

Il nome di ogni risorsa è determinato da una formula precisa basata sul nome della release Helm, il nome del chart e il nome del deployment o job. Tutte le risorse rispettano il limite DNS di 63 caratteri.

| Tipo di risorsa | Pattern | Limite |
|---|---|---|
| Deployment, Service, SA, ConfigMap, Secret, HPA, PDB, NetworkPolicy | `{release}-{chart}-{deploymentName}` | 63 |
| Mounted ConfigMap | `{release}-{chart}-{deploymentName}-md-cm-{name}` | 63 |
| Ingress | `{release}-{chart}` | 63 |
| CronJob root-level | `{release}-{chart}-{cronjobName}` | **52** |
| CronJob dentro deployment | `{release}-{chart}-{deploymentName}-{cronjobName}` | **52** |
| Hook Job root-level | `{release}-{chart}-{hookType}-{jobName}` | 63 |
| Hook Job dentro deployment | `{release}-{chart}-{deploymentName}-{hookType}-{jobName}` | 63 |

> Il limite di 52 caratteri per i CronJob è necessario perché Kubernetes aggiunge automaticamente un suffisso di 11 caratteri (`-xxxxxxxxxx`) quando crea i Job dal CronJob, e il limite totale del nome Job è 63 caratteri.

**Esempio pratico:**

```
Release: myapp
Chart: global-chart
Deployment: backend

→ Deployment:    myapp-global-chart-backend
→ Service:       myapp-global-chart-backend
→ ServiceAccount: myapp-global-chart-backend
→ ConfigMap:     myapp-global-chart-backend
→ CronJob:       myapp-global-chart-backend-cleanup  (trunc a 52)
→ Hook Job:      myapp-global-chart-backend-pre-upgrade-migrate (trunc a 63)
```

---

## 3. Installazione e Quick Start

### 3.1 Prerequisiti

- Helm >= 3.x
- Kubernetes >= 1.19
- Docker (per eseguire i test localmente)
- `make` (per usare il Makefile)

### 3.2 Installazione del chart

**Da repository locale (sviluppo):**

```bash
# Installazione base
helm install myapp ./charts/global-chart \
  -f myvalues.yaml \
  --namespace myapp \
  --create-namespace

# Aggiornamento
helm upgrade myapp ./charts/global-chart \
  -f myvalues.yaml \
  --namespace myapp
```

**Come dipendenza in un altro chart (`Chart.yaml`):**

```yaml
dependencies:
  - name: global-chart
    version: "1.3.0"
    repository: "https://filippomerante.github.io/global-chart"
```

### 3.3 Esempio minimo — un deployment nginx

Il chart richiede almeno un deployment con un campo `image`. Tutto il resto ha valori di default:

```yaml
# values.yaml
deployments:
  web:
    image: nginx:1.25
```

Questo genera:
- `Deployment` con 2 repliche (default), immagine `nginx:1.25`, policy `IfNotPresent`
- `Service` di tipo `ClusterIP` sulla porta 80
- `ServiceAccount` dedicato

### 3.4 Esempio completo — stack applicativo

```yaml
global:
  imageRegistry: registry.example.com
  imagePullSecrets:
    - name: regcred

deployments:
  frontend:
    image:
      repository: myorg/frontend
      tag: "v3.2.1"
    replicaCount: 3
    service:
      port: 80
    configMap:
      API_URL: https://api.example.com
    autoscaling:
      enabled: true
      minReplicas: 2
      maxReplicas: 10
      targetCPUUtilizationPercentage: 70

  backend:
    image:
      repository: myorg/backend
      tag: "v2.5.0"
    replicaCount: 2
    service:
      port: 3000
    configMap:
      DB_HOST: postgres.db.svc
    secret:
      DB_PASSWORD: mypassword
    hooks:
      pre-upgrade:
        migrate:
          command: ["./migrate", "up"]

  worker:
    image:
      repository: myorg/worker
      tag: "v2.5.0"
    service:
      enabled: false
    configMap:
      QUEUE_URL: redis://redis:6379
    cronJobs:
      cleanup:
        schedule: "0 4 * * *"
        command: ["./cleanup.sh"]

ingress:
  enabled: true
  className: nginx
  hosts:
    - host: example.com
      deployment: frontend
      paths:
        - path: /
    - host: api.example.com
      deployment: backend
      paths:
        - path: /
```

### 3.5 Comandi Makefile

Il Makefile è lo strumento principale per lo sviluppo e la verifica del chart.

```bash
# Mostra tutti i target disponibili
make help

# Lint di tutti gli scenari di test (esegue helm lint --strict)
make lint-chart

# Esegue la test suite con helm-unittest (via Docker)
make unit-test

# Genera i manifest per ispezione visiva (output in generated-manifests/)
make generate-templates

# Esegue lint + unit test + genera manifest
make all

# Esegue kube-linter sui manifest generati (richiede Docker)
make kube-linter

# Genera la documentazione helm-docs (richiede Docker)
make generate-docs

# Pacchettizza il chart
make package

# Installa uno scenario di test su un cluster
make install SCENARIO=test01
make install SCENARIO=multi-deployment

# Rende un singolo template per debug
make render VALUES=tests/test01/values.01.yaml TEMPLATE=deployment.yaml

# Pulizia file generati
make clean

# Pulizia completa + disinstalla le release di test
make clean-all
```

---

## 4. Riferimento ai Valori

Questa sezione documenta tutti i valori configurabili del chart, organizzati per area funzionale.

### 4.1 Valori globali

```yaml
global:
  imageRegistry: ""           # Prefisso registry condiviso (es. "registry.example.com")
  imagePullSecrets: []        # Pull secret globali di fallback

nameOverride: ""              # Sovrascrive il nome del chart nei nomi delle risorse
fullnameOverride: ""          # Sovrascrive il fullname completo (release + chart)
```

**Comportamento di `global.imageRegistry`:**
Quando impostato, viene preposto al nome dell'immagine di ogni risorsa (deployment, cronjob, hook), a meno che il primo segmento dell'immagine non sia già un registry (contiene `.` o `:`, oppure è `localhost`). Questo permette di gestire correttamente immagini come `docker.io/nginx:1.25` (non modificata) vs `myorg/myapp:v1` (diventa `registry.example.com/myorg/myapp:v1`).

**Comportamento di `global.imagePullSecrets`:**
Viene usato come fallback solo quando la risorsa (deployment, cronjob, hook) non ha definito il proprio campo `imagePullSecrets`. L'uso di `hasKey` garantisce che un `imagePullSecrets: []` esplicito sulla risorsa disabiliti il fallback globale — non viene interpretato come "non impostato".

### 4.2 Deployment

Ogni entry nella mappa `deployments` definisce un deployment indipendente con tutte le risorse correlate.

```yaml
deployments:
  <nome>:
    # ── Abilitazione ──────────────────────────────────────────────
    enabled: true                    # bool, default true. Se false, salta tutto.

    # ── Immagine ──────────────────────────────────────────────────
    image: "nginx:1.25"              # Stringa oppure oggetto:
    # image:
    #   repository: nginx            # Obbligatorio se mappa
    #   tag: "1.25"                  # Alternativo a digest
    #   digest: "sha256:abc..."      # Alternativo a tag (digest prevalente su tag)
    #   pullPolicy: IfNotPresent     # Always | IfNotPresent | Never

    imagePullSecrets: []             # Pull secret specifici per questo deployment
                                     # Se omesso: usa global.imagePullSecrets

    # ── Repliche e scaling ────────────────────────────────────────
    replicaCount: 2                  # Ignorato se autoscaling.enabled è true

    autoscaling:
      enabled: false
      minReplicas: 2                 # Obbligatorio se enabled
      maxReplicas: 10                # Obbligatorio se enabled
      targetCPUUtilizationPercentage: ""    # int, omesso se 0
      targetMemoryUtilizationPercentage: "" # int, omesso se 0
      behavior:                      # Opzionale, vedi HPA v2 behavior
        scaleUp: {}
        scaleDown: {}

    # ── Strategia di rollout ──────────────────────────────────────
    strategy:
      type: RollingUpdate            # O Recreate
      rollingUpdate:
        maxSurge: 1
        maxUnavailable: 0
    revisionHistoryLimit: 10         # Numero di ReplicaSet da conservare
    progressDeadlineSeconds: 600     # Timeout del progresso del Deployment

    # ── ServiceAccount ────────────────────────────────────────────
    serviceAccount:
      create: true                   # Default true. false = usa SA esistente
      name: ""                       # Nome esplicito (crea o usa esistente)
      automount: true                # Monta automaticamente il token
      annotations: {}                # Annotations sul SA (es. IRSA, Workload Identity)

    # ── Service ───────────────────────────────────────────────────
    service:
      enabled: true                  # false per worker/background job
      type: ClusterIP                # ClusterIP | NodePort | LoadBalancer
      port: 80
      targetPort: http               # Nome porta o numero
      portName: http
      protocol: TCP

    # ── Configurazione env ────────────────────────────────────────
    configMap: {}                    # key/value → ConfigMap + envFrom
    secret: {}                       # key/value → Secret + envFrom (base64 auto)
    envFromConfigMaps: []            # Nomi di ConfigMap esistenti da importare
    envFromSecrets: []               # Nomi di Secret esistenti da importare
    additionalEnvs: []               # Variabili env native Kubernetes (env[])

    # ── Probes ────────────────────────────────────────────────────
    livenessProbe: {}                # Spec native Kubernetes
    readinessProbe: {}
    startupProbe: {}

    # ── Risorse ───────────────────────────────────────────────────
    resources: {}                    # requests/limits

    # ── Security ──────────────────────────────────────────────────
    podSecurityContext: {}           # Livello Pod (fsGroup, runAsGroup, ...)
    securityContext: {}              # Livello container (runAsUser, capabilities, ...)

    # ── Scheduling ────────────────────────────────────────────────
    nodeSelector: {}
    tolerations: []
    affinity: {}
    topologySpreadConstraints: []
    hostAliases: []
    dnsConfig:
      nameservers: []
      searches: []
      options: []

    # ── Volumi ────────────────────────────────────────────────────
    volumes: []                      # Spec native K8s o formato legacy .type
    volumeMounts: []

    # ── Container extra ───────────────────────────────────────────
    extraInitContainers: []
    extraContainers: []

    # ── PodDisruptionBudget ───────────────────────────────────────
    pdb:
      enabled: false
      minAvailable: 1                # Mutuamente esclusivo con maxUnavailable
      # maxUnavailable: 1

    # ── NetworkPolicy ─────────────────────────────────────────────
    networkPolicy:
      enabled: false
      policyTypes: []                # Opzionale: ["Ingress"] | ["Egress"] | entrambi
      ingress: []                    # Regole ingress standard Kubernetes
      egress: []                     # Regole egress standard Kubernetes

    # ── Mounted ConfigFiles ───────────────────────────────────────
    mountedConfigFiles:
      files: []                      # ConfigMap singoli, uno per file
      bundles: []                    # Proiezioni multi-file in un ConfigMap

    # ── Ricreazione forzata pod ───────────────────────────────────
    podRecreation:
      enabled: false                 # Aggiunge annotation timestamp per forzare restart

    # ── Metadati pod ─────────────────────────────────────────────
    podAnnotations: {}
    podLabels: {}

    # ── Hook dentro deployment (ereditano dal parent) ─────────────
    hooks:
      <hookType>:                    # pre-install, post-install, pre-upgrade, ecc.
        <jobName>:
          command: []
          # ... (vedi sezione 8)

    # ── CronJob dentro deployment (ereditano dal parent) ──────────
    cronJobs:
      <jobName>:
        schedule: "* * * * *"
        command: []
        # ... (vedi sezione 8)
```

### 4.3 Ingress

```yaml
ingress:
  enabled: false
  className: "nginx"
  annotations: {}
  tls: []
    # - secretName: myapp-tls
    #   hosts:
    #     - example.com

  hosts:
    - host: example.com
      deployment: frontend         # Riferimento a deployments.frontend
      # service:                   # Alternativa: service esterno
      #   name: external-svc
      #   port: 8080
      paths:
        - path: /
          pathType: ImplementationSpecific
```

**Regole di validazione Ingress:**
- Ogni host deve specificare `deployment` (nome di un deployment) **oppure** `service.name` (nome di un service esterno). Se nessuno dei due è fornito, il render fallisce.
- Se `deployment` referenzia un deployment con `enabled: false`, il render fallisce con un messaggio che indica il problema (il Service non sarà creato).

### 4.4 CronJob root-level

```yaml
cronJobs:
  <nome>:
    schedule: "0 2 * * *"           # Obbligatorio
    image: myapp:v1                  # Oppure oggetto {repository, tag}
    # fromDeployment: main           # Alternativa: copia immagine da un deployment
    command: []
    args: []
    imagePullPolicy: IfNotPresent
    imagePullSecrets: []             # Se omesso: usa global.imagePullSecrets
    concurrencyPolicy: Forbid        # Allow | Forbid | Replace
    successfulJobsHistoryLimit: 2
    failedJobsHistoryLimit: 2
    restartPolicy: Never
    resources: {}                    # Se omesso: usa defaults.resources
    env: []
    envFromConfigMaps: []
    envFromSecrets: []
    volumes: []
    volumeMounts: []
    nodeSelector: {}
    tolerations: []
    affinity: {}
    hostAliases: []
    dnsConfig: {}
    podSecurityContext: {}
    securityContext: {}
    initContainers: []
    annotations: {}
    serviceAccountName: ""          # Nome SA esistente
    serviceAccount:                  # O crea un SA dedicato
      create: true
      name: ""
      automount: true
      annotations: {}
```

### 4.5 Hook root-level

```yaml
hooks:
  <hookType>:                        # pre-install | post-install | pre-upgrade | ...
    <jobName>:
      image: myapp:v1               # Oppure fromDeployment: main
      command: []
      args: []
      weight: "10"                  # Ordine di esecuzione degli hook
      deletePolicy: before-hook-creation
      resources: {}                  # Se omesso: usa defaults.resources
      imagePullPolicy: IfNotPresent
      imagePullSecrets: []
      env: []
      envFromConfigMaps: []
      envFromSecrets: []
      volumes: []
      volumeMounts: []
      nodeSelector: {}
      tolerations: []
      affinity: {}
      hostAliases: []
      podSecurityContext: {}
      securityContext: {}
      restartPolicy: Never
      serviceAccountName: ""        # Nome SA esistente
      serviceAccount:               # O gestisci il SA dell'hook
        create: false
        name: ""
        automount: true
        annotations: {}
```

### 4.6 ExternalSecrets

```yaml
externalSecrets:
  <nome>:
    secretkey: "my-key"             # Obbligatorio: chiave nel Secret Kubernetes
    remote:
      key: "path/to/secret"         # Obbligatorio: chiave nel secret store remoto
      conversionStrategy: Default
      decodingStrategy: None
      metadataPolicy: None
    secretstore:
      kind: ClusterSecretStore      # Obbligatorio
      name: my-store                # Obbligatorio
    refreshInterval: "1h"
    target:
      name: ""                      # Default: {fullname}-{nome}
      creationPolicy: Owner
      deletionPolicy: Retain
```

### 4.7 RBAC

```yaml
rbacs:
  roles:
    - name: custom-role             # Opzionale, default: {fullname}-role-{index}
      serviceAccount:
        name: custom-sa
        create: true                # Default true
        automount: true
        annotations: {}
      rules:
        - apiGroups: [""]
          resources: ["pods"]
          verbs: ["get", "list"]
```

Il template genera per ogni entry: `ServiceAccount` (se create=true) + `Role` + `RoleBinding`.

### 4.8 Defaults

```yaml
defaults:
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
```

I valori in `defaults.resources` vengono usati come fallback per tutti i CronJob e Hook che non specificano esplicitamente il campo `resources`. Se un job ha `resources: {}` (esplicito ma vuoto), il fallback viene ignorato e nessun blocco `resources` viene reso.

---

## 5. Architettura dei Template

### 5.1 Pattern di iterazione

Ogni template che gestisce risorse per-deployment segue il medesimo pattern:

```
{{- $root := . }}
{{- range $name, $deploy := .Values.deployments }}
{{- if $deploy }}
{{- if eq (include "global-chart.deploymentEnabled" (dict "deploy" $deploy)) "true" }}
  ... generazione risorsa ...
{{- end }}
{{- end }}
{{- end }}
```

Il doppio guard (`if $deploy` e `deploymentEnabled`) gestisce sia i deployment nulli (YAML `null`) sia quelli esplicitamente disabilitati con `enabled: false`.

### 5.2 Template deployment.yaml

Il deployment è il template più complesso. Le sezioni principali sono:

**Checksums di configurazione:**
```yaml
checksum/config: {{ toYaml $deploy.configMap | sha256sum }}
checksum/secret: {{ toYaml $deploy.secret | sha256sum }}
checksum/mounted-config-files: {{ toYaml $deploy.mountedConfigFiles | sha256sum }}
```
Questi annotation forzano un rolling restart del pod quando la configurazione cambia — comportamento standard di Helm, ma esplicito per tutti e tre i tipi di configurazione.

**podRecreation:**
```yaml
{{- if $podRecreation.enabled }}
timestamp: "{{ now | date "20060102150405" }}"
{{- end }}
```
Aggiunge un annotation con il timestamp corrente ad ogni render, forzando il restart del pod anche senza modifiche ai valori. Utile per worker con `pullPolicy: Always`.

**Gestione imagePullSecrets:**
```yaml
{{- if hasKey $deploy "imagePullSecrets" -}}
  {{- $imagePullSecrets = $deploy.imagePullSecrets -}}
{{- else -}}
  {{- $global := default (dict) $root.Values.global -}}
  {{- $imagePullSecrets = $global.imagePullSecrets -}}
{{- end -}}
```
Il pattern `hasKey` è fondamentale: se un deployment imposta `imagePullSecrets: []` (lista vuota esplicita), il campo è presente nella mappa e viene usato come tale — il fallback al globale non si attiva. Se `imagePullSecrets` è semplicemente assente dal deployment, si usa il globale.

**envFrom:**
Il template genera un blocco `envFrom` che aggrega in ordine: ConfigMap generato → Secret generato → ConfigMap esterni → Secret esterni → variabili aggiuntive (`additionalEnvs` va in `env`, non `envFrom`).

**Volumi:** I volumi utente vengono iterati con `renderVolume` (gestisce entrambi i formati), poi vengono aggiunti i volumi dei mountedConfigFiles.

### 5.3 Template service.yaml

```
{{- $svcEnabled := true }}
{{- if and (hasKey $svc "enabled") (not $svc.enabled) }}
{{- $svcEnabled = false }}
{{- end }}
```

Anche qui `hasKey` è necessario: `service.enabled` di default è `true` (assente dalla mappa). Solo se esplicitamente impostato a `false` il Service viene saltato. Il pattern `not $svc.enabled` da solo non funzionerebbe per distinguere `false` da una chiave assente.

### 5.4 Template cronjob.yaml

Il template ha due parti distinte:

**Parte 1 — CronJob root-level:**
- Risolve l'immagine: campo `image` esplicito > `fromDeployment` > errore
- Gestisce opzionalmente la creazione di un ServiceAccount dedicato
- Accetta `dnsConfig`, `hostAliases`, `podSecurityContext` direttamente

**Parte 2 — CronJob dentro deployment:**
- Genera un nome che include sia il nome del deployment sia il nome del job
- Eredita immagine, envFrom (ConfigMap + Secret del deployment), envFromConfigMaps/envFromSecrets, additionalEnvs, imagePullSecrets, hostAliases, podSecurityContext, securityContext, dnsConfig, nodeSelector, tolerations, affinity
- Ogni campo ereditato usa `hasKey` + `ternary` per permettere l'override con valore vuoto

### 5.5 Template hook.yaml

Struttura identica a cronjob.yaml (due parti). Le differenze rispetto ai CronJob:

- Aggiunge le annotation di Helm hook (`helm.sh/hook`, `helm.sh/hook-weight`, `helm.sh/hook-delete-policy`)
- Crea un ServiceAccount dedicato per ogni hook root-level (a meno che non venga specificato un SA esistente)
- I hook dentro deployment non ereditano `dnsConfig` (assente dalla specifica hook in deployment), ma ereditano tutte le altre proprietà

**Gestione del peso (weight):**
Il SA viene creato con `weight-5` rispetto al Job (`weight-10`) per garantire che esista prima che il Job venga eseguito.

### 5.6 Template ingress.yaml

```
{{- if and (hasKey $hostEntry "service") $hostEntry.service $hostEntry.service.name -}}
  # Priority 1: Explicit service override
{{- else if $hostEntry.deployment -}}
  # Priority 2: Deployment reference (with existence and enabled check)
{{- else -}}
  # Priority 3: Error
{{- end }}
```

Il template risolve il nome del Service backend con questa priorità: service esplicito > riferimento deployment > errore.

L'annotation `deepCopy` viene usata per le annotations: `{{- $annotations := deepCopy (default (dict) $ing.annotations) }}`. Questo è il pattern corretto per evitare mutazioni di `.Values` durante il render.

### 5.7 Template hpa.yaml

```yaml
{{- $cpu := int (default 0 $hpa.targetCPUUtilizationPercentage) }}
{{- $mem := int (default 0 $hpa.targetMemoryUtilizationPercentage) }}
{{- $hasMetric := or (gt $cpu 0) (gt $mem 0) }}
{{- if and $hpa.enabled $hasMetric }}
```

L'HPA viene generato solo se almeno una metrica è impostata a un valore > 0. Usa l'API `autoscaling/v2` (disponibile da Kubernetes 1.23+, ma il chart richiede solo 1.19 — aggiornare il cluster prima di usare HPA con behavior).

### 5.8 Template pdb.yaml

```yaml
{{- if and (hasKey $pdb "minAvailable") (hasKey $pdb "maxUnavailable") }}
{{- fail (printf "PDB for deployment '%s': minAvailable and maxUnavailable are mutually exclusive..." $name) }}
{{- end }}
{{- if not (or (hasKey $pdb "minAvailable") (hasKey $pdb "maxUnavailable")) }}
{{- fail (printf "PDB for deployment '%s': one of minAvailable or maxUnavailable is required..." $name) }}
{{- end }}
{{- if hasKey $pdb "minAvailable" }}
minAvailable: {{ $pdb.minAvailable }}
{{- end }}
```

`hasKey` è essenziale qui: `minAvailable: 0` è un valore valido (zero pod disponibili durante manutenzione). Usare `if $pdb.minAvailable` escluderebbe questo caso legittimo.

### 5.9 Template networkpolicy.yaml

```yaml
{{- if $np.policyTypes }}
policyTypes:
  {{- toYaml $np.policyTypes | nindent 4 }}
{{- else if or $np.ingress $np.egress }}
policyTypes:
  {{- if $np.ingress }}- Ingress{{- end }}
  {{- if $np.egress }}- Egress{{- end }}
{{- else }}
{{- fail (printf "NetworkPolicy for deployment '%s': at least one of policyTypes, ingress, or egress must be set..." $name) }}
{{- end }}
```

Se `policyTypes` è fornito esplicitamente, viene usato as-is. Altrimenti viene derivato dalla presenza di regole ingress/egress. Se né `policyTypes` né le regole sono presenti, il render fallisce — evitando un manifesto NetworkPolicy con `policyTypes:` vuoto che Kubernetes rifiuterebbe.

---

## 6. Il Sistema di Helper

Tutti gli helper sono definiti in `charts/global-chart/templates/_helpers.tpl`. Il file non genera output direttamente ma fornisce funzioni chiamate da tutti gli altri template.

### 6.1 Helper di naming

#### `global-chart.name`
```
Input: contesto root (.)
Output: nome del chart, troncato a 63 caratteri
        usa nameOverride se impostato
```

#### `global-chart.fullname`
```
Input: contesto root (.)
Output: "{release}-{chart}" troncato a 63 caratteri
        usa fullnameOverride se impostato
        se release contiene già il nome del chart, usa solo il release
```

#### `global-chart.chart`
```
Input: contesto root (.)
Output: "{chart}-{version}" (es. "global-chart-1.3.0")
        usato nel label helm.sh/chart
```

#### `global-chart.deploymentFullname`
```
Input: dict { root: ., deploymentName: "backend" }
Output: "{fullname}-{deploymentName}" troncato a 63 caratteri
```

#### `global-chart.hookfullname`
```
Input: contesto root con .hookname e .jobname
Output: "{fullname}-{hookname}-{jobname}" troncato a 63 caratteri
```

### 6.2 Helper di label

#### `global-chart.labels`
Label standard per risorse non-deployment (Ingress, ExternalSecret, RBAC):
```yaml
helm.sh/chart: global-chart-1.3.0
app.kubernetes.io/name: global-chart
app.kubernetes.io/instance: myrelease
app.kubernetes.io/version: "1.3.0"
app.kubernetes.io/managed-by: Helm
```

#### `global-chart.selectorLabels`
Subset di labels usato nei selettori (non include `helm.sh/chart` né `version` per stabilità):
```yaml
app.kubernetes.io/name: global-chart
app.kubernetes.io/instance: myrelease
```

#### `global-chart.deploymentLabels`
Labels per risorse per-deployment:
```yaml
helm.sh/chart: global-chart-1.3.0
app.kubernetes.io/name: global-chart
app.kubernetes.io/instance: myrelease
app.kubernetes.io/component: backend    # <- differenzia i deployment
app.kubernetes.io/version: "1.3.0"
app.kubernetes.io/managed-by: Helm
```

#### `global-chart.deploymentSelectorLabels`
Usato nei `selector.matchLabels` e nei `selector` dei Service:
```yaml
app.kubernetes.io/name: global-chart
app.kubernetes.io/instance: myrelease
app.kubernetes.io/component: backend    # <- fondamentale per l'isolamento
```

Il componente `app.kubernetes.io/component` garantisce che i pod di deployment diversi non si sovrappongano mai. Senza questo, un Service potrebbe selezionare pod di deployment sbagliati.

#### `global-chart.hookLabels` / `global-chart.hookLabelsWithComponent`
I hook **non includono** i `selectorLabels`. Questo è intenzionale: se i hook avessero le stesse label dei pod del deployment, l'HPA potrebbe selezionarli e calcolare metriche sbagliate durante l'esecuzione.

### 6.3 Helper di abilitazione

#### `global-chart.deploymentEnabled`
```
Input: dict { deploy: $deploy }
Output: "true" o "false" (stringa, non booleano)
        default "true" se il campo enabled è assente
```

Usa `ternary .deploy.enabled true (hasKey .deploy "enabled")` — se la chiave esiste usa il suo valore, altrimenti usa `true`.

> Restituisce una stringa perché Go template non permette di assegnare direttamente il risultato di un'espressione booleana a una variabile e confrontarla facilmente nei template condizionali `{{- if }}`/`{{- else }}`. La convenzione di restituire `"true"`/`"false"` come stringa e confrontarla con `eq ... "true"` è più robusta.

### 6.4 Helper di ServiceAccount

#### `global-chart.deploymentServiceAccountName`
```
Input: dict { root: ., deploymentName: "backend", deployment: $deploy }
Output: nome del ServiceAccount da usare nel pod
```

Logica:
1. Se `serviceAccount.create` è `true` (default): usa il nome generato o il nome esplicito `serviceAccount.name`
2. Se `serviceAccount.create` è `false`: usa `serviceAccount.name` oppure `"default"`

### 6.5 Helper di immagine

#### `global-chart.imageString`
Il cuore della gestione delle immagini. Supporta due modalità di chiamata:

**Modalità legacy (compatibilità):**
```
{{ include "global-chart.imageString" $deploy.image }}
```

**Modalità nuova (con registry globale):**
```
{{ include "global-chart.imageString" (dict "image" $deploy.image "global" $root.Values.global) }}
```

**Algoritmo di risoluzione del registry:**

```
image = "nginx:1.25"                → "nginx:1.25" (no segmento con slash)
image = "myorg/myapp:v1"            → "registry/myorg/myapp:v1" (aggiunge registry)
image = "docker.io/nginx:1.25"      → "docker.io/nginx:1.25" (primo segmento contiene ".")
image = "localhost:5000/myapp:v1"   → "localhost:5000/myapp:v1" (primo segmento è "localhost")
image = "registry:5000/app:v1"      → "registry:5000/app:v1" (primo segmento contiene ":")
```

**Formati supportati:**
- Stringa: `"nginx:1.25"`, `"ghcr.io/org/app:v1"`
- Mappa con tag: `{ repository: myapp, tag: v1 }`
- Mappa con digest: `{ repository: myapp, digest: sha256:abc... }`
- Mappa con digest senza repository: **errore** (`fail`)
- Mappa senza né tag né digest: restituisce solo il repository

#### `global-chart.imagePullPolicy`
```
Input: dict {
  override: string|nil,   # Campo pullPolicy esplicito a livello job
  image: map|string,      # Oggetto immagine (per image.pullPolicy)
  fallback: string|nil    # Fallback specifico
}
Output: policy stringa (Always | IfNotPresent | Never)
        default: "IfNotPresent"
```

Priorità: `override` > `image.pullPolicy` > `fallback` > `"IfNotPresent"`.

### 6.6 Helper di render condivisi

Questi helper sono chiamati con il pattern `{{- with (include ...) }}{{- . | nindent N }}{{- end }}` per evitare linee vuote quando non producono output.

#### `global-chart.renderImagePullSecrets`
```
Input: lista di stringhe o oggetti { name: "..." }
Output: blocco YAML "imagePullSecrets:" oppure stringa vuota
```

Accetta sia `"regcred"` (stringa) sia `{ name: "regcred" }` (oggetto), normalizzando al formato Kubernetes `- name: "..."`.

#### `global-chart.renderDnsConfig`
```
Input: dizionario dnsConfig
Output: blocco YAML "dnsConfig:" oppure stringa vuota
        vuoto se nessuno dei campi nameservers/searches/options è impostato
```

#### `global-chart.renderResources`
```
Input: dict {
  resources: map,       # Risorse esplicite
  hasResources: bool,   # true se il campo resources esiste nella mappa job
  defaults: map         # Valori defaults dal values.yaml
}
Output: blocco YAML "resources:" oppure stringa vuota
```

**Semantica hasResources:**
- `hasResources: false` (campo assente): usa `defaults.resources` come fallback
- `hasResources: true, resources: {...}`: usa le risorse specificate
- `hasResources: true, resources: {}` (campo presente ma vuoto): nessun blocco resources (override esplicito del default)

#### `global-chart.renderVolume`
```
Input: oggetto volume
Output: entry YAML del volume (con "- name: ...")
```

**Formato nativo (raccomandato):** qualsiasi spec Kubernetes senza il campo `type`. Tutti i campi eccetto `name` vengono serializzati con `toYaml` — ordine delle chiavi deterministico.

**Formato legacy (compatibilità):** oggetto con campo `type` che viene tradotto:
- `type: emptyDir` → `emptyDir: {}`
- `type: configMap` → usa `configMap.name`
- `type: secret` → usa `secret.secretName` o `secret.name`
- `type: persistentVolumeClaim` → usa `persistentVolumeClaim.claimName` o `persistentVolumeClaim.name`
- Qualsiasi altro tipo → **errore** con lista dei tipi supportati

---

## 7. Pattern Multi-Deployment

Il pattern multi-deployment è la funzionalità principale del chart: permette di deployare più workload indipendenti in una singola release Helm, mantenendo la gestione coordinata del ciclo di vita (upgrade, rollback, test).

### 7.1 Quando usarlo

Situazioni appropriate per il multi-deployment:
- **Stack applicativi accoppiati**: frontend + backend + worker che evolvono insieme
- **Deployment con requisiti di scheduling diversi**: componenti che devono stare su nodepool differenti
- **Microservizi correlati**: servizi che condividono configurazione o secret
- **Pattern Odoo/Nginx**: un'applicazione principale più un reverse proxy, con hook coordinati

Situazioni in cui **non** usarlo:
- Microservizi completamente indipendenti con cicli di release separati
- Applicazioni gestite da team diversi (governance separata)
- Deployment con valori molto diversi e nessuna configurazione condivisa

### 7.2 Struttura di un multi-deployment

```yaml
deployments:
  frontend:           # Deployment 1 — espone HTTP su porta 80
    image: nginx:1.25
    replicaCount: 3
    service:
      port: 80

  backend:            # Deployment 2 — API su porta 3000, con SA dedicato
    image: myapp:v2
    replicaCount: 2
    serviceAccount:
      create: true
      name: backend-sa
    service:
      port: 3000

  worker:             # Deployment 3 — nessun Service, toleration dedicata
    image: myapp:v2
    service:
      enabled: false  # Worker non espone porte
    tolerations:
      - key: workload
        value: background
        effect: NoSchedule
```

### 7.3 Isolamento dei selettori

Ogni deployment genera un set di label differenziato dal campo `app.kubernetes.io/component`. I `selector.matchLabels` del Deployment e del Service includono questo campo:

```yaml
# Deployment frontend:
selector:
  matchLabels:
    app.kubernetes.io/name: global-chart
    app.kubernetes.io/instance: myrelease
    app.kubernetes.io/component: frontend   # ← unico per frontend

# Deployment backend:
selector:
  matchLabels:
    app.kubernetes.io/name: global-chart
    app.kubernetes.io/instance: myrelease
    app.kubernetes.io/component: backend    # ← unico per backend
```

Questo garantisce che:
1. I pod di deployment diversi non si sovrappongano mai
2. Ogni Service seleziona solo i pod del deployment corretto
3. Gli HPA e PDB targeting un deployment non influenzano gli altri

### 7.4 Ingress multi-deployment

L'Ingress può instradare verso deployment diversi nella stessa release:

```yaml
ingress:
  enabled: true
  className: nginx
  tls:
    - secretName: myapp-tls
      hosts: [myapp.example.com, api.example.com]
  hosts:
    - host: myapp.example.com
      deployment: frontend          # → Service "myrelease-global-chart-frontend"
      paths:
        - path: /
    - host: api.example.com
      deployment: backend           # → Service "myrelease-global-chart-backend"
      paths:
        - path: /api
    - host: admin.example.com
      service:
        name: external-admin-svc    # → Service esterno (non gestito da questo chart)
        port: 8080
      paths:
        - path: /
```

### 7.5 Deployment disabled

Un deployment può essere disabilitato con `enabled: false`. Questo salta la generazione di **tutte** le risorse associate (Deployment, Service, ServiceAccount, ConfigMap, Secret, HPA, PDB, NetworkPolicy, CronJob interni, Hook interni, MountedConfigMaps).

```yaml
deployments:
  staging:
    enabled: false       # Nessuna risorsa generata per questo deployment
    image: myapp:staging
```

Se un host dell'Ingress referenzia un deployment disabilitato, il render fallisce con un messaggio esplicito.

### 7.6 Esempio reale: stack Odoo + Nginx

Il file `tests/hooks-sa-inheritance.yaml` mostra un caso d'uso reale:

```yaml
deployments:
  odoo:
    image:
      repository: nginx
      tag: latest
    serviceAccount:
      create: false
      name: "odoo-stage-workload-identity"  # SA esistente (Workload Identity GKE)
    configMap:
      HOST: "postgres-host"
      DB_NAME: "odoo_db"
    secret:
      PASSWORD: "db-password"
    mountedConfigFiles:
      files:
        - name: odoo-config
          filename: odoo.conf
          targetPath: /etc/odoo/odoo.conf
          content: |
            [options]
            addons_path = /mnt/extra-addons
            ...
    hooks:
      pre-upgrade:
        scale-down:
          image:
            repository: bitnami/kubectl
            tag: latest
          serviceAccountName: "odoo-scale-hooks"  # Override esplicito SA
          command: [kubectl, scale, deployment, odoo-release-global-chart-odoo, --replicas=0]
        migration:
          image:
            repository: nginx
            tag: latest
          imagePullPolicy: Always
          command: [/bin/sh, -c]
          args: ["./migrate.sh"]
          # Eredita: configMap (DB_HOST, DB_NAME), secret (PASSWORD) dal deployment odoo

  nginx:
    image:
      repository: nginx
      tag: alpine
    mountedConfigFiles:
      files:
        - name: odoo-nginx-config
          filename: odoo.conf
          targetPath: /etc/nginx/conf.d/odoo.conf
          content: |
            upstream odoo { server odoo-release-global-chart-odoo:8069; }
            ...

rbacs:
  roles:
    - name: odoo-scale-hooks
      serviceAccount:
        name: odoo-scale-hooks
        automount: true
      rules:
        - apiGroups: ["apps"]
          resources: ["deployments", "deployments/scale"]
          verbs: ["get", "list", "watch", "update", "patch"]
```

Questo pattern mostra:
- Un deployment con SA esterno (Workload Identity)
- Hook pre-upgrade per scale-down e migrazione con SA diversi
- Un deployment Nginx con configurazione montata che include indirizzi del deployment Odoo

---

## 8. CronJob e Hook — Posizionamento e Ereditarietà

### 8.1 Due modalità di posizionamento

CronJob e Hook possono essere definiti in due posti nel values, con comportamenti diversi:

| Aspetto | Root-level | Dentro deployment |
|---|---|---|
| Posizione YAML | `cronJobs.*` / `hooks.*.*` | `deployments.*.cronJobs.*` / `deployments.*.hooks.*.*` |
| Immagine | Esplicita o `fromDeployment` | Ereditata dal parent (overridabile) |
| ConfigMap/Secret | Nessuna ereditarietà | Ereditati dal parent come envFrom |
| ServiceAccount | Dedicato o `serviceAccountName` | Ereditato dal parent (overridabile) |
| nodeSelector/tolerations/affinity | Nessuna ereditarietà | Ereditati (overridabili) |
| envFromConfigMaps/Secrets | Espliciti | Ereditati dal parent + aggiunti propri |
| additionalEnvs | campo `env` | Unione additionalEnvs parent + propri `env` |
| dnsConfig | Supportato direttamente | Ereditato dal parent (per CronJob), non applicabile per Hook |
| Nome generato | `{release}-{chart}-{jobName}` | `{release}-{chart}-{deployName}-{jobName}` |

### 8.2 Ereditarietà completa (CronJob dentro deployment)

Quando un CronJob è definito dentro un deployment, eredita automaticamente i seguenti campi:

```
Ereditati senza override:
- envFrom: configMap del parent + secret del parent
           + envFromConfigMaps del parent + envFromSecrets del parent

Ereditati con override possibile (hasKey + ternary):
- image              → override: job.image
- serviceAccount     → override: job.serviceAccountName o job.serviceAccount.name
- imagePullSecrets   → override: job.imagePullSecrets: []
- hostAliases        → override: job.hostAliases
- podSecurityContext → override: job.podSecurityContext
- securityContext    → override: job.securityContext
- nodeSelector       → override: job.nodeSelector
- tolerations        → override: job.tolerations
- affinity           → override: job.affinity
- dnsConfig          → override: job.dnsConfig

Unione (non override):
- env: concat(parent.additionalEnvs, job.env)
- envFrom: deployment.envFromConfigMaps + deployment.envFromSecrets
                + job.envFromConfigMaps + job.envFromSecrets
```

### 8.3 Ereditarietà del ServiceAccount

L'ereditarietà del ServiceAccount segue questa logica nei hook/cronjob dentro deployment:

```
1. Se job specifica serviceAccountName o serviceAccount.name → usa quello
2. Else se deployment.serviceAccount.create = true → usa SA del deployment (generato)
3. Else se deployment.serviceAccount.create = false AND deployment.serviceAccount.name → usa SA esistente del deployment
4. Else → crea un nuovo SA dedicato per il job
```

**Esempio pratico:**

```yaml
deployments:
  backend:
    serviceAccount:
      create: true
      name: backend-sa           # SA esistente creato da questo chart
    hooks:
      pre-upgrade:
        migrate:
          command: ["./migrate"]
          # Eredita: usa backend-sa

        scale-down:
          serviceAccountName: "scale-hooks-sa"  # Override: usa SA diverso
          image:
            repository: bitnami/kubectl
            tag: latest
          command: [kubectl, scale, ...]

  odoo:
    serviceAccount:
      create: false
      name: "odoo-workload-identity"   # SA esterno (non creato da chart)
    hooks:
      pre-upgrade:
        migration:
          command: ["./migrate"]
          # Eredita: usa odoo-workload-identity (anche se create=false)
```

### 8.4 Override dell'ereditarietà

Per sovrascrivere un valore ereditato, bisogna **impostare esplicitamente** il campo nel job. La presenza del campo (anche vuota) è sufficiente:

```yaml
deployments:
  backend:
    nodeSelector:
      disktype: ssd
    tolerations:
      - key: workload
        value: backend
        effect: NoSchedule
    cronJobs:
      cleanup:
        schedule: "0 4 * * *"
        command: ["./cleanup.sh"]
        nodeSelector: {}          # Override esplicito: nessun nodeSelector
        tolerations: []           # Override esplicito: nessuna toleration
        # ← questi override vengono rispettati grazie a hasKey
```

Se si omette `nodeSelector` e `tolerations` dal CronJob, vengono ereditati dal deployment.

### 8.5 Tipi di hook Helm

I tipi di hook supportati sono quelli nativi di Helm:

| Tipo | Quando viene eseguito |
|---|---|
| `pre-install` | Prima che vengano installate le risorse al primo `helm install` |
| `post-install` | Dopo che tutte le risorse sono state installate |
| `pre-upgrade` | Prima di ogni `helm upgrade` |
| `post-upgrade` | Dopo ogni `helm upgrade` |
| `pre-delete` | Prima di `helm uninstall` |
| `post-delete` | Dopo `helm uninstall` |
| `pre-rollback` | Prima di `helm rollback` |
| `post-rollback` | Dopo `helm rollback` |
| `test` | Con `helm test` |

### 8.6 Ordinamento degli hook con weight

Quando più hook dello stesso tipo devono essere eseguiti in ordine:

```yaml
hooks:
  pre-upgrade:
    scale-down:
      fromDeployment: main
      command: [kubectl, scale, deployment, myapp, --replicas=0]
      weight: "1"              # Primo

    migrate:
      fromDeployment: main
      command: ["./migrate", "up"]
      weight: "5"              # Secondo

    warm-cache:
      fromDeployment: main
      command: ["./warm-cache.sh"]
      weight: "10"             # Terzo
```

Helm esegue gli hook nello stesso tipo in ordine crescente di weight. Il ServiceAccount viene sempre creato con weight-5 rispetto al Job (es. SA weight 5, Job weight 10) per garantire l'ordine corretto.

### 8.7 CronJob root-level con fromDeployment

```yaml
deployments:
  backend:
    image:
      repository: myapp/backend
      tag: v2.0

cronJobs:
  db-backup:
    schedule: "0 2 * * *"
    fromDeployment: backend       # Copia l'immagine da deployments.backend
    command: ["./backup.sh"]
    envFromConfigMaps:
      - backup-config             # ConfigMap esterno
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
```

`fromDeployment` copia solo l'immagine. Il CronJob root-level **non eredita** ConfigMap, Secret, SA o scheduling dal deployment referenziato.

---

## 9. Funzionalità Avanzate

### 9.1 PodDisruptionBudget

Il PDB garantisce una disponibilità minima durante le operazioni di manutenzione (drain nodi, aggiornamenti):

```yaml
deployments:
  backend:
    image: myapp:v2
    replicaCount: 3
    pdb:
      enabled: true
      minAvailable: 2          # Almeno 2 pod disponibili durante drain
      # maxUnavailable: 1      # Alternativa: al massimo 1 pod non disponibile
```

**Regole:**
- `minAvailable` e `maxUnavailable` sono mutuamente esclusivi
- Almeno uno dei due deve essere specificato se `pdb.enabled: true`
- Entrambi accettano interi o percentuali (`"50%"`)
- `minAvailable: 0` è un valore valido (nessuna garanzia, ma il PDB esiste)

### 9.2 Horizontal Pod Autoscaler

```yaml
deployments:
  api:
    image: myapp:v2
    replicaCount: 2
    autoscaling:
      enabled: true
      minReplicas: 2            # Obbligatorio
      maxReplicas: 20           # Obbligatorio
      targetCPUUtilizationPercentage: 60
      targetMemoryUtilizationPercentage: 80
      behavior:
        scaleUp:
          stabilizationWindowSeconds: 60
          policies:
            - type: Percent
              value: 100
              periodSeconds: 60
        scaleDown:
          stabilizationWindowSeconds: 300
          policies:
            - type: Percent
              value: 30
              periodSeconds: 60
```

Quando `autoscaling.enabled: true`, il campo `spec.replicas` viene omesso dal Deployment — lasciando l'HPA come unico responsabile del numero di repliche.

L'HPA usa l'API `autoscaling/v2` e supporta metriche CPU e memoria. Richiede che il cluster abbia il Metrics Server installato.

### 9.3 NetworkPolicy

```yaml
deployments:
  backend:
    image: myapp:v2
    networkPolicy:
      enabled: true
      policyTypes:
        - Ingress
        - Egress
      ingress:
        - from:
            - namespaceSelector:
                matchLabels:
                  kubernetes.io/metadata.name: frontend-ns
            - podSelector:
                matchLabels:
                  app.kubernetes.io/component: frontend
          ports:
            - port: 3000
              protocol: TCP
      egress:
        - to:
            - namespaceSelector:
                matchLabels:
                  kubernetes.io/metadata.name: database-ns
          ports:
            - port: 5432
              protocol: TCP
        - to:                    # Permette DNS
            - namespaceSelector: {}
          ports:
            - port: 53
              protocol: UDP
```

**Regole di validazione:**
- Se `policyTypes` è fornito, viene usato as-is (permette policy vuote intenzionali)
- Se solo `ingress` o `egress` sono presenti, `policyTypes` viene derivato automaticamente
- Se nessuno dei tre è presente, il render fallisce

### 9.4 ExternalSecrets

Richiede l'External Secrets Operator installato nel cluster:

```yaml
externalSecrets:
  database-credentials:
    secretkey: password              # Chiave nel Secret Kubernetes generato
    remote:
      key: "prod/database"           # Path nel vault remoto
      conversionStrategy: Default
      decodingStrategy: None
    secretstore:
      kind: ClusterSecretStore       # O SecretStore (namespaced)
      name: vault-backend
    refreshInterval: "1h"
    target:
      name: "my-db-secret"           # Default: {fullname}-database-credentials
      creationPolicy: Owner
      deletionPolicy: Retain
```

### 9.5 Mounted ConfigFiles

Permette di montare file di configurazione come ConfigMap dentro i pod, con due modalità:

**Mode `files` — ConfigMap singoli:**
```yaml
deployments:
  nginx:
    image: nginx:1.25
    mountedConfigFiles:
      files:
        - name: nginx-conf            # Identificatore univoco
          filename: nginx.conf        # Nome del file nel ConfigMap
          targetPath: /etc/nginx/nginx.conf  # Percorso nel container
          content: |
            worker_processes auto;
            events { worker_connections 1024; }
            http { server { listen 8080; } }
```

Genera un ConfigMap `{fullname}-md-cm-nginx-conf` e un volumeMount con `subPath: nginx.conf`.

**Mode `bundles` — Proiezioni multi-file:**
```yaml
deployments:
  app:
    image: myapp:v1
    mountedConfigFiles:
      bundles:
        - mountDir: /etc/app/certs    # Directory di montaggio
          files:
            - name: tls-cert
              relPath: tls.crt        # Percorso relativo nella directory
              content: |
                -----BEGIN CERTIFICATE-----
                ...
            - name: tls-key
              relPath: tls.key
              content: |
                -----BEGIN PRIVATE KEY-----
                ...
```

Genera un ConfigMap per ogni file del bundle, poi usa un volume `projected` per montarli tutti nella stessa directory.

### 9.6 RBAC

```yaml
rbacs:
  roles:
    # Role con SA dedicato (creato da questo chart)
    - name: job-manager
      serviceAccount:
        name: job-manager-sa
        create: true
        automount: true
        annotations:
          iam.gke.io/gcp-service-account: job-manager@project.iam.gserviceaccount.com
      rules:
        - apiGroups: ["batch"]
          resources: ["jobs"]
          verbs: ["get", "list", "watch", "create", "delete"]

    # Role legato a SA esistente (non creato da questo chart)
    - name: reader-role
      serviceAccount:
        name: existing-reader-sa
        create: false
      rules:
        - apiGroups: [""]
          resources: ["pods", "pods/log"]
          verbs: ["get", "list"]
```

Il nome del RoleBinding viene derivato dal nome del Role, rimuovendo il suffisso `-role` se presente (es. `job-manager-role` → `job-manager-rolebinding`).

### 9.7 Variabili d'ambiente — Diverse fonti

I pod di un deployment possono ricevere variabili d'ambiente da quattro fonti diverse, tutte cumulabili:

```yaml
deployments:
  app:
    image: myapp:v1

    # 1. ConfigMap generato (key/value → envFrom configMapRef)
    configMap:
      APP_ENV: production
      LOG_LEVEL: info

    # 2. Secret generato (key/value → envFrom secretRef, base64 automatico)
    secret:
      DB_PASSWORD: mysecretpassword
      API_KEY: myapikey

    # 3. ConfigMap/Secret esistenti (envFrom)
    envFromConfigMaps:
      - shared-app-config
      - feature-flags
    envFromSecrets:
      - shared-secrets

    # 4. Variabili native Kubernetes (env[])
    additionalEnvs:
      - name: POD_NAME
        valueFrom:
          fieldRef:
            fieldPath: metadata.name
      - name: NODE_NAME
        valueFrom:
          fieldRef:
            fieldPath: spec.nodeName
      - name: FROM_SECRET
        valueFrom:
          secretKeyRef:
            name: my-secret
            key: value
```

### 9.8 Global imageRegistry con esempi

```yaml
global:
  imageRegistry: "registry.mycompany.com"

deployments:
  app:
    image: myorg/myapp:v1
    # → registry.mycompany.com/myorg/myapp:v1

  nginx:
    image: nginx:1.25
    # → registry.mycompany.com/nginx:1.25

  external:
    image: docker.io/library/nginx:1.25
    # → docker.io/library/nginx:1.25  (invariato: primo segmento "docker.io" contiene ".")

  localhost-registry:
    image: localhost:5000/myapp:v1
    # → localhost:5000/myapp:v1  (invariato: primo segmento è "localhost")
```

---

## 10. Design Pattern e Insidie

### 10.1 hasKey vs. default — Il problema dei valori falsy

**Il problema fondamentale:**

In Go template, sia `false` che `0` che `{}` che `[]` sono valori falsy. La funzione `default` sostituisce un valore con quello di default se il valore è falsy:

```
{{ default true $var }}  # Se $var = false → restituisce true (SBAGLIATO!)
{{ default 0 $var }}     # Se $var = 0 → restituisce 0 (corretto per caso)
```

Questo crea un problema quando un campo booleano di default è `true` ma l'utente vuole impostarlo a `false`: `default true false` restituisce `true`, ignorando la scelta dell'utente.

**La soluzione — hasKey + ternary:**

```
{{- $create := ternary $sa.create true (hasKey $sa "create") -}}
```

Traduzione: "se la chiave `create` esiste nella mappa `$sa`, usa `$sa.create`; altrimenti usa `true`".

Questo distingue correttamente tre stati:
- Chiave assente: usa il default (`true`)
- Chiave presente = `true`: usa `true`
- Chiave presente = `false`: usa `false`

**Esempi nel codebase:**

```
# serviceaccount.yaml — create default true
{{- $create := ternary $sa.create true (hasKey $sa "create") -}}

# deploymentEnabled helper
{{- define "global-chart.deploymentEnabled" -}}
{{- ternary .deploy.enabled true (hasKey .deploy "enabled") -}}
{{- end }}

# service.yaml — service enabled default true
{{- if and (hasKey $svc "enabled") (not $svc.enabled) }}
{{- $svcEnabled = false }}
{{- end }}
```

### 10.2 hasKey per l'inheritance dell'ereditarietà

**Il problema:**
```yaml
deployments:
  backend:
    nodeSelector:
      disktype: ssd
    cronJobs:
      cleanup:
        nodeSelector: {}    # Intende: "nessun nodeSelector"
```

Se si usasse `if not $job.nodeSelector` (pattern sbagliato), un `nodeSelector: {}` (dizionario vuoto, falsy) verrebbe trattato come "non impostato" e il valore del deployment verrebbe ereditato — non quello voluto.

**La soluzione corretta:**
```
{{- $nodeSelector := ternary $job.nodeSelector $deploy.nodeSelector (hasKey $job "nodeSelector") -}}
```

- Se `nodeSelector` esiste nel job (anche vuoto `{}`): usa il valore del job
- Se `nodeSelector` non esiste nel job: usa il valore del deployment

**Questa regola si applica a:** `nodeSelector`, `tolerations`, `affinity`, `imagePullSecrets`, `podSecurityContext`, `securityContext`, `hostAliases`, `dnsConfig`.

### 10.3 Non mutare .Values durante il rendering

**Il problema:**
```yaml
# SBAGLIATO — muta .Values
{{- $annotations := $ing.annotations -}}
{{- $_ := set $annotations "nginx.ingress.kubernetes.io/ssl-redirect" "true" -}}
```

Le mutazioni di `.Values` durante il rendering si propagano a tutti i template successivi nella stessa invocazione, causando comportamenti imprevedibili e bug difficili da debuggare.

**La soluzione:**
```yaml
# CORRETTO — crea una copia locale
{{- $annotations := deepCopy (default (dict) $ing.annotations) }}
```

`deepCopy` crea una copia profonda del dizionario. Tutte le modifiche avvengono sulla copia locale, non sul valore originale.

### 10.4 Shared helpers e spazi bianchi

I shared helper (`renderImagePullSecrets`, `renderDnsConfig`, `renderResources`) possono restituire una stringa vuota quando non c'è output da produrre. Il pattern corretto per usarli senza generare linee vuote nel manifest è:

```yaml
# CORRETTO
{{- with (include "global-chart.renderImagePullSecrets" $imagePullSecrets) }}
{{- . | nindent 6 }}
{{- end }}

# SBAGLIATO — produce una linea vuota se l'helper restituisce ""
{{ include "global-chart.renderImagePullSecrets" $imagePullSecrets | nindent 6 }}
```

Internamente, gli helper usano `-}}` sul conditional/with per evitare una newline iniziale nell'output:

```
{{- define "global-chart.renderImagePullSecrets" -}}
{{- with . -}}
imagePullSecrets:
  ...
{{- end }}
{{- end }}
```

Il `-}}` dopo `with .` evita che il blocco produca una newline iniziale prima di `imagePullSecrets:`, che `nindent` trasformerebbe in una linea vuota.

### 10.5 Gestione dell'immagine — tag obbligatorio

Se si usa il formato mappa con `repository`, è obbligatorio specificare `tag` oppure `digest`:

```yaml
# SBAGLIATO
deployments:
  app:
    image:
      repository: myapp      # Errore al render: "requires either a tag or digest"

# CORRETTO
deployments:
  app:
    image:
      repository: myapp
      tag: v1.0              # oppure digest: sha256:...
```

Il template controlla esplicitamente:
```
{{- if and (kindIs "map" $deploy.image) $deploy.image.repository (not (or $deploy.image.tag $deploy.image.digest)) }}
{{- fail (printf "deployments.%s.image requires either a tag or digest when repository is provided" $name) }}
{{- end }}
```

Un `digest` senza `repository` produce anch'esso un errore nell'helper `imageString`.

### 10.6 Ordine di iterazione della mappa

Go template non garantisce un ordine di iterazione delle mappe. Questo significa che l'ordine dei deployment generati nei manifest può variare tra invocazioni. I checksum delle configurazioni e i nomi delle risorse sono però deterministici.

Questo non è un problema per Kubernetes (le risorse hanno nomi unici), ma può influenzare l'ordine delle risorse negli output di `helm template` o nei diff di `helm diff`.

### 10.7 CronJob — limite 52 caratteri

Il template tronca i nomi dei CronJob a 52 caratteri esplicitamente:

```
{{- $jobFullname := printf "%s-%s" $fullname $name | trunc 52 | trimSuffix "-" }}
```

Se il nome combinato supera 52 caratteri, viene troncato silenziosamente. È responsabilità dell'utente garantire che i nomi risultanti siano unici e leggibili. Per release con nomi lunghi o deployment con nomi lunghi, potrebbe essere necessario abbreviare i nomi dei CronJob.

**Esempio critico:**
```
release = "my-very-long-release-name"  (30 char)
chart   = "global-chart"               (12 char)
cron    = "database-backup-job"        (19 char)
totale  = "my-very-long-release-name-global-chart-database-backup-job" = 60 char → troncato a 52
```

---

## 11. Testing

### 11.1 Struttura dei test

Il repository ha due tipi di test distinti:

**Test di lint (scenari):** file values in `tests/` usati con `helm lint --strict`. Verificano che la configurazione sia valida sintatticamente e semanticamente.

**Test unitari:** suite helm-unittest in `charts/global-chart/tests/`. Verificano asserzioni sul contenuto dei manifest generati.

### 11.2 Scenari di lint

Il Makefile definisce 16 scenari in `TEST_CASES`, ognuno con un file values, un namespace e un identificatore:

| Scenario | File | Descrizione |
|---|---|---|
| `test01` | `tests/test01/values.01.yaml` | Kitchen-sink: autoscaling, volumi, secret, hook, cron, ingress, ExternalSecrets, RBAC |
| `test02` | `tests/values.02.yaml` | SA esistente, service su porta non-standard |
| `test03` | `tests/values.03.yaml` | Chart disabilitato (nessun output) |
| `mountedcm1` | `tests/mountedcm1.yaml` | Mounted ConfigFiles con bundle e legacyvolumi |
| `mountedcm2` | `tests/mountedcm2.yaml` | Mounted ConfigFiles modalità file singolo |
| `cron` | `tests/cron-only.yaml` | Solo CronJob, nessun Deployment |
| `hooks` | `tests/hook-only.yaml` | Solo Hook, nessun Deployment |
| `externalsecret` | `tests/externalsecret-only.yaml` | Solo ExternalSecrets |
| `ingress` | `tests/ingress-custom.yaml` | Ingress con riferimento a deployment |
| `external-ingress` | `tests/external-ingress.yaml` | Ingress con service esterno |
| `rbac` | `tests/rbac.yaml` | RBAC con Role e SA |
| `multi-deployment` | `tests/multi-deployment.yaml` | Multi-deployment completo |
| `service-disabled` | `tests/service-disabled.yaml` | Deployment con service disabilitato |
| `raw-deployment` | `tests/raw-deployment.yaml` | Deployment con immagine stringa |
| `deployment-hooks-cronjobs` | `tests/deployment-hooks-cronjobs.yaml` | Hook/CronJob dentro deployment con inheritance |
| `hooks-sa-inheritance` | `tests/hooks-sa-inheritance.yaml` | SA inheritance per hook dentro deployment |

### 11.3 Suite di unit test

Le 16 suite in `charts/global-chart/tests/` coprono complessivamente 220 test case:

| File | Oggetto testato | Focus principale |
|---|---|---|
| `deployment_test.yaml` | `deployment.yaml` | Enabled flag, immagini, env, volumi, probes, labels, strategy, global values |
| `service_test.yaml` | `service.yaml` | Enabled flag, tipi, porte, selettori |
| `serviceaccount_test.yaml` | `serviceaccount.yaml` | Creazione SA, naming, automount |
| `configmap_test.yaml` | `configmap.yaml` | Generazione, data, encoding booleani/interi |
| `secret_test.yaml` | `secret.yaml` | Generazione, base64, tipi di valore |
| `mounted-configmap_test.yaml` | `mounted-configmap.yaml` | Files e bundles, naming |
| `hpa_test.yaml` | `hpa.yaml` | Enabled, metriche, behavior, minReplicas required |
| `pdb_test.yaml` | `pdb.yaml` | Enabled, minAvailable, maxUnavailable, mutua esclusività |
| `networkpolicy_test.yaml` | `networkpolicy.yaml` | Enabled, policyTypes, regole ingress/egress |
| `ingress_test.yaml` | `ingress.yaml` | Routing deployment, routing service esterno, TLS |
| `cronjob_test.yaml` | `cronjob.yaml` | Root-level, dentro-deployment, inheritance, SA, naming |
| `hook_test.yaml` | `hook.yaml` | Root-level, dentro-deployment, weight, SA inheritance |
| `externalsecret_test.yaml` | `externalsecret.yaml` | Campi obbligatori, naming, defaults |
| `rbac_test.yaml` | `rbac.yaml` | Creazione SA, Role, RoleBinding, binding name |
| `helpers_test.yaml` | `_helpers.tpl` | imageString, imagePullPolicy, fullname, labels |
| `notes_test.yaml` | `NOTES.txt` | Output post-install |

### 11.4 Esecuzione dei test

```bash
# Esegue tutti i test unitari (via Docker)
make unit-test

# Lint di tutti gli scenari (helm lint --strict)
make lint-chart

# Genera manifest per ispezione visiva
make generate-templates

# Esecuzione completa: lint + unit test + genera
make all
```

Il target `unit-test` usa Docker e l'immagine `helmunittest/helm-unittest:3.19.0-1.0.3`. Non è necessario installare il plugin helm-unittest localmente.

### 11.5 Struttura di un test unitario

```yaml
suite: deployment template tests
templates:
  - templates/deployment.yaml
tests:
  - it: should render deployment when enabled is true
    set:                              # Override di values per questo test
      deployments:
        main:
          enabled: true
          image: nginx:1.25
    release:                          # Metadati della release simulata
      name: myrelease
    asserts:
      - hasDocuments:
          count: 1
      - equal:
          path: metadata.name
          value: myrelease-global-chart-main
      - isSubset:
          path: spec.selector.matchLabels
          content:
            app.kubernetes.io/component: main
```

### 11.6 Aggiungere un nuovo test

1. Identificare il template da testare
2. Aggiungere un test case al file `_test.yaml` corrispondente
3. Usare asserzioni appropriate:
   - `hasDocuments: { count: N }` — conta i documenti generati
   - `equal: { path: ..., value: ... }` — confronto esatto
   - `isSubset: { path: ..., content: ... }` — subset di un oggetto
   - `contains: { path: ..., content: ... }` — elemento in una lista
   - `isNull: { path: ... }` — campo assente o null
   - `notExists: { path: ... }` — campo non presente
   - `isKind: { of: Deployment }` — tipo del documento
   - `failedTemplate: { errorMessage: ... }` — attende un errore

4. Aggiungere il corrispondente scenario di lint in `tests/` se necessario
5. Aggiornare `TEST_CASES` nel Makefile se è stato aggiunto un nuovo scenario
6. Eseguire `make lint-chart && make unit-test`

---

## 12. CI/CD

### 12.1 Pipeline CI (helm-ci.yml)

La pipeline CI si esegue su ogni push a `main` e su ogni Pull Request.

```yaml
jobs:
  lint-and-test:
    steps:
      - Checkout
      - Set up Helm v3.19.0
      - Lint chart scenarios       # make lint-chart
      - Run unit tests             # make unit-test (Docker)
      - Generate manifests         # make generate-templates
      - Upload generated-manifests # Artifact disponibile per ispezione
```

**Artifact generato:** I manifest renderizzati per tutti gli scenari sono disponibili come artifact GitHub Actions dopo ogni CI run. Questo permette di ispezionare l'output del chart senza dover eseguire `helm template` localmente.

### 12.2 Pipeline di Release (release.yml)

La pipeline di release si esegue su ogni push a `main` e usa `helm/chart-releaser-action` per automatizzare la pubblicazione.

```yaml
jobs:
  release:
    steps:
      - Checkout (con full history: fetch-depth 0)
      - Configure Git
      - Run chart-releaser         # Skip se la versione esiste già
```

`chart-releaser` funziona così:
1. Cerca il `Chart.yaml` nella directory `charts/`
2. Se la versione nel `Chart.yaml` non ha già un GitHub Release corrispondente, crea:
   - Un GitHub Release con il tag `global-chart-{version}`
   - Un pacchetto `.tgz` del chart allegato al release
   - Aggiorna il branch `gh-pages` con l'`index.yaml` del repository Helm

La flag `skip_existing: true` permette push multipli su `main` senza dover incrementare la versione ogni volta (utile per modifiche alla documentazione o al CI senza cambiamenti al chart).

### 12.3 Processo di rilascio manuale

Per rilasciare una nuova versione:

1. Incrementare `version` in `charts/global-chart/Chart.yaml` (SemVer)
2. Aggiornare `CHANGELOG.md` con le modifiche
3. Eseguire `make all` per verificare che tutto passi
4. Committare e fare push su `main`
5. La pipeline di release gestisce automaticamente il tag e la pubblicazione

```bash
# Verifica pre-release
make all

# Commit
git add charts/global-chart/Chart.yaml CHANGELOG.md
git commit -m "chore: bump chart version to X.Y.Z"
git push origin main
```

---

## 13. Contribuire

### 13.1 Workflow di sviluppo

```bash
# 1. Clone e setup
git clone https://github.com/filippomerante/global-chart
cd global-chart

# 2. Sviluppo di una nuova funzionalità
# Modificare templates/ o values.yaml

# 3. Verificare il lint
make lint-chart

# 4. Verificare i test unitari
make unit-test

# 5. Ispezionare visivamente i manifest
make generate-templates
# Aprire generated-manifests/ per verificare l'output

# 6. Per una singola feature, renderizzare un template specifico
make render VALUES=tests/test01/values.01.yaml TEMPLATE=deployment.yaml

# 7. Installare su cluster di test (richiede accesso a un cluster)
make install SCENARIO=multi-deployment
```

### 13.2 Convenzioni del codice template

**Variabili:**
- Usa `$root := .` all'inizio del template per mantenere il contesto root dopo un `range`
- Usa `$labelCtx := dict "root" $root "deploymentName" $name` per passare il contesto agli helper

**Accesso a campi opzionali annidati:**
```yaml
# CORRETTO — evita nil pointer
{{- $sa := default (dict) $deploy.serviceAccount }}
{{- $autoscaling := default (dict) $deploy.autoscaling }}

# SBAGLIATO — $deploy.serviceAccount potrebbe essere nil
{{- $create := $deploy.serviceAccount.create }}
```

**Booleani con default true:**
```yaml
# CORRETTO
{{- $create := ternary $sa.create true (hasKey $sa "create") -}}

# SBAGLIATO — ignora false esplicito
{{- $create := default true $sa.create -}}
```

**Ereditarietà con override:**
```yaml
# CORRETTO — distingue "non impostato" da "impostato a vuoto"
{{- $nodeSelector := ternary $job.nodeSelector $deploy.nodeSelector (hasKey $job "nodeSelector") -}}

# SBAGLIATO — tratta {} come "non impostato"
{{- $nodeSelector := $job.nodeSelector | default $deploy.nodeSelector -}}
```

**Shared helpers:**
```yaml
# CORRETTO — evita linee vuote
{{- with (include "global-chart.renderImagePullSecrets" $list) }}
{{- . | nindent 6 }}
{{- end }}

# SBAGLIATO — produce linea vuota se stringa è ""
{{ include "global-chart.renderImagePullSecrets" $list | nindent 6 }}
```

### 13.3 Aggiunta di un nuovo template

Per aggiungere un nuovo tipo di risorsa al chart:

1. Creare `charts/global-chart/templates/<nome>.yaml`
2. Seguire il pattern di iterazione standard con doppio guard
3. Aggiungere gli helper necessari in `_helpers.tpl`
4. Creare `charts/global-chart/tests/<nome>_test.yaml` con le suite di test
5. Aggiungere uno scenario di lint in `tests/` se necessario
6. Aggiornare `TEST_CASES` nel Makefile
7. Documentare i nuovi valori in `values.yaml` con commenti `# --`
8. Aggiornare questo documento e `CLAUDE.md`

### 13.4 Aggiunta di un helper condiviso

1. Aggiungere il `define` in `_helpers.tpl`
2. Documentare il contratto (Input/Output) nel commento del helper
3. Verificare la gestione dei valori nil/vuoti
4. Se l'helper può restituire stringa vuota, documentare l'uso con `{{- with }}`
5. Aggiungere test in `helpers_test.yaml`

### 13.5 Aggiunta di ereditarietà a CronJob/Hook

Quando si aggiunge un nuovo campo da ereditare dai deployment-level CronJob/Hook:

1. Aggiungere il campo al template con pattern `hasKey` + `ternary`:
   ```
   {{- $field := ternary $job.field $deploy.field (hasKey $job "field") -}}
   ```
2. Aggiungere test che verifichino: a) ereditarietà quando il campo è assente nel job, b) override quando il campo è presente nel job, c) override con valore vuoto
3. Aggiornare la documentazione in questa sezione e in `CLAUDE.md`

---

## 14. Changelog e Migrazione

### 14.1 Versione 1.3.0 (2026-03-13)

#### Nuove funzionalità

- **PodDisruptionBudget** — `pdb.yaml`, attivabile per deployment con `pdb.enabled: true`
- **NetworkPolicy** — `networkpolicy.yaml`, attivabile con `networkPolicy.enabled: true`
- **Helm test** — `helm test <release>` verifica la connettività al primo service attivo
- **Deployment strategy** — `strategy`, `revisionHistoryLimit`, `progressDeadlineSeconds`, `topologySpreadConstraints`
- **Global values** — `global.imageRegistry` e `global.imagePullSecrets`
- **Native volume spec** — I volumi accettano spec nativa Kubernetes oltre al formato legacy `.type`
- **Configurable default resources** — Sezione `defaults.resources` in values.yaml
- **Secret checksum** — Annotation `checksum/secret` per restart automatico
- **hostAliases e dnsConfig per CronJob root-level** — Parità con deployment-level
- **dnsConfig per Hook root-level** — Parità

#### Fix

- Inheritance CronJob/Hook deployment-level: valori vuoti espliciti (`nodeSelector: {}`, `tolerations: []`, ecc.) ora sovrascrivono correttamente l'ereditarietà
- Field `resources` non più renderizzato come `resources: null` se non specificato

#### Migrazione da 1.2.x

**Attenzione:** L'upgrade causerà un rolling restart dei pod nella prima applicazione (nuovi annotation nel pod template).

1. **Rolling restart previsto:** La nuova annotation `checksum/secret` e i nuovi label `app.kubernetes.io/version` cambiano il pod template spec, causando un restart. Pianificare la manutenzione.

2. **Fix inheritance CronJob/Hook (potenziale breaking change):** Se si usano deployment-level CronJob/Hook con campi esplicitamente vuoti (`nodeSelector: {}`) mentre il deployment parent ha valori per quegli stessi campi, il comportamento cambia. In 1.2.x il campo vuoto veniva ignorato e il valore del parent ereditato; in 1.3.0 il campo vuoto sovrascrive correttamente. Verificare i propri valori.

3. **Default resources ora configurabili:** Se `defaults` viene completamente sovrascritto senza includere `resources`, i CronJob/Hook senza risorse esplicite non avranno resource requests. Verificare che `defaults.resources` sia impostato se necessario.

**Checklist di migrazione:**
- [ ] Ispezionare deployment-level CronJob/Hook per campi vuoti che potrebbero cambiare comportamento
- [ ] Pianificare la finestra di manutenzione per il rolling restart
- [ ] Eseguire `helm diff upgrade` prima di applicare
- [ ] Verificare che `defaults.resources` sia configurato se necessario

### 14.2 Versione 1.2.1 (2026-03-05)

- Aggiunto flag `enabled` su tutti i template (deployment, service, serviceaccount, hpa, configmap, secret, mounted-configmap, cronjob, hook, NOTES.txt)

### 14.3 Versione 1.2.0 (2026-03-04)

- Test suite completa: 14 suite, 174 test
- Miglioramenti ai template e al Makefile

### 14.4 Versione 1.1.0 (2026-02-28)

- Aggiornamento gestione ServiceAccount

### 14.5 Versione 1.0.0 (2026-02-15)

- Rilascio iniziale con supporto multi-deployment
- Deployment, Service, Ingress, CronJob, Hook, ExternalSecret, RBAC
- Pattern di ereditarietà per Hook/CronJob a livello deployment

---

## 15. Appendice — Glossario

**affinity:** Regola di scheduling Kubernetes che specifica preferenze o requisiti di co-localizzazione/anti-co-localizzazione dei pod rispetto ad altri pod o nodi.

**autoscaling (HPA):** HorizontalPodAutoscaler — risorsa Kubernetes che scala automaticamente il numero di repliche di un Deployment in base a metriche (CPU, memoria, custom).

**checksum:** Hash SHA256 del contenuto di una configurazione. Usato come annotation del pod per forzare un rolling restart quando la configurazione cambia.

**CronJob:** Risorsa Kubernetes che crea Job periodicamente secondo uno schedule cron.

**deepCopy:** Funzione Helm template che crea una copia profonda di un oggetto, evitando che le modifiche sulla copia si propaghino all'originale.

**deployment:** Risorsa Kubernetes che gestisce un insieme di pod identici (ReplicaSet), garantendo un numero desiderato di repliche in esecuzione.

**ExternalSecret:** CRD dell'External Secrets Operator che sincronizza segreti da vault esterni (AWS Secrets Manager, HashiCorp Vault, GCP Secret Manager) in Secret Kubernetes nativi.

**fromDeployment:** Campo di CronJob e Hook root-level che indica da quale deployment copiare l'immagine.

**hasKey:** Funzione Go template/Sprig che verifica se una chiave esiste in una mappa, indipendentemente dal valore (anche `false` o `0` o `{}`).

**helm-docs:** Tool che genera automaticamente la documentazione del chart dai commenti `# --` in `values.yaml`.

**helm-unittest:** Framework di test per chart Helm che permette di scrivere asserzioni sui manifest generati.

**Hook:** Job Kubernetes con annotation Helm (`helm.sh/hook`) che viene eseguito in momenti specifici del ciclo di vita Helm (install, upgrade, delete, ecc.).

**inheritance model:** Pattern per cui Hook e CronJob definiti dentro un deployment ereditano automaticamente configurazioni dal parent (immagine, env, SA, scheduling).

**mounted-configmap:** ConfigMap il cui contenuto viene montato come file nel filesystem del container (a differenza dei ConfigMap usati come `envFrom`).

**multi-deployment:** Pattern che permette di definire più Deployment indipendenti in una singola release Helm, ognuno con le proprie risorse.

**NetworkPolicy:** Risorsa Kubernetes che definisce le regole di traffico di rete tra pod e tra pod e endpoint esterni.

**nindent:** Funzione Helm template che aggiunge indentazione (N spazi) all'inizio di ogni riga di una stringa multi-riga.

**PDB (PodDisruptionBudget):** Risorsa Kubernetes che garantisce un numero minimo di pod disponibili durante operazioni di manutenzione volontarie (drain nodi, aggiornamenti).

**podRecreation:** Campo che aggiunge un annotation timestamp al pod template, forzando un rolling restart ad ogni `helm upgrade` anche senza modifiche alla configurazione.

**projected volume:** Volume Kubernetes che combina più sorgenti (ConfigMap, Secret, ServiceAccount token, downward API) in un'unica directory.

**registry detection:** Algoritmo nell'helper `imageString` che determina se il primo segmento di un'immagine è già un registry (contiene `.` o `:`, o è `localhost`), per decidere se applicare il `global.imageRegistry`.

**RoleBinding:** Risorsa Kubernetes che lega un Role a un Subject (ServiceAccount, User, Group) in un namespace.

**selector labels:** Sottoinsieme di label usato in `selector.matchLabels` di Deployment e Service. Include `app.kubernetes.io/component` per distinguere deployment diversi nella stessa release.

**ServiceAccount:** Identità Kubernetes per i processi che girano nei pod. Usata per l'autenticazione verso l'API server e per l'integrazione con sistemi IAM cloud (IRSA, Workload Identity).

**ternary:** Funzione Sprig con sintassi `ternary trueValue falseValue condition` — equivalente dell'operatore ternario di altri linguaggi.

**toYaml:** Funzione Helm template che serializza un oggetto Go in formato YAML. Con `nindent` produce output correttamente indentato.

**weight (hook):** Numero che determina l'ordine di esecuzione degli hook dello stesso tipo. Hook con weight minore vengono eseguiti prima.

**Workload Identity:** Meccanismo GKE che lega un ServiceAccount Kubernetes a un service account IAM Google Cloud, permettendo ai pod di accedere ai servizi GCP senza chiavi statiche.

---

*Documentazione generata per global-chart v1.3.0 — 2026-03-13*
