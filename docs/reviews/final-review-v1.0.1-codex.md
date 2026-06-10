# ruby-dag v1.0.1 - Final Review (Codex, stile Antirez)

Data: 2026-05-02

Scope deciso:

- `claude-review-v1.0.1.md`
- `codex-review-v1.0.1.md`
- `gemini-review-v1.0.1.md`
- `opencode-deepseek-v4-flash-review-v1.0.1.md`
- `opencode-kimi-k2.6-review-v1.0.1.md`

Esclusi:

- `docs/reviews/opencode-deepseek-v4-flash-review-v1.0.1.md`: duplicato
  byte-per-byte del file DeepSeek in root.
- `REVIEW.md`: fuori repo/versione. Cita `Steps::Exec`, strategie
  `threads/processes`, `FileRead`, `FileWrite`, path sandboxing e bug EINTR:
  nessuno di questi oggetti esiste nel kernel v1.0.1 attuale.

Questa review non e' un compromesso tra agent. E' un verdetto dopo verifica
diretta di codice, contratto, README, test e script locali.

## Verifiche eseguite

Comandi eseguiti:

```bash
bundle exec rake
bundle exec ruby scripts/production_readiness.rb --fast --duration 5 --progress-interval 2
```

Risultati osservati:

- `bundle exec rake`: 515 test, 39885 assertion, 0 failure, 0 error.
- RuboCop/Standard: 129 file, 0 offense.
- YARD: 99.08% documented.
- Production readiness fast probe: PASS dopo 5 secondi.

Verifiche statiche:

- `DAG::VERSION` e' `1.0.1`.
- `ruby-dag.gemspec` richiede Ruby `>= 3.4`.
- Nessuna runtime dependency nel gemspec.
- Runtime `require` in `lib/dag/**`: solo stdlib (`json`, `digest`,
  `securerandom`) piu' `require_relative`.
- Nessun `Thread`, `Ractor`, `Mutex`, `Queue`, `Monitor`,
  `ConditionVariable`, `Process.spawn`, `system`, `attr_accessor` in
  `lib/dag/**`.
- `Event::TYPES` e `CONTRACT.md` sono allineati: 10 eventi, non 13.

## Verdetto

`ruby-dag` v1.0.1 e' un kernel serio: piccolo per scelta, deterministico,
zero runtime deps, con boundary atomici espliciti e test migliori della media
di una gem di questa dimensione.

Non e' perfetto. Le review migliori hanno trovato debito reale. Le review
peggiori hanno confuso preferenze estetiche con bug, o hanno recensito file
che non appartengono a questa codebase.

La frase corta e':

> Buon kernel. Nessuna riscrittura. Correggere la narrazione, stringere alcune
> validazioni pubbliche, gestire un dead-end operativo sugli effetti, e tenere
> a dieta il port storage.

## Vision: cosa regge e cosa no

### Zero dipendenze esterne

Confermato.

La gem non ha runtime dependency esterne. Gli adapter stdlib usano solo
`json`, `digest` e `securerandom`. Questo e' coerente con README e gemspec.

Verdetto: vero. Non trasformarlo in religione. SQLite/Postgres/Redis/HTTP
client devono restare fuori dal kernel, negli adapter o nei consumer.

### Monadi

Parzialmente vero.

`DAG::Result` e' una mini-monade legittima su `Success | Failure`:

- `Success` e `Failure` includono `DAG::Result`.
- `Waiting` non lo include, per scelta esplicita.
- `and_then` e `recover` fanno type-check del valore restituito con
  `Result.assert_result!`.
- `tap`, `tap_error`, `map_error`, `value_or` sono esclusi deliberatamente
  per superficie minima.

Questa scelta e' buona Ruby: poca astrazione, contratto chiaro.

Pero' `Effects::Await` non e' una monade. Il commento dice "Monad-like", ma il
codice e' un traduttore di snapshot: legge `input.metadata[:effects]`, ritorna
`Waiting`, `Failure`, oppure passa il risultato a una continuation che deve
ritornare `Success | Waiting | Failure`. Non ha `pure`, `bind` o composizione
diretta `Await -> Await`.

