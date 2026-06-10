# ruby-dag v1.0.1 — Revisione Finale (stile Antirez)

> Verifica incrociata di 5 review (Claude, Codex, Gemini, Deepseek-v4-flash, Kimi-k2.6) contro il codice sorgente. Ogni claim è stato controllato su `file:line`. Niente lodi, niente vendite.

---

## 1. Metodologia

Ho letto le 5 review e, per ogni assunzione significativa, ho aperto il file citato. Se il claim non citava un file, ho cercato con `grep`. Se due reviewer si contradicevano, il codice ha arbitrato. Risultato: questa revisione non è una sintesi di opinioni, è un fact-check.

---

## 2. Validazione Vision — punto per punto

### 2.1 Zero dipendenze esterne
**Stato: VERO.** `ruby-dag.gemspec` non dichiara runtime deps. `lib/dag.rb` carica solo file locali. Stdlib (`json`, `securerandom`, `set`) — tutto lì. Uno dei pochi claim che regge al 100%.

### 2.2 Monadi
**Stato: PARZIALE, con marketing.**

- `DAG::Result` su `Success | Failure` è una mini-monade onesta: `and_then`, `map`, `recover`, `assert_result!` (`result.rb:25-57`). Left identity e short-circuit sono rispettati. **Questa parte regge.**
- `Effects::Await` (`await.rb:5`) si proclama "Monad-like step helper". **È falso.** È un dispatcher su 4 stati di uno snapshot con `yield` al continuation. Non c'è `bind`, non c'è `pure`, non si compone con se stesso (`Await ∘ Await` non esiste). È una `if-let` con custodia di tipi. Utile, ma non una monade.
- `Waiting` è **deliberatamente escluso** da `DAG::Result` (`result.rb:4-5`). Scelta architetturale corretta — Waiting è control-flow, non valore — ma cancella metà del claim "monadi".

**Verdetto:** hai un Either monade legittimo. Non chiamarlo "sistema di monadi".

### 2.3 Tipi dati immutabili
**Stato: VERO, con una crepa.**

- `Data.define` ovunque (16+ occorrenze). `frozen_copy` usato disciplinatamente ai confini.
- `DAG.frozen_copy` (`immutability.rb`) assume che se un oggetto è `frozen?` e non è Hash/Array, sia sicuro. È **troppo fiducioso**: un `Set` frozen contenente elementi mutabili passa il controllo. Un oggetto custom con `freeze` superficiale passa. Non è un bug attivo, ma è una crepa nel contratto.
- L'unica zona mutabile è `StorageState` (`storage_state.rb:1-30`), dichiarata esplicitamente come tale. Onesto.

### 2.4 Copy-on-write per concorrenza futura
**Stato: OVERSTATEMENT.**

- CoW su value objects (Definition, Graph, ExecutionContext) è vero: ogni mutazione ritorna una nuova istanza congelata.
- **Ma** `ExecutionContext#merge` (`execution_context.rb:27-29`) fa `deep_dup` + `deep_freeze` dell'intero hash interno. Non è CoW strutturale (persistent data structure), è "copia totale ad ogni step". Per workflow con centinaia di nodi e contesto che cresce, questo **distrugge il GC** (allocazioni a ogni layer).
- Lo stato durabile (`StorageState`) ha read-modify-write senza alcun meccanismo di concorrenza. Il commento in cima dice "single-process" — onesto. Ma "CoW per concorrenza futura" implica un design che **non esiste**.

**Verdetto:** CoW dei value objects è precondizione necessaria, non sufficiente. Lo storage non è preparato per concorrenza. Chiarisci: "frozen value objects safe to share; concurrent storage requires durable adapter (S0)".

### 2.5 Bilanciamento perfetto OOP/FP
**Stato: RETORICA.**

