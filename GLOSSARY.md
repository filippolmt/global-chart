# Global-chart

Chart Helm riusabile che fornisce building block Kubernetes multi-deployment. Questo file è solo un glossario: nessun dettaglio implementativo, nessuna decisione di design (quelle stanno in `docs/adr/`).

## Language

**Vendor-neutral**:
Proprietà per cui nessun operator o CRD di terze parti è *obbligatorio* per usare la chart. Le risorse vendor-specific sono ammesse purché opt-in e protette da un capability check che fallisce il render quando il CRD non è registrato. Non significa "solo API Kubernetes core": KEDA ed External Secrets sono già resi dalla chart a queste condizioni. Un'annotazione destinata a un controller esterno non è una risorsa e non ha un CRD da verificare: è ammessa purché opt-in, e senza il controller resta inerte — non rompe niente, ma nemmeno fa niente, e la chart non può accorgersene.
_Avoid_: vendor-agnostic, portabile, neutrale

**Scope root / scope deployment**:
I due luoghi in cui un CronJob o un hook può essere dichiarato. Nello *scope root* il Job è autonomo: non eredita niente e riferisce esplicitamente ciò che gli serve. Nello *scope deployment* il Job appartiene a un Deployment e ne eredita immagine, configurazione, ServiceAccount e collocazione sul cluster, salvo override. La collocazione è dove e con quale precedenza il pod viene schedulato: i nodi che può occupare e la priorità con cui li contende agli altri pod. Lo scope dice da dove arrivano i valori, mai quale regola li interpreta: una regola che cambia risultato a seconda dello scope è un difetto, non una caratteristica.
_Avoid_: top-level, standalone (per lo scope root, quando il contrasto è con lo scope deployment), nested

**Ruolo hook**:
Che cosa una risorsa è dentro la sequenza di hook di Helm: il Job da eseguire, il ServiceAccount che lo esegue, o una copia hook-prerequisite. È un asse ortogonale allo scope — lo scope dice da dove arrivano i valori, il ruolo dice quando la risorsa deve esistere rispetto alle altre.
_Avoid_: tipo di hook (è `helm.sh/hook`, cioè la fase: pre-install, post-upgrade…), categoria, kind

**Copia hook-prerequisite**:
Duplicato annotato come hook di una risorsa che il Job di un hook deve trovare già presente. Esiste perché Helm crea le risorse normali solo dopo gli hook, quindi l'originale non c'è ancora quando il Job viene schedulato. Vive solo per la durata della fase di hook, che la fase riesca o fallisca: una copia sopravvissuta a un tentativo fallito è ciò contro cui urta il tentativo successivo. Il contenuto della copia è quello della risorsa reale: la copia differisce solo nei metadata e, quando la risorsa ne produce un'altra, nel nome di ciò che produce e nel fatto di possederlo — ciò che il Job deve trovare è la risorsa prodotta, e i dati che essa risolve restano gli stessi. Possederlo è ciò che la fa sparire insieme alla copia: una copia che scrive in ciò che un'altra risorsa possiede, o che lo lascia dietro di sé, non è più soltanto una copia. Una copia il cui contenuto diverge dall'originale non è una copia — è una seconda risorsa, e la divergenza non si vede, perché nessun manifest diventa invalido.
Una copia non porta mai il nome della risorsa reale: esiste in ogni fase in cui la risorsa reale potrebbe mancare, e in almeno una di quelle fasi la risorsa reale c'è già — uno strumento che rilancia gli hook a ogni sincronizzazione la sovrascriverebbe e poi la cancellerebbe. Il prezzo è l'identità legata al nome: il Job che gira come la copia di un ServiceAccount creato dalla release non ne eredita l'identità esterna.
_Avoid_: copia temporanea, shadow resource, risorsa di appoggio

**ServiceAccount creato dalla release**:
ServiceAccount che la chart stessa crea, per un deployment o per una entry di ruolo, contro quello che la chart si limita a legare perché esiste già fuori dalla release. La distinzione decide se un hook che deve trovarlo prima delle risorse normali gira come la copia o come l'originale: un ServiceAccount creato dalla release si copia, uno esterno si usa così com'è. Chi lo crea non cambia la risposta: la stessa domanda ha una sola risposta per ogni hook, in entrambi gli scope.
_Avoid_: SA gestito, SA della chart, SA interno

**Porta primaria**:
La porta che il Service di un deployment espone quando non se ne dichiarano altre. È l'unica ad avere default propri — numero, nome, protocollo e porta di destinazione esistono anche se nessuno li scrive — mentre ogni porta aggiuntiva va dichiarata per intero. Un default che vale per la porta primaria non vale automaticamente per una porta aggiuntiva, né per la porta di un Service che la chart non crea.
_Avoid_: porta di default, prima porta, porta http