Verdetto: non cambiare il design. Cambiare il vocabolario. Dire:

> `Result` e' una mini-monade Success/Failure. `Waiting` e `Await` sono
> control-flow del runner/effect ledger.

### Tipi immutabili

Confermato ai confini pubblici e nel kernel puro.

`Data.define` e `DAG.frozen_copy` sono usati in modo sistematico. I value
objects validano input JSON-safe dove serve e congelano copie difensive.
`Runner` e' frozen dopo `initialize`.

La mutazione in-place esiste, ma e' confinata in
`DAG::Adapters::Memory::StorageState`, come documentato e come richiesto dal
design del memory adapter.

Verdetto: vero. Non fingere che storage in-memory sia immutabile; il punto e'
che il chiamante non riceve riferimenti mutabili vivi.

### Copy-on-write e concorrenza futura

Parzialmente vero, e il nome e' troppo forte.

`ExecutionContext#merge` e i value boundary non fanno structural sharing vero.
Fanno deep copy + freeze. Questo e' semanticamente immutabile, non CoW in senso
persistente/Clojure/HAMT.

In piu', i value objects frozen aiutano la concorrenza futura, ma non la
risolvono. La concorrenza vera sta nello storage: CAS, transazioni, lease,
retry atomici, effect claim atomici. Il memory adapter e' single-process e non
sincronizzato.

Verdetto: sostituire la narrazione "copy-on-write per concorrenza" con:

> Value objects frozen e copie difensive riducono aliasing e drift. La
> concorrenza multi-process/multi-host richiede adapter storage transazionali.

### Bilanciamento OOP/FP

Vero se detto bene, falso se venduto come "perfetto".

La regola reale e' chiara:

- FP/value style per `Graph` frozen, `Definition`, `ExecutionContext`,
  `Success`, `Failure`, `Waiting`, effetti e eventi.
- OOP per `Runner`, `Dispatcher`, ports, adapters e registry.
- Mutazione confinata dietro storage o builder locali.

Questo non e' caos. E' una divisione pragmatica. Ma "bilanciamento perfetto"
e' marketing.

Verdetto: formulare cosi':

> FP per i dati e le trasformazioni pure; OOP per coordinazione, boundary e
> adapter.

### Ruby idiomatico

Confermato con riserva.

Buono:

- keyword args;
- error class esplicite;
- `Data.define` per value objects;
- no `method_missing`;
- no `Enumerable` ambiguo su `Graph`;
- `each_predecessor` e `each_successor` esistono entrambi;
- `Runner.new` richiede tutti e 7 i port.

Riserva: il pattern `Data.define` + `remove_method :[]` + constructor
keyword-only e' ripetitivo. Non e' un bug. E' boilerplate deliberato per non
introdurre metaprogramming generico.

Verdetto: tenerlo, ma documentare che la duplicazione e' intenzionale finche'
non appare un helper davvero piccolo e non magico.

### DRY

Parzialmente vero.

Vero:

- `DAG::Validation` centralizza molti check.
- `DAG.frozen_copy` evita duplicazione ai boundary.
- storage contract specs evitano drift tra adapter.

Falso o incompleto:

- `storage_overrides?` e' duplicato in `Runner`, `Dispatcher` e
  `MutationService`, non solo in due file.
- `immutable_json_copy` e' duplicato due volte nello stesso
  `effects/dispatcher.rb`.
- il boilerplate dei value object e' ripetuto.

Verdetto: DRY buono dove non nasconde il contratto. Evitare refactor generici
che rendono opachi storage, runner e value validation.

## Claim verificati: accettati

### 1. Il port storage e' diventato il vero centro del sistema

Confermato.

`lib/dag/ports/storage.rb` ha 338 linee e copre workflow row, revisioni, node
states, attempts, event log, resume, retry, mutation CAS, effect ledger,
leasing e query batch dei predecessori.