Il codice è **layered**, non bilanciato:
- Value objects → FP puro.
- Result → mini-monade FP.
- Step → classe OOP con `#call`.
- Runner → orchestratore OOP denso (~497 LOC, ~19 metodi privati).
- StorageState → programmazione procedurale C-style (`module_function`, stato passato esplicito).

Non c'è composizione orizzontale tra i layer. Non puoi comporre due Runner. Non puoi comporre due Await. Il "bilanciamento" è "ogni layer sceglie il paradigma comodo".

**Verdetto:** niente di sbagliato, è pragmatismo. Ma chiamarlo "bilanciamento perfetto" è retorica. Più onesto: "FP per i valori, OOP per la coordinazione".

### 2.6 Ruby idiomatico
**Stato: VERO, con eccezioni.**

- Bene: niente `attr_accessor`, niente `method_missing`, `Data.define` ovunque, lazy `enum_for` su Graph, `private_constant`, snake_case.
- Eccezione: il pattern "custom factory `[]`" (`remove_method :[]` + `def [](kw:); new(...); end`) è ripetuto in ~9 file. È un trick per sostituire il costruttore positional di `Data.define` con keyword-only. ~120-200 righe di boilerplate regolare.
- Eccezione: `StorageState` è scritto come C con sintassi Ruby (`module_function`, ogni metodo prende `state` come primo argomento). Anti-idiomatico per Ruby 3.4.

### 2.7 DRY
**Stato: PARZIALE.**

- **Vero:** `Validation` (`validation.rb`, 182 LOC, 14 helper) è centralizzato e usato uniformemente. Ottimo.
- **Falso:** ~9 file ripetono lo stesso scheletro `Data.define` + `remove_method :[]` + `initialize` con validazione. Stima: ~150-200 righe di duplicazione regolare.
- **Falso:** `storage_overrides?` è duplicato in 3 file (`runner.rb:382`, `effects/dispatcher.rb:285`, `mutation_service.rb:76`) — 5 righe identiche per file.
- **Falso:** `immutable_json_copy` è duplicato in 2 classi nello stesso file (`dispatcher.rb:40-44` e `106-110`).

**Verdetto:** DRY per la logica di validazione, sì. DRY per la forma dei value object e per piccoli helper, no.

---

## 3. Verifica assunzioni — claim per claim

### 3.1 `RunResult` non valida `state`
**Reviewer:** Claude, Codex. **Esito: VERO.**
`run_result.rb:27-37` accetta qualsiasi Symbol. Tutti gli altri value object validano gli enum con `Validation.member!`. RunResult no. È costruito solo dal Runner (che passa valori corretti), ma essendo `@api public`, un caller esterno può creare garbage.

### 3.2 `Effects::Await` è "monad-like"
**Reviewer:** Claude, Gemini, Deepseek. **Esito: FALSO.**
`await.rb:5` dice "Monad-like step helper". Non lo è. Vedi §2.2.

### 3.3 `Graph#nodes` cambia object_id tra frozen/unfrozen
**Reviewer:** Kimi. **Esito: VERO.**
`graph.rb:36-37`: `frozen? ? @nodes : @nodes.dup.freeze`. Se usi un Graph come chiave di Hash prima e dopo `freeze`, rompi i bucket. Pericoloso.

### 3.4 `Graph#to_dot` non dovrebbe stare in Graph
**Reviewer:** Kimi. **Esito: DISCUTIBILE.**
`graph.rb:419-436` — ~18 righe. Non è un mostro. Ma se domani vuoi Mermaid, aggiungi un altro metodo? Sì, meglio estrarre un `DAG::Graph::DotFormatter`.

### 3.5 `Graph` gestisce anche shortest/longest/critical path
**Reviewer:** Kimi. **Esito: VERO, ma accettabile.**
696 LOC totali. Gli algoritmi sono ~100-150 righe. Non è un disastro, ma `Graph::Algorithms` come modulo separato sarebbe più pulito.