**Livello di routing HTTP**:
Il punto unico della release attraverso cui il traffico HTTP raggiunge i deployment: un Ingress o le route HTTP del Gateway, mai entrambi. Le route HTTP possono essere più d'una — una per hostname o per Gateway — e restano un solo livello: è il tipo di risorsa che conta, non il numero. Uno solo per release, perché due livelli sugli stessi hostname sono due risposte alla stessa domanda, e quale vince lo decide l'infrastruttura, non la chart. Riguarda solo l'HTTP: le route L4 non sono un livello di routing e non competono con lui.
_Avoid_: routing layer (senza "HTTP"), ingress layer, livello di esposizione

**Route L4**:
Route del Gateway che inoltra una porta TCP o UDP a un Service senza interpretarne il protocollo applicativo: niente hostname, niente path, niente header su cui decidere. Esiste per i protocolli che non sono HTTP. Una release può averne quante ne servono, anche su Gateway diversi, e convivono con il livello di routing HTTP perché servono porte diverse. Una route L4 inoltra solo verso una porta dello stesso protocollo: una route TCP verso una porta UDP non è una configurazione insolita ma un errore, perché Kubernetes la accetta e il traffico non arriva mai.
_Avoid_: TCP ingress, stream route, route non-HTTP

**Proprietario delle repliche**:
Ciò che decide quanti pod esegue un Deployment: il Deployment stesso, con il numero fisso che dichiara, oppure un autoscaler — quello che la chart rende, o quello che KEDA deriva per sé. Il proprietario è sempre uno e uno solo. Il Deployment cede il numero solo a un autoscaler che esiste davvero e ha qualcosa da misurare: una configurazione in cui il Deployment rinuncia al numero senza che nessuno lo prenda non è un default ragionevole ma un errore, perché Kubernetes riempie il vuoto con un pod solo e nessuno lo segnala. Allo stesso modo, due autoscaler sullo stesso Deployment non sono una ridondanza ma due proprietari.
_Avoid_: replica owner, chi scala, gestore delle repliche

**Mounted config file**:
File di configurazione il cui contenuto sta nei values e che la chart materializza in un ConfigMap dedicato, montato nel pod del Deployment. Descrive il *runtime del Deployment*: non è configurazione della release né materiale condiviso, e per questo nessun job dello scope deployment lo eredita — un hook di migrazione non è quel runtime. Le due forme in cui si dichiara (file singolo con il suo percorso di destinazione, o bundle montato come directory) sono modi di montarlo, non cose diverse: condividono un solo spazio dei nomi, e due entry con lo stesso nome sono una collisione, non due file.
_Avoid_: file montato, config file, volume di configurazione

**Sorgente osservata**:
Sorgente di configurazione che la chart rende e che il pod di un Deployment legge, la cui modifica deve sostituire i pod. Il confine è ciò che la chart vede: una sorgente che la chart si limita a riferire per nome, o un valore che vive in uno store esterno, non è osservata, e cambiarla non sostituisce niente — serve qualcosa fuori dalla chart. Una sorgente resa ma non osservata è un difetto: la risorsa cambia, i pod no, e gli hook della stessa release, che leggono la copia appena creata, girano con una configurazione diversa da quella dei pod. Osservare una sorgente dice che i pod vengono sostituiti, non che i pod nuovi leggano già il contenuto nuovo: quando a produrre la risorsa è un operator, i pod possono partire prima che l'operator l'abbia aggiornata. La chart può affidare una sorgente che non vede a un controller esterno, dicendogli quali risorse guardare, ma affidata non vuol dire osservata: la chart non sa se il controller esiste né se reagisce.
_Avoid_: checksum, trigger di rollout, config watch

**Chiave nominante**:
Chiave di una mappa dei values, campo che identifica un'entry di una lista, o valore scalare dei values (un override del nome), che diventa parte del nome di qualcosa che Kubernetes o Helm validano: una risorsa, un container, una label, il tipo di un hook. Il suo vincolo è l'insieme di ciò che accetta il punto più stretto in cui finisce, non una regola uniforme più severa: si rifiuta solo ciò che non potrebbe mai essere applicato. Il vincolo è lo stesso nei due scope, anche quando uno dei due tronca e l'altro no, e non dipende da ciò che le sta accanto nei values: aggiungere un hook non deve rendere invalida una chiave che prima era valida. Un override del nome fa eccezione solo in apparenza: nomina la release intera, non una risorsa, quindi il suo punto più stretto è ciò che la release rende davvero, e un valore valido come nome ma non come etichetta si rifiuta solo quando la release rende qualcosa che lo usa come etichetta. Il vicino non cambia il vincolo: cambia ciò che il valore nomina.
_Avoid_: nome della mappa, id, chiave di mappa (quando si intende quella che genera nomi)