Questo e' coerente, ma costoso per ogni adapter durevole.

Decisione: non spezzare ora il port. `AGENTS.md` dice che
`lib/dag/ports/storage.rb` e' canonico. Spezzarlo in 4 port e' una migrazione
pubblica, non un refactor innocente.

Soluzione accettata:

- aggiungere una capability matrix documentale: core runner, resume, mutation,
  effects, dispatcher;
- bloccare la crescita del port;
- ogni nuovo metodo storage deve motivare quale finestra di crash/stale-read
  chiude.

### 2. Effect idempotency conflict puo' lasciare il workflow in dead-end

Confermato.

Il contratto dice che `commit_attempt(..., effects:)` deve rollbackare tutto
se la reservation degli effetti fallisce. Lo spec
`spec/support/storage_contract/effects.rb` verifica proprio questo: dopo
`IdempotencyConflictError`, l'attempt resta `:running`, il nodo resta
`:running`, non viene scritto evento, non viene creato link effetto.

Storage-level e' corretto. Runner-level e' ruvido: se uno step deterministico
produce lo stesso `(type, key)` con payload diverso, puo' riprodurre lo stesso
conflitto a ogni resume.

Soluzione accettata per v1.0.2:

- catturare `DAG::Effects::IdempotencyConflictError` nel `Runner` intorno a
  `commit_attempt`;
- convertirlo in failure non retriable di nodo/workflow con evento durabile;
- preservare la garanzia storage di rollback.

Questa e' la proposta piu' importante uscita dalle review.

### 3. Validazione pubblica non uniforme

Confermato.

Esempi reali:

- `RunResult` valida JSON safety di `outcome` e `metadata`, ma non `state` o
  `last_event_seq`.
- `StepInput` valida solo `metadata` JSON-safe, ma non `context`,
  `node_id`, `attempt_number`.
- `Event` valida `type` e `payload`, ma non `workflow_id`, `revision`,
  `seq`, `at_ms`, `node_id`, `attempt_id`.
- `RuntimeProfile` valida `durability`, retry budget e attempt budget, ma non
  `event_bus_kind`.

Il Runner crea questi oggetti correttamente, quindi non e' bug osservato. Ma
sono API pubbliche. Devono rifiutare stati impossibili.

Soluzione accettata:

- aggiungere helper stretti in `DAG::Validation` solo dove ricorrono;
- validare `RunResult.state` contro `%i[completed paused waiting failed]`;
- validare interi non negativi opzionali per `seq`, `last_event_seq`,
  `at_ms`, `attempt_number` dove applicabile;
- validare `StepInput.context` come `DAG::ExecutionContext`;
- decidere se `event_bus_kind` e' enum chiuso o simbolo opaco documentato.

### 4. `Effects::Await` ha un commento falso

Confermato.

Il commento "Monad-like" in `lib/dag/effects/await.rb` non descrive il codice.

Soluzione accettata:

- rinominare la descrizione a "effect snapshot helper" o "effect snapshot
  translator";
- non cambiare API.

### 5. `storage_overrides?` e `immutable_json_copy` sono duplicati

Confermato.

`storage_overrides?` compare in:

- `lib/dag/runner.rb`
- `lib/dag/effects/dispatcher.rb`
- `lib/dag/mutation_service.rb`

`immutable_json_copy` compare due volte nello stesso dispatcher.

Soluzione accettata:

- estrarre un helper piccolo, esplicito, non magico;
- non usarlo come scusa per rendere generica l'interfaccia storage.

### 6. `Memory::StorageState` e' troppo grande

Confermato.

`lib/dag/adapters/memory/storage_state.rb` ha 760 linee e contiene lifecycle,
revision append, attempts, events, effects, lease, retry e validazioni.

Non e' un bug. E' il prezzo di "una sola zona mutabile". Ma sta diventando il
file dove si accumula tutto.

Soluzione accettata, non urgente:

- mantenere il facade `DAG::Adapters::Memory::Storage`;
- mantenere una singola struttura di stato mutabile;
- dividere internamente per dominio quando si tocca lo storage per S0 o per
  una nuova feature sostanziale.