### 3.6 `canonical_committed_attempt` è ottimizzazione prematura
**Reviewer:** Claude, Deepseek, Kimi. **Esito: VERO.**
`runner.rb:393-412` — loop manuale con 3 variabili per evitare allocazione di un Array intermedio. Per un workflow con 100 nodi e 3 attempts sono ~300 array di 2 elementi. Su un adapter SQLite questa logica dovrebbe essere `ORDER BY attempt_number DESC, attempt_id DESC LIMIT 1`.

```ruby
# Equivalente in 3 righe:
def canonical_committed_attempt(attempts)
  attempts
    .select { |a| a[:state] == :committed }
    .max_by { |a| [a.fetch(:attempt_number), a.fetch(:attempt_id).to_s] }
end
```

### 3.7 `Runner` è troppo lungo / viola SRP
**Reviewer:** Deepseek (6/10), Kimi. **Esito: VERO, ma non urgente.**
497 LOC, ~19 metodi privati. `handle_outcome` (linee 227-265) mescola: decisione stato nodo, tipo evento, payload evento, transizione workflow, ritorno al loop, e IO (commit + event_bus). È denso ma corretto. Spezzarlo in `OutcomeHandler` + `Finalizer` migliorerebbe la testabilità, ma il rischio di regression su 515 test non vale il beneficio estetico se non stai aggiungendo feature.

### 3.8 `StorageState` è C-style Ruby
**Reviewer:** Kimi. **Esito: VERO.**
`storage_state.rb:12-13`: `module StorageState; module_function`. Ogni metodo prende `state` come primo argomento. Nessuna incapsulazione. Una classe `MemoryStorageBackend` con `@state` sarebbe più idiomatica e testabile. Ma: il cop `Dag/NoInPlaceMutation` path-allowlista `lib/dag/adapters/memory/**`, quindi la forma attuale è "legale".

### 3.9 `StorageState` è troppo grande
**Reviewer:** Claude, Codex, Deepseek, Kimi. **Esito: VERO.**
760 LOC. Contiene: workflow lifecycle, revision append, attempts, event log, effect ledger, lease claim/mark, waiting-node release, retry reset. Il commento in cima lo ammette. Split per dominio (Workflow, Node/Attempt, Effect, Event) — 4 file da ~150-200 LOC — è meccanico e a zero rischio.

### 3.10 Storage port è troppo "grasso"
**Reviewer:** Gemini, Codex, Kimi. **Esito: PARZIALE.**
`ports/storage.rb`: ~338 LOC, ~30 metodi. È grande. Ma è **intenzionale**: le operazioni atomiche (es. `prepare_workflow_retry`, `commit_attempt` con `effects`, `transition_workflow_state` con `event`) richiedono che lo storage faccia più cose in una transazione. Spezzare il port in 4 (`WorkflowStorage`, `NodeAttemptStorage`, `EventStorage`, `EffectStorage`) come propone Kimi **romperebbe l'atomicità**: il Runner chiama `commit_attempt` che deve scrivere attempt, nodo, evento, ed effetti nello stesso step. Se il port è spezzato, il Runner dovrebbe fare 4 chiamate, riaprendo la finestra di crash.

**Verdetto:** il port è grasso perché le atomic boundaries sono grasse. Questo è il costo della correttezza. Non spezzare il port. Documenta quali metodi sono richiesti per quali feature (adapter capability matrix).

### 3.11 `storage_overrides?` duplicato
**Reviewer:** Deepseek, Kimi. **Esito: VERO, e sottocontato.**
Non 2 file, **3 file**: `runner.rb:382`, `effects/dispatcher.rb:285`, `mutation_service.rb:76`. Stesse 5 righe identiche. Estrarre in `DAG::Ports::Storage` come helper o in un modulo condiviso richiede 2 minuti.

### 3.12 `immutable_json_copy` duplicato
**Reviewer:** Deepseek. **Esito: VERO.**
2 classi nello stesso file (`dispatcher.rb:40-44` e `106-110`). Stesse 4 righe.