**Annotazione comune**:
Annotazione che vale per ogni risorsa che la chart crea, contro l'annotazione per-risorsa che specializza una sola di esse. Le due non sono alternative: quando entrambe nominano la stessa chiave, il valore per-risorsa è quello che conta, sempre e a prescindere dall'ordine in cui le due sorgenti vengono emesse. Una risorsa che le espone come chiavi separate anziché come un valore solo non sta applicando una precedenza — sta rimandando la scelta a chi legge il manifest, e chi legge non è sempre lo stesso.
_Avoid_: annotazione globale, annotazione di default, merge delle annotazioni

**Sorgente d'ambiente**:
Uno dei blocchi da cui un container riceve variabili d'ambiente in massa, contro la singola variabile dichiarata per nome. Le sorgenti di un container sono ordinate e l'ultima vince sulla chiave condivisa, quindi l'ordine è una regola di dominio, non un dettaglio di resa. Il Deployment e i job che lo accompagnano non lo ordinano con lo stesso criterio, e la differenza è voluta: il Deployment ordina **per tipo** — prima tutte le sorgenti non segrete, poi tutte quelle segrete, così che un segreto batta sempre una configurazione in chiaro — mentre un job ordina **per prossimità** — prima ciò che gli arriva dal Deployment, poi ciò che dichiara da sé, così che il dichiarante più vicino vinca. I due criteri non sono conciliabili perché non contano gli stessi livelli: il job ne ha uno in più, il proprio, e ordinarlo per tipo lo farebbe perdere contro una sorgente che non è sua. La differenza si osserva solo su una chiave presente sia in una sorgente segreta sia in una non segreta: altrove i due ordini danno lo stesso ambiente.
_Avoid_: ereditarietà envFrom, precedenza delle env, merge dell'ambiente

**Secret riscritto**:
Un Secret di cui un ExternalSecret riduce i dati ai soli propri, cancellando tutto ciò che non ha scritto lui. Lo fa a ogni refresh, che ne sia proprietario o no. Conta ciò che l'ExternalSecret fa ai dati, non chi possiede il Secret. Un Secret riscritto non può essere anche un Secret che la chart rende: i due scrittori si cancellano a vicenda a ogni upgrade e a ogni refresh, e nessuno dei due se ne accorge. Un ExternalSecret che aggiunge le proprie chiavi e lascia le altre al loro posto non riscrive il Secret, quindi può scrivere in un Secret della chart.
_Avoid_: target posseduto, Secret adottato, conflitto di ownership

**Superficie passthrough**:
Nodo dei values che la chart consegna così com'è a un manifest, la cui forma appartiene a Kubernetes o a un operator e non alla chart. Non è del tutto opaca: la chart può leggerne qualche campo per le proprie regole, e quei campi sono suoi — li dichiara e ne risponde come di ogni altro valore. Il resto non è suo: sa che cosa ci si aspetta di trovarci solo chi possiede la forma, e la forma cambia al ritmo di chi la possiede, non della chart.
_Avoid_: campo libero, sezione raw, blob, pass-through (con il trattino)

**Guard di riserva**:
Controllo della chart che rifiuta un valore già rifiutato dallo schema, e che per questo in condizioni normali non scatta mai. Non è codice morto: quando chi installa salta la validazione dello schema — la via d'uscita prevista quando Kubernetes aggiunge un campo prima che la chart lo conosca — è l'unica protezione rimasta, e il suo messaggio è l'unico che l'utente vede. Una guard di riserva vale quanto la sua verifica: se nessuna prova la fa scattare, non si sa se funziona ancora. Una guard che nemmeno senza schema potrebbe mai scattare, perché la condizione è esclusa altrove nella chart, è invece codice morto.
_Avoid_: guard morta, guard ridondante, controllo duplicato

**Autore dei values**:
Chi scrive i values di una release senza conoscere le regole interne della chart, tipicamente assistito da un LLM. La chart lo guida solo attraverso ciò che rifiuta e ciò che descrive: un errore che non nomina il path, o un campo senza descrizione, per lui non esiste. Un campo in cui la chart accetta qualunque cosa è, per lui, il posto dove spostare ciò che altrove viene rifiutato.
_Avoid_: utente, consumer, sviluppatore (quando si intende chi scrive i values)