### 7. Production readiness large graph dovrebbe usare il builder

Confermato.

`scripts/production_readiness.rb` costruisce scenari large graph con la API
immutabile chainable. Esiste invece
`DAG::Workflow::Definition::Builder`, dichiarato proprio per costruzioni bulk.

Soluzione accettata:

- aggiornare gli scenari large-graph dello script a usare il builder;
- aggiungere un test semplice di equivalenza builder vs chain API.

### 8. `canonical_committed_attempt` e' una micro-ottimizzazione locale

Confermato, ma non prioritario.

Il metodo manuale nel Runner evita allocazioni, ma rende la lettura piu'
difficile. Memory storage ha gia' una query dedicata
`list_committed_results_for_predecessors`; SQLite farebbe meglio con
`ORDER BY attempt_number DESC, attempt_id DESC LIMIT 1`.

Soluzione accettata solo se si tocca gia' quel codice:

- semplificare il fallback con codice piu' leggibile, oppure spostare la
  scelta canonica nello storage dove possibile.

### 9. `handle_outcome` mescola decisione e side effect

Confermato, ma da trattare con disciplina.

`Runner#handle_outcome` decide stato nodo, tipo evento, payload, retry,
terminal workflow state e valore di controllo del loop. La logica e'
corretta, ma densa.

Soluzione accettata solo con trigger reale:

- estrarre prima una decisione pura piccola, poi applicarla;
- non spezzare il Runner in 5 classi per estetica.

## Claim verificati: respinti o ridimensionati

### 1. "Graph#each_successor non esiste"

Falso.

`Graph#each_successor` esiste accanto a `each_predecessor`. Questo claim viene
da `REVIEW.md`, file escluso perche' fuori repo/versione.

### 2. "CONTRACT.md dice 10 eventi, il codice ne ha 13"

Falso nello stato verificato.

`Event::TYPES` contiene 10 eventi:

- `workflow_started`
- `node_started`
- `node_committed`
- `node_waiting`
- `node_failed`
- `workflow_paused`
- `workflow_waiting`
- `workflow_completed`
- `workflow_failed`
- `mutation_applied`

`CONTRACT.md` contiene la stessa lista.

### 3. "Spezzare subito il port Storage in 4 port"

Respinto per v1.0.1/v1.0.2.

L'idea e' comprensibile: il port e' grande. Ma in questo repo la forma del
port storage e' fonte canonica. Spezzarlo ora significa cambiare contratto,
adapter contract tests, runner, mutation service, dispatcher e documentazione.

La strada giusta e' prima documentare capability e fermare la crescita. Si
valuta lo split solo se un adapter reale prova che il contratto attuale e'
troppo costoso o concettualmente sbagliato.

### 4. "Rendere Waiting parte di Result"

Respinto.

`Waiting` non e' fallimento e non e' successo. E' parcheggio del workflow con
semantica storage/eventi. Metterlo nella monade per ottenere chainability
omogenea renderebbe il codice piu' elegante e meno onesto.

Tenere `Success | Failure` come `Result`, e `Waiting` come outcome separato.

### 5. "Aggiungere value_or/tap/map_error per completare la monade"

Respinto per ora.

Il commento di `DAG::Result` dice che questi metodi sono esclusi per scelta:
non usati dalla libreria o trivially expressible. La superficie piccola e'
una decisione forte, non una mancanza.

Si aggiungono solo quando il codice interno li usa davvero.

### 6. "Eliminare payload_fingerprint/external_ref/not_before_ms dallo snapshot"

Respinto senza cambio di contratto.

`CONTRACT.md` elenca esplicitamente questi campi in
`StepInput.metadata[:effects]`. Non sono lease owner o timestamp storage;
sono parte dello snapshot pubblico stabile. Toglierli sarebbe breaking change.

Se si vuole ridurre lo snapshot, prima si cambia contratto e si spiega perche'.

### 7. "Graph#nodes e' pericoloso perche' cambia object_id"