### 3.13 Event types: 9 vs 10 vs 13
**Reviewer:** Deepseek dice 13. **Esito: FALSO — sono 10.**
`event.rb:61-71` elenca 10 tipi (incluso `mutation_applied`). `CONTRACT.md:514-525` elenca gli stessi 10. `CLAUDE.md` ne elenca 9 (dimentica `mutation_applied`). Deepseek ha esagerato.

### 3.14 `REVIEW.md` nella root è di un altro progetto
**Reviewer:** Claude, Codex. **Esito: VERO.**
Parla di `Steps::Exec`, `drain_pipes`, `KILL_GRACE_SECONDS`, `threads.rb`, `processes.rb` — codice che **non esiste** in questo repo. È spillage da un altro progetto. Misleading per chi lo legge prima.

### 3.15 Effect idempotency conflict lascia workflow stuck
**Reviewer:** Codex. **Esito: VERO, e importante.**
Se uno step deterministico riusa lo stesso `(type, key)` con payload diverso, `commit_attempt` fa rollback per `IdempotencyConflictError`. Il nodo resta `:running`, il workflow resta `:running`. Resume → retry → stesso conflitto. Loop infinito operativo. Il Runner non cattura questa eccezione per convertirla in failure terminale.

### 3.16 `RuntimeProfile.default` non usato dal Runner
**Reviewer:** Deepseek. **Esito: VERO.**
`runtime_profile.rb:30-38` definisce `default` con `max_attempts_per_node: 3`, ma il Runner non applica default. Chi crea il workflow deve passare esplicitamente il profilo.

### 3.17 `list_committed_results_for_predecessors` dovrebbe essere required
**Reviewer:** Claude. **Esito: DISCUTIBILE.**
Il default port non lo implementa; il Runner fa fallback O(N×M) query (`runner.rb:353-379`). Il fast-path (`storage_overrides?`) salva su Memory adapter, ma lascia il default port debole. Promuoverlo a required semplificherebbe il Runner, ma obbligherebbe ogni adapter a implementarlo. Trade-off valido.

### 3.18 `Record#to_snapshot` espone campi infrastrutturali
**Reviewer:** Claude. **Esito: VERO.**
`record.rb:5-19` include `payload_fingerprint`, `not_before_ms`, `external_ref` nello snapshot. Questi sono campi di storage/lease. Gli step li vedono in `metadata[:effects]`. Dovrebbero essere filtrati.

---

## 4. Sintesi per componente

| Componente | LOC | Consensus | Problema principale |
|---|---|---|---|
| **Graph** | 696 | Il migliore del progetto (9/10) | `to_dot` e algoritmi path potrebbero essere estratti; `nodes` cambia object_id |
| **Runner** | 497 | Corretto ma troppo denso (6/10) | SRP violato; `handle_outcome` mescola decisione e side-effect; `canonical_committed_attempt` ottimizzazione prematura |
| **StorageState** | 760 | Il rischio più grande (5/10) | C-style procedurale; troppi concern; unico punto di mutazione |
| **Effects subsystem** | ~1078 | Solido (8/10) | 2 DRY violations minori; idempotency conflict non gestito in Runner |
| **Validation** | 182 | Funziona (7/10) | Verboso ma esplicito; non vale il refactoring |
| **Test suite** | ~7000 | Eccellente (9/10) | 515 test, 0 fallimenti; fuzz, crash simulation, fingerprint stability |
| **Ports** | ~338 | Necessariamente grassi | Atomic boundaries richiedono metodi grossi; non spezzare |

---

## 5. Proposte concrete — graduate per costo/beneficio

### 5.1 Basso costo, alto valore (~1h totale)

| # | Cambiamento | File | Motivazione |
|---|---|---|---|
| 1 | Rinomina commento `Await` "Monad-like" → "Effect snapshot dispatcher" | `effects/await.rb:5` | Onestà semantica. 1 minuto. |
| 2 | Aggiungi `Validation.member!(state, RUN_RESULT_STATES)` in `RunResult#initialize` | `run_result.rb:27` | Uniformità con tutti gli altri value object. 3 righe. |
| 3 | Filtra campi infrastrutturali da `Record#to_snapshot` | `effects/record.rb:5-19` | Separa semantica (step) da infra (storage). 4 righe. |
| 4 | Estrai `storage_overrides?` in helper condiviso | `ports/storage.rb` o modulo | Elmina duplicazione in 3 file. 5 minuti. |
| 5 | Elimina duplicazione `immutable_json_copy` | `effects/dispatcher.rb` | Stesso file, 2 classi. 2 minuti. |
| 6 | Sostituisci `canonical_committed_attempt` con `select.max_by` | `runner.rb:393-412` | Leggibilità > micro-perf. 3 righe. |
| 7 | Rimuovi o sposta `REVIEW.md` obsoleto | root | Misleading per future revisioni. 1 minuto. |
| 8 | Documenta in `CLAUDE.md` che il boilerplate Data.define è intenzionale | `CLAUDE.md` | Chiude il falso claim DRY. 5 minuti. |

### 5.2 Costo medio, valore medio (~3-4h)

| # | Cambiamento | Motivazione |
|---|---|---|
| 9 | Cattura `IdempotencyConflictError` in Runner e converti in failure terminale | Evita loop operativi infiniti su conflitto idempotenza |
| 10 | Tighten validazione su `StepInput`, `Event`, `RuntimeProfile` | Codex ha ragione: API pubblica deve rifiutare garbage |
| 11 | Aggiorna production readiness script per usare `Definition::Builder` | Usa il fast path previsto dal design |
| 12 | Documenta CoW limitato a value objects + storage-CoW pendente | Onestà del claim "concorrenza futura" |

### 5.3 Costo alto, valore architetturale (~6-8h, pre-S0)

| # | Cambiamento | Motivazione |
|---|---|---|
| 13 | Split `StorageState` per dominio (Workflow, Node/Attempt, Effect, Event) | 760 LOC sono troppi per un file; prepara il terreno per SQLite |
| 14 | Estrai `OutcomeHandler` e `Finalizer` da Runner | Solo quando aggiungi feature al Runner, non per estetica |
| 15 | Estrai `Graph::Algorithms` e `Graph::DotFormatter` | SRP; ma non urgente |

### 5.4 Proposte da RIFIUTARE — con motivazione

| Proposta | Reviewer | Perché rifiutare |
|---|---|---|
| Spezza Storage port in 4 port separati | Kimi | Romperebbe le atomic boundaries (`commit_attempt` scrive attempt+nodo+evento+effetti). Il port è grasso perché le transazioni sono grasse. |
| Rendi `Waiting` un `Result` con `and_then` | Kimi | Waiting è control-flow, non valore. La scelta di escluderlo è corretta e difesa da Codex. |
| Aggiungi `value_or`, `tap`, `map_error` a Result | Kimi | `result.rb:21-24` spiega perché sono esclusi: "trivially expressible in two lines of caller code". Surface minima = commitment a lungo termine. |
| Sostituisci `StorageState` con classi incapsulate | Kimi | La forma `module_function` è path-allowlistata dal cop `NoInPlaceMutation`. Cambiare forma senza cambiare semantica è churn. |
| OCC invece di storage fat (Gemini) | Gemini | Spostare la logica transazionale nel Runner significherebbe più round-trip e riaprire finestre di crash. Le atomic boundaries attuali sono intenzionali. |
| Rinomina CoW in `ImmutableCopy` | Kimi | `ExecutionContext#merge` usa `@data.merge(patch)` che è CoW dell'hash Ruby (shallow), poi `ExecutionContext.new` fa deep-freeze. Non è "copia totale" in tutti i casi. Il nome è approssimato ma non fuorviante. |