Ridimensionato.

Il metodo documenta che ritorna uno snapshot frozen. Per grafi non frozen fa
una copia, per grafi frozen puo' restituire il set interno frozen. Il vero
rischio Hash-key e' gia' documentato in `Graph#hash`: non usare un grafo
mutabile come chiave e poi mutarlo.

Non e' una priorita'.

### 8. "Graph fa troppe cose: estrarre subito algoritmi e DOT"

Respinto per ora.

`Graph` ha 696 linee, ma il file e' coeso: struttura DAG, query DAG,
algoritmi DAG e formato DOT minimo. Non c'e' drift verso adapter o runtime.

Estrazione accettabile solo se arrivano altri formati o algoritmi che rendono
il file davvero opaco. Oggi sarebbe refactor estetico.

### 9. "StorageState module_function e' C-style Ruby, sostituire con classi"

Ridimensionato.

La critica di forma ha senso, ma la proposta non e' automaticamente migliore.
Una classe backend con `@state` renderebbe l'OO piu' idiomatico, ma non
ridurrebbe la complessita' delle transizioni. Il problema reale e' la
dimensione del dominio, non il fatto che `state` sia un argomento esplicito.

Prima dividere per dominio; poi decidere se classi o moduli.

### 10. "RuntimeProfile defaults non sono usati dal Runner"

Vero ma non bug.

Il Runner legge il `runtime_profile` del workflow creato nello storage.
`RuntimeProfile.default` e' un convenience per chi crea il workflow, e README
lo dice chiaramente: retry workflow default `0`, opt-in con profilo diverso.

Non serve far applicare default al Runner.

### 11. "DAG.frozen_copy e' insicuro per Set/custom frozen"

Parzialmente vero, ma non e' una falla generalizzata.

`frozen_copy` ritorna oggetti frozen non Hash/Array cosi' come sono. Quindi un
custom object superficialmente frozen potrebbe portare stato interno non
profondamente congelato.

Pero' i payload pubblici JSON-safe non accettano `Set` o oggetti arbitrari.
Il rischio riguarda boundary dove si passano oggetti ricchi, non il normale
payload step/event/effect.

Decisione: non cambiare subito. Documentare meglio il contratto di
`frozen_copy`: e' sicuro per valori JSON-safe e value objects gia' immutabili,
non un freezer universale per oggetti custom.

## Priorita consigliata

### v1.0.2

1. Gestire `DAG::Effects::IdempotencyConflictError` nel Runner come failure
   terminale non retriable con evento durabile.
2. Stringere la validazione dei value object pubblici: `RunResult`,
   `StepInput`, `Event`, `RuntimeProfile`.
3. Correggere la narrazione: `Await` non e' monade; CoW e' deep-copy/freeze,
   non structural sharing; concorrenza futura dipende dallo storage.
4. Usare `Definition::Builder` negli scenari large graph di
   `scripts/production_readiness.rb`.
5. Eliminare o quarantinare `REVIEW.md`, perche' induce agent e umani a
   recensire un progetto diverso.

### Debito piccolo

1. Estrarre `storage_overrides?` in helper condiviso.
2. Estrarre `immutable_json_copy` dal dispatcher.
3. Validare `RunResult.state` con enum chiuso.
4. Documentare il boilerplate `Data.define` come duplicazione intenzionale.
5. Semplificare `canonical_committed_attempt` solo quando si tocca il Runner.

### Dopo v1.0.2 / prima di S0 durable adapter

1. Capability matrix del port storage.
2. Split interno di `Memory::StorageState` per dominio, senza cambiare facade.
3. Revisione del contratto storage solo dopo feedback da un adapter reale.
4. Eventuale separazione decisione/applicazione in `Runner#handle_outcome`.

## Cosa non fare

- Non riscrivere il Runner ora solo per portarlo da 497 a 200 linee.
- Non spezzare il port storage per estetica.
- Non trasformare Ruby in Haskell aggiungendo una monade a 3 stati.
- Non sostituire il boilerplate esplicito dei value object con
  metaprogramming generico.