---

## 6. Verdetto finale

Il progetto è **serio**. Chi l'ha scritto conosce Wadler e ha shippato Ruby in produzione. I constraint sono enforced in codice (custom cops), non solo in prosa. I test sono di alta qualità (fuzz, crash simulation, fingerprint stability a 100 run). Non ci sono bug critici.

**Cosa regge:**
- Zero deps, immutabilità, ports-and-adapters, test suite, custom cops, atomic boundaries nel storage, determinismo bit-identico.

**Cosa non regge:**
- Il claim "monadi" è parziale (solo `Result` lo è).
- Il claim "CoW per concorrenza futura" è parziale (storage non pronto).
- Il claim "bilanciamento perfetto OOP/FP" è retorica.
- Il claim "DRY" è parziale (~200 righe di duplicazione regolare su value object).

**I tre debiti veri:**
1. **Boilerplate Data.define** (~200 righe). Vivila o documentala come intenzionale.
2. **Overstatement nei commenti** (`Await` "monad-like", CoW "per concorrenza"). Riformula.
3. **Runner e StorageState sono troppo densi** per la loro età. Non rifattorizzare per estetica — aspetta che una nuova feature (S0 SQLite) costringa lo split naturale.

**Useresti questa libreria?**
Sì, per workflow deterministico single-process con futuro durable adapter. No, se ti aspetti multi-process out-of-the-box.

**Stato:** production-ready alpha per il workload dichiarato. Una lista di nit di ~3 ore chiude il gap tra il codice e la sua narrazione.

---

## 7. Tabella di verifica — revisione delle review

| Claim | Reviewer | Esito | File:line verificato |
|---|---|---|---|
| `RunResult` non valida state | Claude, Codex | ✅ VERO | `run_result.rb:27-37` |
| `Await` non è monade | Claude, Gemini, Deepseek | ✅ VERO | `await.rb:5` |
| `Graph#nodes` cambia object_id | Kimi | ✅ VERO | `graph.rb:36-37` |
| `Runner` troppo lungo | Deepseek, Kimi | ✅ VERO | `runner.rb` (497 LOC) |
| `StorageState` C-style | Kimi | ✅ VERO | `storage_state.rb:12-13` |
| `StorageState` troppo grande | Tutti | ✅ VERO | `storage_state.rb` (760 LOC) |
| `storage_overrides?` duplicato | Deepseek, Kimi | ✅ VERO, 3 file | `runner.rb:382`, `dispatcher.rb:285`, `mutation_service.rb:76` |
| `immutable_json_copy` duplicato | Deepseek | ✅ VERO | `dispatcher.rb:40-44, 106-110` |
| Event types = 13 | Deepseek | ❌ FALSO | `event.rb:61-71` (10 tipi) |
| `REVIEW.md` obsoleto | Claude, Codex | ✅ VERO | `REVIEW.md:1` (parla di `Exec`, `drain_pipes`) |
| Effect conflict lascia stuck | Codex | ✅ VERO | `spec/support/storage_contract/effects.rb:87` |
| Spezza Storage port in 4 | Kimi | ❌ RIFIUTATO | `ports/storage.rb` (atomic boundaries) |
| Rendi Waiting un Result | Kimi | ❌ RIFIUTATO | `result.rb:4-5` (scelta deliberata) |
| `canonical_committed_attempt` ottimizzazione prematura | Claude, Deepseek, Kimi | ✅ VERO | `runner.rb:393-412` |
| `to_dot` non dovrebbe stare in Graph | Kimi | ✅ VERO, ma bassa priorità | `graph.rb:419-436` |
| `frozen_copy` troppo fiducioso su Set/custom | Kimi | ✅ VERO | `immutability.rb` (controllo `frozen?` superficiale) |

---

*Fine. Niente da riscrivere, molto da aggiustare.*