- Non ottimizzare `Graph#add_edge` finche' il target resta "tens to low
  thousands of nodes". Il costo O(V+E) e' documentato e accettabile.

## Valutazione dei cinque input

### Claude review

La piu' utile sul piano semantico. Corretta su:

- `Result` vero solo per `Success | Failure`;
- `Await` non monade;
- CoW/concorrenza sovradichiarati;
- boilerplate value object;
- `RunResult.state` non validato;
- `canonical_committed_attempt` troppo ottimizzato;
- `handle_outcome` denso;
- `StorageState` grande;
- `REVIEW.md` fuori repo.

Da respingere o modificare:

- filtrare `Record#to_snapshot` rimuovendo campi gia' presenti nel contratto;
- promuovere immediatamente alcuni fallback storage a port-required senza
  passare da capability/contract review.

### Codex review

La piu' bilanciata sul rischio operativo. Corretta su:

- storage port come centro reale;
- idempotency conflict come dead-end operativo;
- validazione pubblica non uniforme;
- `StorageState` grande;
- builder non usato negli scenari large graph;
- review artifact obsoleti.

E' la base piu' solida per v1.0.2.

### DeepSeek review

Buona sui componenti, ma con alcuni errori.

Corretta su:

- zero deps;
- monadi parziali;
- CoW come deep-copy/freeze;
- Runner e StorageState grandi;
- duplicazione `immutable_json_copy`;
- test suite forte;
- non refactorare Runner senza trigger.

Da correggere:

- `storage_overrides?` non e' solo in due file: e' anche in
  `MutationService`;
- event types count e' falso nello stato verificato;
- alcuni giudizi numerici sono opinioni, non finding.

### Kimi review

Utile come stress test, non come piano.

Corretta su:

- zero deps ha costo prestazionale;
- Waiting non e' monade;
- CoW e' nome impreciso;
- storage port grande;
- `to_dot`/algoritmi Graph sono potenziali candidati futuri se il file cresce.

Da respingere:

- rendere `Waiting` un `Result`;
- aggiungere monadic vocabulary non usato;
- spezzare subito storage port;
- chiamare anti-idiomatico ogni `Data.define` validato;
- trasformare StorageState in classi come soluzione primaria.

### Gemini review

Alta quota, poca verifica puntuale.

Corretta su:

- effect intents come split buono tra dichiarazione ed esecuzione;
- CoW/deep_freeze ha costo GC potenziale;
- storage contract e' pesante per adapter durevoli;
- `Graph#add_edge` O(V+E) e' pragmatico e non va ottimizzato ora.

Da ridimensionare:

- "Runner funzione pura" e' troppo generoso: Runner coordina storage e event
  bus, quindi e' orchestratore OOP frozen, non funzione pura;
- "OOP/FP perfetto" e' marketing;
- OCC generico al posto delle atomic boundaries attuali e' una proposta
  architetturale grande, non patch-level.

## Giudizio finale

Questo progetto non ha bisogno di una riscrittura. Ha bisogno di onesta'
lessicale e di pochi fix mirati.

La parte migliore non e' "monadi", non e' "FP", non e' "architettura
perfetta". La parte migliore e':

- il kernel non crea thread;
- i port sono espliciti;
- le transizioni che devono essere atomiche sono nominate;
- gli eventi terminali sono legati allo storage;
- gli effect intent sono astratti e durevoli;
- i test non sono decorazione.

La parte piu' fragile e' la crescita del contratto storage. Non perche' sia
sbagliato, ma perche' ogni nuovo metodo atomico diventa tassa permanente per
ogni adapter futuro.

Stato realistico:

> production-ready alpha per workflow deterministici single-process e per
> consumer che accettano il contratto storage attuale. Non ancora una piattaforma
> workflow general purpose. Non ancora una storia completa di concorrenza
> durable multi-process. Ma le fondamenta sono buone.

Antirez-style: taglia le parole grosse, non il codice buono.
