# ruby-dag v1.0.1 — Final Review (meta-review verificata, stile Antirez)

> Sintesi delle 5 review parallele (`claude`, `codex`, `gemini`,
> `opencode-deepseek-v4-flash`, `opencode-kimi-k2.6`), con ogni claim
> verificata di prima persona contro il codice. Niente fiducia per delega:
> ogni `file:line` qui è stato controllato. Quando i reviewer divergono, decide
> il file, non la maggioranza.

---

## TL;DR

Il kernel è **serio**: zero deps, value object immutabili, custom cop per gli
anti-pattern, contract test condivisi sullo storage, fingerprint stability
verificato a 100 run. Niente bug critici. Tre debt strutturali manageable
(boilerplate `Data.define`, port storage grasso, `StorageState` monolitico) e
**due overstatement nella vision** (CoW per concorrenza, "monadi" plurale).

Tre dei cinque reviewer sono accurati nei dettagli, due hanno claim
falsificate (DeepSeek su event types, DeepSeek su `RuntimeProfile.defaults`,
Kimi su "anti-idiomatico" `module_function`). Claude sbaglia il count di
`storage_overrides?` (2 invece di 3 occorrenze).

**Stato**: production-ready alpha per il workload dichiarato (workflow
deterministico single-process con futuro durable adapter). Da non spedire come
"workflow engine multi-process out-of-the-box".

---

## 1. Validazione vision — 7 claim

| Claim                      | Verdetto      | Riferimento principale                                                             |
| -------------------------- | ------------- | ---------------------------------------------------------------------------------- |
| Zero dipendenze esterne    | ✅ vero       | `ruby-dag.gemspec` senza runtime deps; `lib/dag.rb` solo relative; require stdlib  |
| Monadi                     | ⚠️ parziale   | `Result` è una mini-monade; `Effects::Await` è un dispatcher con continuation      |
| Tipi dati immutabili       | ✅ vero       | `Data.define` 16+, `frozen_copy` 36+, `runner.rb:66` freeze finale                 |
| CoW per concorrenza futura | ⚠️ parziale   | Vero per i value object; lo storage è single-writer dichiarato                     |
| Bilanciamento OOP/FP       | ⚠️ parziale   | Stratificazione, non bilanciamento (FP per i valori, OOP per l'orchestrazione)     |
| Ruby idiomatico            | ✅ vero       | `Data.define`, kw args, `private_constant`, niente `attr_accessor`/method_missing  |
| DRY                        | ⚠️ parziale   | DRY per `Validation` e `frozen_copy`; non DRY per la forma costruttore Data.define |

### 1.1 Zero deps — vero

`lib/dag.rb` carica solo file relativi. I require runtime sono solo stdlib:
`securerandom`, `digest`, `json`. Il gemspec non dichiara runtime deps. Tutti
e cinque i reviewer convergono. **Reggesi al 100%.**

### 1.2 Monadi — parziale, lessico da correggere

`Result` è una mini-monade legittima:

- `result.rb:25` — `module Result` marker incluso da `Success` (`success.rb:11`)
  e `Failure` (`failure.rb:9`).
- `success.rb:61-63` — `and_then` con `Result.assert_result!` al boundary.
- `failure.rb:58-60` — `recover` simmetrico.
- `result.rb:21-24` — la lista esplicita dei metodi **non** inclusi (`tap`,
  `map_error`, `value_or`, `tap_error`) è disciplina, non religione.
- `result.rb:54-57` — `assert_result!` raise se il block non torna un `Result`.
  Questo becca il bug più comune di chi inizia con monadi (forgot to wrap).
  È **buona ingegneria**.

**`Waiting` non include `Result`** (`waiting.rb` linee 9-69, nessun
`include Result`). Codex e DeepSeek sono d'accordo: **scelta corretta**, non
bug. `Waiting` è control-flow di runtime (parking + resume token), non valore
monadico. Mescolarlo nel chain renderebbe la semantica meno esplicita.

`Effects::Await` (`effects/await.rb:5`) è documentato come "Monad-like step
helper". **Falso**. Niente `bind`, niente `pure`, niente composizione
`Await ∘ Await`. È un dispatcher che mappa snapshot di effetti
(`succeeded | failed_terminal | failed_retriable | reserved/pending`) in
risultati legali (`Success | Waiting | Failure`), con un `yield` per la
continuation. Va benissimo come helper — pessimo come "monade".

**Azione (10 minuti)**: cambia il commento a `effects/await.rb:5` da
"Monad-like step helper" a "Effect snapshot dispatcher with continuation". Non
cambiare il codice. Lo dice anche Claude review §3.2.

### 1.3 Tipi immutabili — vero, eseguito con disciplina

Verificato in modo capillare:

- `Data.define` ovunque (Edge, Event, RunResult, RuntimeProfile, StepInput,
  Success, Failure, Waiting, Intent, PreparedIntent, Record, ProposedMutation,
  ReplacementGraph, RunContext, DispatchReport, HandlerResult — 16+).
- `immutability.rb:16-19` — `frozen_copy` evita `deep_freeze(deep_dup(...))`
  inline, usato 36+ volte ai confini dei costruttori.
- `runner.rb:66` — `freeze` finale del Runner.
- `runner.rb:142-161` — `RunContext` frozen, `predecessors_by_node` frozen e
  cache pre-computata una volta per `#call`.
- `graph.rb` — frozen graph eagerly cacha layers, sort, roots, leaves, edges.

**Buco onesto, dichiarato dal codice**: `adapters/memory/storage_state.rb` è
mutable (760 LOC). Il commento in cima a `storage_state.rb:6-13` lo dichiara
esplicitamente come "the only spot in `lib/dag/**` allowed to mutate hashes
in place"; il cop `Dag/NoInPlaceMutation` esenta solo questa cartella. È
ammissione, non occultamento. Codex e Claude convergono: **scelta corretta**.

**Nitpick verificato di Kimi** (review §1.3 "Tipi immutabili"):
`immutability.rb:17` — `frozen_copy` accetta `value if value.frozen? && !value.is_a?(Hash) && !value.is_a?(Array)`.
Tecnicamente, un `Set` frozen contenente elementi mutabili non sarebbe
visitato. **Vero ma irrilevante**: nel kernel non vengono mai usati Set di
oggetti mutabili — i `Set` interni a `Graph` contengono Symbol (immutabili) e
sono freezati esplicitamente in `graph.rb:freeze`. Da non fixare senza un
caso reale.

### 1.4 CoW per concorrenza futura — overstatement

**Vero per i value object**: ogni mutazione di `Definition` / `Graph` /
`ExecutionContext` ritorna una nuova istanza congelata. Una `Definition` o
`Graph` frozen è safe da condividere tra thread.

**Falso per lo stato durabile**: `storage_state.rb:100-108` (e analoghi)
contengono read-modify-write loops senza alcun meccanismo di concorrenza:

```ruby
row = fetch_workflow!(state, id)
unless row[:state] == from
  raise StaleStateError, ...
end
row[:state] = to
```

Due thread che chiamano `transition_workflow_state` sullo stesso workflow in
parallelo → race condition con lost update. Il commento del file dichiara
"single-process" — è onesto. Ma "CoW per concorrenza futura" implica un
design di concorrenza che **non è ancora stato disegnato per lo storage
in-memory**. Sui port durable (S0+ in roadmap), il design è invece presente:
`prepare_workflow_retry`, `transition_workflow_state(event:)`,
`append_revision_if_workflow_state`, `commit_attempt(effects:)`,
`claim_ready_effects` con lease — sono tutti CAS/atomic boundary corretti.

Codex (§Vision/Copy-on-write) è il più preciso: **CoW non è una strategia di
concorrenza, è una disciplina che la rende meno pericolosa una volta che la
vera concorrenza vive nello storage**. Sottoscrivo.

**Gemini** ha un punto separato e legittimo: in MRI Ruby non esistono
strutture dati persistenti (Trie/HAMT). `deep_freeze` + `deep_dup` su un
contesto che cresce a ogni step è davvero copia totale, non CoW algoritmico.
Per workflow profondi e contesti grandi, il GC pressure è reale. Ma — come
osserva DeepSeek (§Copy-on-write) — il costo di vero CoW (structural sharing)
non vale il beneficio per workflow di decine/centinaia di nodi, che è il
target dichiarato. **Il claim "CoW" va riformulato in `ImmutableCopy at
boundaries` o "frozen value semantics"**.

### 1.5 Bilanciamento OOP/FP — stratificazione, non bilanciamento

Il codice è layered:

- **Value objects** → FP puro (`Data.define` + `frozen_copy`).
- **`Result`/`Success`/`Failure`** → mini-monade FP.
- **`Step::Base`** → classe OOP con `#call(StepInput) -> Result`.
- **`Runner`** → orchestrator OOP con `RunContext` carrier.
- **`StorageState`** → `module_function` C-style con state injection.

Niente di sbagliato in questo. È **pragmatismo**. Ma "bilanciamento perfetto"
è retorica. La definizione onesta è quella di Codex: "OOP per ports/adapters
e orchestrazione, FP per i valori". DeepSeek e Kimi convergono. Gemini è il
più ottimista qui ed è quello con meno fondamento sul codice.

### 1.6 Ruby idiomatico — vero, con un pattern ripetuto

Conformi al lessico Ruby 3.4:

- Niente `attr_accessor` (`runner.rb:32-44` solo `attr_reader`, cop
  `Dag/NoMutableAccessors` enforce).
- Niente `method_missing`, niente `define_method` magico.
- `Data.define` per ogni value object.
- `enum_for` lazy (`graph.rb:382, 389, 395, 401`).
- `private_constant` (`runner.rb:187, 309`).

**Pattern ripetuto, non sbagliato**: `class << self; remove_method :[]; def
[]; end; end; def initialize; validate; super; end` ricorre in 9 file. È un
trick noto per sostituire il costruttore positional di `Data.define` con uno
keyword-only validato. Costa ~10-15 righe per file di boilerplate. Vedi §2.4.

**Nota su `module_function` in `StorageState`** (`storage_state.rb:13`): Kimi
review lo definisce "anti-idiomatico Ruby 3.4. Stai scrivendo C con sintassi
Ruby". **Sbagliato**. Una classe con `@state` interno sarebbe identicamente
mutabile, solo con encapsulation. Il design qui è esplicito: tutto lo stato
viene iniettato dal facade `Memory::Storage`, e **una classe avrebbe nascosto
questo, non risolto**. Il pattern è "explicit state, single mutable site",
non "C with Ruby syntax". È ortogonale a OOP/non-OOP. Lascia stare.

### 1.7 DRY — parziale

**DRY dove costa poco**:

- `validation.rb` — 14 helper, 182 LOC, recentemente refactored (commit
  `45b5257`, `480d187`, `95786de`). Ogni costruttore lo invoca al confine.
- `frozen_copy` — 36+ occorrenze.
- `Result.exception_failure` (`result.rb:44-51`) — un solo posto fa
  `{code:, message:, error_class:, **extras}`.

**Non DRY dove costa metaprogramming**:

- 9 file ripetono il pattern `Data.define` + `class << self; remove_method
  :[]` + custom `initialize` (success, failure, waiting, run_result, event,
  step_input, intent, prepared_intent, record).
- 3 file ripetono `storage_overrides?` (vedi §2.1).
- 2 classi nello stesso file ripetono `immutable_json_copy` (vedi §2.1).

`CLAUDE.md` esplicitamente dice "Avoid `method_missing`, broad
metaprogramming, or generic 'validate schema' layers". Questa è scelta
consapevole di **vivere con la duplicazione regolare**. Ma il claim "DRY"
universale va ridimensionato: "DRY per le validation; duplicazione regolare
e accettata per la forma dei value object".

---

## 2. Bug e debt verificati di prima persona

### 2.1 `storage_overrides?` duplicato in 3 file (non 2)

| Sito                         | Righe        | Corpo                                                                       |
| ---------------------------- | ------------ | --------------------------------------------------------------------------- |
| `runner.rb:382-386`          | 5            | identico                                                                    |
| `effects/dispatcher.rb:285-289` | 5         | identico                                                                    |
| `mutation_service.rb:76-80`  | 5            | identico                                                                    |

Claude review (§3) e DeepSeek review (§DRY) hanno detto "2 file". **Sbagliato**.
Kimi review (§DRY) ha detto "Runner, MutationService, Dispatcher (3 volte
identico)". **Corretto**. Verificato con `grep -rn "storage_overrides?"
lib/`.

**Fix (15 minuti)**: spostare in `DAG::Ports::Storage` come module helper
o in `DAG` come `module_function`:

```ruby
# In lib/dag/ports/storage.rb (o lib/dag.rb)
module DAG
  module_function
  def storage_overrides?(storage, method_name)
    return false unless storage.respond_to?(method_name)
    storage.method(method_name).owner != DAG::Ports::Storage
  end
end
```

I 3 chiamanti diventano `DAG.storage_overrides?(@storage, :foo)`. Costo zero.

### 2.2 `immutable_json_copy` duplicato in `dispatcher.rb`

`effects/dispatcher.rb:40-46` (in `HandlerOutcome`) e
`effects/dispatcher.rb:106-112` (in `DispatchOutcome`) — stesso file, due
classi private, corpo identico:

```ruby
def immutable_json_copy(value)
  return nil if value.nil?
  return value if value.frozen?
  DAG.frozen_copy(value)
end
```

DeepSeek review (§DRY) lo ha beccato. **Corretto**.

**Fix (5 minuti)**: estrarre come `module_function` privato del `Dispatcher`
o convergere su `DAG.frozen_copy(value)` con un `nil` guard inline (la
funzione non aggiunge valore semantico oltre `frozen_copy` + `nil` check).

### 2.3 `RunResult` non valida `state`

`run_result.rb:27-37` — accetta qualsiasi Symbol come `state`. Tutti gli
altri value object validano gli enumerati con `Validation.member!`
(`event.rb:39`, `runtime_profile.rb:41`, `record.rb:229-236`). Il
costruttore unico in `runner.rb:471-477` passa solo i 4 valori validi
(`:completed | :paused | :waiting | :failed`), ma `RunResult.new`/`[]`
sono `@api public` (`run_result.rb:7`).

Claude (§3.3) e Codex (§Findings 3) convergono.

**Fix (15 minuti)**:

```ruby
# in run_result.rb
RUN_RESULT_STATES = %i[completed paused waiting failed].freeze

# in initialize
DAG::Validation.member!(state, RUN_RESULT_STATES, "state")
```

### 2.4 Validazione disuguale negli altri value object

Codex review (§Findings 3) ha la lista più completa, tutta verificata:

- **`StepInput`** (`step_input.rb:27-36`): valida solo `metadata` json_safe.
  Non valida `context` (dovrebbe essere `ExecutionContext`), `node_id`
  (Symbol/String), `attempt_number` (positive Integer).
- **`Event`** (`event.rb:38-57`): valida `type` membership e `payload`
  json_safe. Non valida `workflow_id` (String), `revision`
  (positive Integer), `at_ms` (Integer), `node_id`/`attempt_id` (opzionali),
  `seq` (opzionale Integer).
- **`RuntimeProfile`** (`runtime_profile.rb:40-59`): valida `durability`,
  `max_attempts_per_node`, `max_workflow_retries`. Non valida
  `event_bus_kind` (Symbol o enum).

Non è un bug attuale (il Runner costruisce questi valori correttamente). Ma
sono `@api public`. Se un host costruisce un `Event` con `revision: "1"`
invece di `1`, il bug si manifesta lontano dal sito di costruzione.

**Fix (1h)**: aggiungere helper `optional_nonnegative_integer!` e
`workflow_id!` in `validation.rb` e tirare i tre file. Test in
`spec/r1/types_validation_test.rb`.

### 2.5 Effect idempotency conflict — dead-end operativo

Codex (§Findings 2) ha l'osservazione più importante e meno ovvia. Verificata
contro `spec/support/storage_contract/effects.rb:87`: dopo un
`IdempotencyConflictError`, l'attempt resta `:running`, il nodo resta
`:running`, nessun evento appeso. Atomic e corretto al livello storage.

Ma al livello Runner: uno step deterministico che propone
`(type, key)` con payload diverso re-incappa nel conflitto a ogni resume.
Non è data corruption, è un **dead-end operativo** non terminale.

**Fix (1-2h)**: in `runner.rb` `commit_and_emit` (linea 285) avvolgere la
chiamata a `commit_attempt` in `rescue DAG::Effects::IdempotencyConflictError`,
trasformarlo in un `Failure` non retriable e proseguire al ramo
`:failed_terminal`. Test in `spec/r1/effects_*` mostrano il workflow
terminale invece del nodo `:running`.

### 2.6 `canonical_committed_attempt` micro-ottimizzazione fragile

`runner.rb:393-412` — 19 righe di mutation loop con 3 variabili (`best`,
`best_id`, `candidate_id`) per evitare l'array intermedio di `select`. Il
commento (`runner.rb:388-392`) **giustifica** invece di **spiegare**.

Costo dell'ottimizzazione: ogni reviewer si ferma a verificare che `best_id`
non leak across iterazioni quando `best` viene riassegnato (linea 401:
`best_id = nil` resetta correttamente).

Beneficio: per workflow con 100 nodi e ~3 attempts/nodo, ~300 array di 2
elementi e ~300 stringhe per `Runner#call`. Polvere su qualsiasi profilo
realistico.

Claude (§3.4) e DeepSeek (§Runner.rb) convergono: **migra al port**. Memory
adapter fa già la stessa cosa con `better_committed_attempt?`
(`storage_state.rb:710-719`); SQLite la farà con `ORDER BY attempt_number
DESC, attempt_id DESC LIMIT 1`. Il Runner non dovrebbe sapere come
discriminare attempts. La sostituzione è:

```ruby
def canonical_committed_attempt(attempts)
  attempts
    .select { |a| a[:state] == :committed }
    .max_by { |a| [a.fetch(:attempt_number), a.fetch(:attempt_id).to_s] }
end
```

3 righe. 1-2 microsecondi più lente. Più leggibili.

### 2.7 Storage port "fat" — port gravity

`lib/dag/ports/storage.rb` ha **26 metodi** in 338 righe (verificato con
`grep -c '^[[:space:]]*def ' lib/dag/ports/storage.rb`):

- workflow CRUD (5): `create_workflow`, `load_workflow`,
  `transition_workflow_state`, `prepare_workflow_retry`,
  `abort_running_attempts`
- definition revisions (4): `append_revision`,
  `append_revision_if_workflow_state`, `load_revision`,
  `load_current_definition`
- node states (2): `load_node_states`, `transition_node_state`
- attempts (4): `begin_attempt`, `commit_attempt`, `list_attempts`,
  `count_attempts`
- effect ledger (8): `list_effects_for_node`, `list_effects_for_attempt`,
  `claim_ready_effects`, `mark_effect_succeeded`, `mark_effect_failed`,
  `complete_effect_succeeded`, `complete_effect_failed`,
  `release_nodes_satisfied_by_effect`
- predecessor results (1): `list_committed_results_for_predecessors`
- events (2): `append_event`, `read_events`

Codex (§Findings 1), Gemini (§2 Storage Contract), DeepSeek (§ports/storage),
Kimi (§ports/storage) — **convergono tutti**.

Fa male in due modi:

1. La barriera per scrivere il primo durable adapter (SQLite/Postgres) è
   alta. Ogni metodo ha semantica atomica documentata.
2. Tre dei metodi (`prepare_workflow_retry`, `commit_attempt(effects:)`,
   `claim_ready_effects`) chiedono al DB transazionalità complessa.

**Codex propone bene** (§Findings 1): non splittare il port casualmente, ma
**congelare la crescita** e documentare una capability matrix ("runner core",
"resume", "mutation", "effects", "dispatcher") per dichiarare quali metodi
servono per quale feature pubblica. Sottoscrivo.

**Gemini propone** (§Storage Contract): ridurre il contratto storage a
primitive elementari + CAS lift-up al kernel. **Non sono d'accordo**:
spostare il CAS al kernel impone round-trip extra (read → guard → write) che
in un DB transazionale sono unica query. Gli atomic boundary attuali esistono
perché chiudono crash gap reali, e Codex lo dimostra metodicamente
("Crash-resume semantics are treated seriously"). La giusta strada è quella
di Codex: **congelare il port, non riscriverlo**.

**Deepseek/Kimi propongono** lo split in 4 port (`WorkflowStorage`,
`NodeAttemptStorage`, `EventStorage`, `EffectStorage`). Difendibile, ma il
Runner dipenderebbe da 4 oggetti invece di 1, e gli atomic boundary
(`commit_attempt(event:, effects:)`, `transition_workflow_state(event:)`,
`prepare_workflow_retry(event:)`) tagliano deliberatamente trasversalmente
ai sub-domini. Splittare significherebbe rompere quei boundary o introdurre
un facade. Non vale la candela in alpha.

### 2.8 `StorageState` monolitico (760 LOC)

`storage_state.rb` è un singolo `module_function` con tutti i sottosistemi
(workflow, attempts, events, effects, retry, mutation guard) in un file.
Codex (§Findings 4), DeepSeek (§Memory::StorageState), Kimi
(§lib/dag/adapters/memory/storage_state.rb) convergono.

**Fix (2h, zero rischio)**: split per dominio prima di S0 (SQLite). 4-5 file
sotto `lib/dag/adapters/memory/` (es. `lifecycle.rb`, `attempts.rb`,
`effects.rb`, `events.rb`, `retry.rb`). Il facade `Memory::Storage` resta
unchanged; il modulo `StorageState` può diventare un facade interno che
delega ai sub-moduli. Nessun cambio di comportamento.

Quando arriverà SQLite, ogni sub-modulo diventa una sezione di adapter con
boundary di transazione coerente, invece di un mega-file da decomporre. Il
costo è basso, il payoff è alto se si vuole rispettare l'invariante "lo
storage è il vero kernel" (Codex §Findings 1).

### 2.9 `Record#to_snapshot` espone campi infrastrutturali

`effects/record.rb:5-19` — `RECORD_SNAPSHOT_FIELDS` include
`payload_fingerprint`, `external_ref`, `not_before_ms` insieme ai campi
semantici (`type`, `key`, `payload`, `result`, `error`). Lo step in
`Effects::Await` legge solo `status`, `result`, `error`, `not_before_ms`.

`payload_fingerprint` è idempotenza storagica; `external_ref` è dispatch lease
integration. Nessuno step li dovrebbe vedere.

Claude (§3.8) lo segnala. Verificato.

**Fix (30 min)**: filtrare `RECORD_SNAPSHOT_FIELDS` ai soli campi semantici.
Rompe API solo se qualche caller esterno legge `payload_fingerprint` dallo
snapshot — improbabile, ma vista l'alpha, accettabile.

### 2.10 Production readiness usa la chain API per grafi grandi

Codex (§Findings 5). `scripts/production_readiness.rb:770-796` —
`build_large_graph(:chain | :fanout | :diamond, nodes)` itera con
`definition = definition.add_node(...).add_edge(...)`. Ogni iterazione
ricrea una `Definition` immutabile, paga il costo CoW.

`DAG::Workflow::Definition::Builder` esiste a
`lib/dag/workflow/definition/builder.rb:7` proprio per costruzione bulk
(buffer mutabile + freeze unico al `build`).

**Fix (30 min)**: sostituire le 3 branch con `Builder.build do |b| ... end`
nel modo `Builder.build { |b| b.add_node(:n0, type: :noop) ...
b.add_edge(:n0, :n1) ... }`. Una probe perf più rappresentativa.

### 2.11 `REVIEW.md` è di altro progetto

`REVIEW.md` (untracked, root). Verificato leggendo le prime 50 righe: parla
di `Steps::Exec`, `Strategy.run_task`, `KILL_GRACE_SECONDS`, `drain_pipes`,
`Threads/Processes/Ractor`, `:exec`/`:ruby`/`:ruby_script`,
`Loader.from_yaml(Dumper.to_yaml(...))`. **Niente di tutto ciò esiste in
ruby-dag**. Sembra spillage da un altro progetto.

Claude (§Context) e Codex (§Findings 6) convergono.

**Fix (5 min)**: rimuovi o sposta in `docs/legacy/`. Se resta in root, un
agente futuro forma il modello mentale sbagliato.

---

## 3. Cosa hanno preso bene i 5 reviewer (convergenze)

Punti su cui tutti concordano, **e il codice conferma**:

1. **Zero deps regge** — gemspec + `lib/dag.rb` puliti.
2. **`Result` è una mini-monade legittima**; **`Effects::Await` non è una
   monade**.
3. **`Waiting` escluso da `Result` è scelta deliberata e corretta**, non bug.
4. **Immutabilità ben eseguita ai confini** (`frozen_copy`, `Data.define`,
   `freeze` finale del Runner).
5. **`storage_state.rb` è confessato come single mutable site** e contenuto
   dietro il facade.
6. **Custom RuboCop cops** (`NoThreadOrRactor`, `NoMutableAccessors`,
   `NoInPlaceMutation`, `NoExternalRequires`) — disciplina enforced al
   linter, non confidata.
7. **Test seri**: graph fuzz (708 LOC), fingerprint stability a 100 run,
   crash simulation (`CrashableStorage`), `spec/support/storage_contract/`
   condivisibile.
8. **Atomic boundary corretti**:
   - `commit_attempt(event:, effects:)` (un'unica transazione logica),
   - `transition_workflow_state(event:)` (chiude la crash gap workflow→event),
   - `prepare_workflow_retry(event:)` (CAS guard + reset + budget atomico),
   - `claim_ready_effects(lease_ms:, owner_id:)` (lease-aware claim).
9. **`Runner.new` 7 keyword required** — niente default singleton hide
   (`runner.rb:54-57`).
10. **`finalize` con commento di design** (`runner.rb:435-453`) — niente
    fallback a `:waiting` se nessun nodo waiting; surface `:failed` con
    `diagnostic: :no_eligible_but_incomplete`. **Onestà sopra eleganza**.

---

## 4. Cosa hanno sbagliato i 5 reviewer (claim falsificate)

Verificare ogni claim ha pagato. Errori trovati:

### 4.1 DeepSeek — "CONTRACT.md dice 10, codice ha 13" — **falso**

DeepSeek (§Errori minori): "Event types count: CONTRACT.md dice 10, il codice
ne ha 13 (mancano probabilmente quelli aggiunti con effects/mutations)".

`event.rb:61-72` ha **10** event types (`workflow_started`, `node_started`,
`node_committed`, `node_waiting`, `node_failed`, `workflow_paused`,
`workflow_waiting`, `workflow_completed`, `workflow_failed`,
`mutation_applied`).

`CONTRACT.md:514-525` ha **gli stessi 10**. Allineati. Niente da fare.

### 4.2 DeepSeek — "`RuntimeProfile.defaults` non è usato dal Runner" — **falso**

DeepSeek (§Errori minori): "RuntimeProfile.defaults: max_attempts_per_node:3
e max_workflow_retries:0 non sono usati dal Runner — sono default nel value
object ma il costruttore di Runner non applica default".

`RuntimeProfile.default` (`runtime_profile.rb:30-38`, singolare, non
"defaults") è una factory helper. L'utente la chiama, ottiene un
`RuntimeProfile` con i valori 3/0/`:ephemeral`/`:null`, e lo passa a
`create_workflow`. Il Runner accede a quei valori in
`runner.rb:248`
(`run.runtime_profile.max_attempts_per_node`) e dentro
`storage.prepare_workflow_retry` per il budget. **I default sono usati
indirettamente, non magicamente — cioè come tutti i factory default in
Ruby.** Il design è corretto: il Runner non ha default impliciti
(`Runner.new` richiede ogni keyword), e i workflow defaults vivono nel
profile creato dall'utente.

### 4.3 Claude — "`storage_overrides?` duplicato in 2 file" — **falso (off-by-one)**

Claude (§3 critiche, riepilogo): "DRY mancato in 2 file (Runner +
Dispatcher)".

In realtà sono **3** file: `runner.rb:382`, `effects/dispatcher.rb:285`,
`mutation_service.rb:76`. Kimi review è il più accurato qui.

Non cambia il fix (estrarre come module helper), ma cambia il count.

### 4.4 Kimi — "`module_function` su `StorageState` è anti-idiomatico" — **opinione, non fatto**

Kimi (§Ruby idiomatico, §StorageState C-style): "stai scrivendo C con
sintassi Ruby. La scusa 'è l'unico posto dove mutare è permesso' non
giustifica la forma procedurale".

Il pattern qui è **explicit state injection**: ogni metodo prende `state`
come primo argomento, lo mutua in-place, ritorna il delta. Una classe con
`@state` interno avrebbe la stessa mutazione, solo nascosta dietro un
campo. Il vantaggio del `module_function` qui è che **l'unico posto in cui
lo state esiste è il facade `Memory::Storage`** (verificare leggendo
`memory/storage.rb`), non sparpagliato in tante istanze. Anti-idiomatico
sarebbe avere `StorageState.workflows = {}` come singleton globale.

Reasonable people may differ on encapsulation taste. Ma "anti-idiomatico"
è un'overstatement. Lascia stare.

### 4.5 Gemini — "Bilanciamento perfetto OOP/FP raggiunto" — **ottimista**

Gemini (§Vision) è il più favorevole sul claim "bilanciamento perfetto
OOP/FP". Claude e DeepSeek lo demoliscono con esempi concreti:

- `Runner` ha 19 metodi privati, `RunContext` viaggia attraverso ~15 di
  loro; non puoi comporre due Runner in pipeline.
- `StorageState` è procedurale, non OOP né FP.
- `Step::Base` è OOP con contratto FP.

La descrizione onesta è **stratificazione**: FP per i valori, OOP per
l'orchestrazione, procedurale per lo storage. Niente di sbagliato — è
**pragmatismo**, non bilanciamento.

### 4.6 Gemini — "deep_freeze distrugge il GC" — **non verificato sul workload target**

Gemini (§1 CoW Performance): "In un workflow con centinaia di nodi, dove il
contesto cresce ad ogni step, questo design distruggerà le performance del
Garbage Collector".

L'osservazione del costo CoW in Ruby è corretta in astratto. Ma `production_readiness.rb` (probe perf nel repo) include scenari `:chain` /
`:fanout` / `:diamond` con grafi grandi e li passa con un budget di tempo
configurabile. Codex riporta che il fast probe passa in 5 secondi
(`bundle exec ruby scripts/production_readiness.rb --fast --duration 5
--progress-interval 2` → pass). Non c'è evidenza pubblica nel repo che il GC
sia un problema attuale per il workload target (workflow di decine/centinaia
di nodi). Diventa rilevante solo per contesti larghi e profondi
(>>100 nodi con context grandi). **Su workload normali, non è un problema
verificato — è un'ipotesi ragionevole**.

---

## 5. Cosa nessuno ha visto (o ha sotto-pesato)

### 5.1 `predecessors_by_node` cache — è il singolo fix di perf più importante

`runner.rb:142-161` — `build_run_context` precomputa
`predecessors_by_node` una volta per `Runner#call`, evitando di chiamare
`each_predecessor` per nodo a ogni iterazione del loop. Claude lo segnala
come positivo (§2). Nessun altro reviewer lo nota.

In un grafo con N nodi e M predecessori medi, il loop `eligible_nodes` viene
chiamato O(L) volte (L = numero di layer). Senza la cache, ogni chiamata
itera N nodi e per ognuno chiama `each_predecessor` (O(M)). Con la cache, è
O(L·N·M) → O(L·N) hash lookup. È un vantaggio reale, non micro.

### 5.2 `append_workflow_started_once` è idempotente per scansione, non per flag

`runner.rb:177-184` — l'idempotenza dell'evento `workflow_started` è
implementata leggendo il primo evento dello storage, non con un flag in
storage:

```ruby
first_event = @storage.read_events(workflow_id: run.workflow_id, limit: 1).first
return if first_event&.type == :workflow_started
```

Sopravvive crash, retry, resume, durable adapter switch. **Buona ingegneria**.
Claude lo nota; gli altri no.

### 5.3 `storage_overrides?` è il pattern fast-path/slow-path documentato

DeepSeek (§Cosa funziona) lo cita positivamente: "Permettere allo storage di
sovrascrivere metodi 'default' del runner è intelligente. Il runner ha un
fallback generico, lo storage può ottimizzare. Questo pattern dovrebbe
essere usato di più".

**Sottoscrivo, ma con un caveat**: il fast-path su
`list_committed_results_for_predecessors` è essenziale (`runner.rb:367`); il
fallback (`runner.rb:375-379`) è O(predecessori) per nodo, **debole sul
default port**. Codex (§Findings 1, capability matrix) ha la risposta
giusta: documentare come capability obbligatoria per gli adapter "runner
core". Vedi §6.5.

### 5.4 Effect snapshot leak è più grave di "campi infrastrutturali"

Claude (§3.8) tratta `payload_fingerprint`/`external_ref` come "leak di
campi infrastrutturali" e propone un filter — corretto, ma sottostimato.

Il problema reale: uno step che scrive ai metadati lo step pre-execution e
si fa fingerprint con `payload_fingerprint` di prima, **diventa
deterministico in modo errato** (ricade sull'idempotenza dell'effect, non
sulla logica dello step). Il filter va fatto.

### 5.5 Crash-resume durability invariant è documentato e implementato

Codex (§What Works Well, "Crash-resume semantics are treated seriously") è
il più preciso. La sequenza
`Runner#transition_and_emit_terminal` → `storage.transition_workflow_state(event:)`
chiude la finestra in cui il workflow era terminale ma il `:workflow_failed`
non era stato persisted. Senza questo, `Runner#resume` rimaneva intrappolato
(`acquire_running` rejecta terminal states).

Sotto-pesato dagli altri reviewer. Vale come "feature distintiva" rispetto a
workflow engine concorrenti che lasciano questa gap implicita.

---

## 6. Proposte concrete (priorità)

Ordinate per costo/beneficio. Le prime 5 sono "low-hanging fruit" e
dovrebbero essere candidate v1.0.2.

| #   | Cambiamento                                                               | Costo  | Beneficio                       | Rif.  |
| --- | ------------------------------------------------------------------------- | ------ | ------------------------------- | ----- |
| 1   | `Validation.member!(state, RUN_RESULT_STATES)` in `RunResult`              | 15min  | uniformità + safety pubblica    | §2.3  |
| 2   | Estrai `storage_overrides?` come `DAG.storage_overrides?(storage, name)`   | 15min  | DRY 3 → 1                       | §2.1  |
| 3   | Estrai/elimina `immutable_json_copy` duplicato in `dispatcher.rb`          | 10min  | DRY 2 → 1                       | §2.2  |
| 4   | Rimuovi `REVIEW.md` o sposta in `docs/legacy/`                             | 5min   | igiene + no-mental-model-drift  | §2.11 |
| 5   | Cambia commento "Monad-like" → "Effect snapshot dispatcher" in `await.rb`  | 5min   | onestà semantica                | §1.2  |
| 6   | Filtra `RECORD_SNAPSHOT_FIELDS` ai soli campi semantici                    | 30min  | separazione semantica/infra     | §2.9  |
| 7   | Sostituisci `canonical_committed_attempt` con `select.max_by`              | 20min  | leggibilità sopra micro-perf    | §2.6  |
| 8   | `production_readiness.rb` `build_large_graph` usa `Builder`                | 30min  | probe perf rappresentativa      | §2.10 |
| 9   | Tighten validation di `StepInput`/`Event`/`RuntimeProfile`                 | 1h     | safety API pubblica             | §2.4  |
| 10  | Catch `IdempotencyConflictError` in Runner → terminal failure              | 1-2h   | chiude operational dead-end     | §2.5  |
| 11  | Documenta capability matrix dello storage port                             | 1-2h   | adoption barrier per S0         | §2.7  |
| 12  | Documenta in `CLAUDE.md` boilerplate `Data.define` come scelta intenzionale| 30min  | chiude falsa contradiction DRY  | §1.7  |
| 13  | Documenta CoW limitato a value objects + storage CoW → SQLite              | 30min  | onestà del claim                | §1.4  |
| 14  | Split `storage_state.rb` per dominio prima di S0                           | 2h     | preparazione SQLite             | §2.8  |
| 15  | Rinomina mentalmente "CoW" in "frozen value semantics" nel README          | 15min  | onestà del claim                | §1.4  |

**Bundle "1 ora di lavoro per chiudere il gap"**: voci 1-5 (45 min totali),
zero rischio, riducono il count di "claim non onesti" da 3 a 0.

**Bundle "candidato v1.0.2"**: aggiungi voci 6-10 (~3-4h totali). Stato
honest-claim 7/7, validation public-API uniforme, idempotency conflict
recoverable, probe perf più rappresentativa.

**Bundle "preparazione S0"**: aggiungi voci 11, 14 (~3-4h totali). Capability
matrix pronta per il primo durable adapter; `storage_state.rb` decomposed.

---

## 7. Verdetto Antirez

Codice serio. Tre marcatori che separano "personal project" da "qualcuno che
ha shippato":

1. **`Result.assert_result!`** (`result.rb:54-57`) — beccare il "forgot to
   wrap" al boundary del block è esperienza, non teoria.
2. **Custom cop enforcement** (`Dag/NoThreadOrRactor`, `Dag/NoMutableAccessors`,
   `Dag/NoInPlaceMutation`, `Dag/NoExternalRequires`) — la disciplina è
   **enforced**, non confidata.
3. **`finalize` con commento di design** (`runner.rb:435-453`) — surface
   `:failed` con `diagnostic: :no_eligible_but_incomplete` invece di forgive
   a `:waiting`. **Onestà sopra eleganza**.

Niente bug critici verificati. Tre debt manageable:

- **boilerplate `Data.define` ripetuta** (~150-200 LOC). Vivi con essa o
  documentala come intenzionale. **Non metaprogrammarla**.
- **storage port grasso** (26 metodi). Congela la crescita; documenta la
  capability matrix.
- **`storage_state.rb` monolitico** (760 LOC). Splittalo prima di SQLite.

Due overstatement nella vision:

- "**Monadi**" → hai una sola, su `Result`. `Effects::Await` è dispatcher.
  Cambia il vocabolario, non il design.
- "**CoW per concorrenza futura**" → vale per i value object passati
  attraverso il kernel. Lo stato durabile è single-writer. Definisci il target
  di concorrenza (single-process MRI? multi-process via durable adapter?
  multi-host?) e riformula il claim.

Useresti questa libreria? **Sì**, se il dominio è "workflow deterministico
single-process con futuro durable adapter". **No**, se ti aspetti
multi-process out-of-the-box senza la fase S0.

**Stato**: production-ready alpha per il workload dichiarato. Niente da
riscrivere. Lista di nit di 3-4 ore per la candidate v1.0.2 e 6-8 ore per la
preparazione S0.

Tutto il resto — DRY (per le validation), immutabilità (al boundary),
idiomaticità Ruby, zero deps, ports, atomic boundary, test — **regge**.

---

## 8. Appendice: tabella di verifica completa

Ogni claim significativa dei 5 review verificata di prima persona contro il
codice. Verdetto: ✅ vero — ⚠️ parziale/sfumato — ❌ falso.

| #  | Claim                                                                       | Da chi              | Esito          | Verifica                                                                   |
| -- | --------------------------------------------------------------------------- | ------------------- | -------------- | -------------------------------------------------------------------------- |
| 1  | Zero deps esterne nel gemspec                                               | tutti               | ✅             | `lib/dag.rb` solo relative; `securerandom`, `digest`, `json` da stdlib     |
| 2  | `Result` è una mini-monade su Success+Failure                               | claude, codex, ds   | ✅             | `result.rb:25`, `success.rb:11`, `failure.rb:9`                            |
| 3  | `Waiting` non include `Result`                                              | claude, codex, ds   | ✅             | `waiting.rb:9-69`, nessun `include Result`                                 |
| 4  | `Effects::Await` "Monad-like" non lo è                                      | claude              | ✅             | `effects/await.rb:5`; nessun `bind`/`pure`                                 |
| 5  | `runner.rb` 497 righe                                                       | claude, ds, kimi    | ✅             | `wc -l`                                                                    |
| 6  | `graph.rb` 696 righe                                                        | ds, kimi            | ✅             | `wc -l`                                                                    |
| 7  | `storage_state.rb` 760 righe                                                | claude, codex, ds   | ✅             | `wc -l`                                                                    |
| 8  | `dispatcher.rb` 339 righe                                                   | ds                  | ✅             | `wc -l`                                                                    |
| 9  | `validation.rb` 182 righe                                                   | claude              | ✅             | `wc -l`                                                                    |
| 10 | `Runner.new` richiede 7 keyword                                             | claude, codex       | ✅             | `runner.rb:54-67`                                                          |
| 11 | `Runner` freeze finale                                                      | claude              | ✅             | `runner.rb:66`                                                             |
| 12 | `each_predecessor`/`each_successor` esistono                                | claude              | ✅             | `graph.rb:394`, `graph.rb:400`                                             |
| 13 | `RunResult` non valida `state`                                              | claude, codex       | ✅             | `run_result.rb:27-37`                                                      |
| 14 | `StepInput` non valida `context`/`node_id`/`attempt_number`                 | codex               | ✅             | `step_input.rb:27-36`                                                      |
| 15 | `Event` non valida `workflow_id/revision/at_ms/...`                         | codex               | ✅             | `event.rb:38-57`                                                           |
| 16 | `RuntimeProfile` non valida `event_bus_kind`                                | codex               | ✅             | `runtime_profile.rb:40-59`                                                 |
| 17 | `canonical_committed_attempt` mutation loop                                 | claude, ds          | ✅             | `runner.rb:393-412`                                                        |
| 18 | `effective_context` fallback O(predecessori)                                | claude              | ✅             | `runner.rb:366-380` con `storage_overrides?`                               |
| 19 | `handle_outcome` mescola decisione e side-effect                            | claude, ds          | ✅             | `runner.rb:227-265`                                                        |
| 20 | `finalize` non fallback a `:waiting` se nessun nodo waiting                 | claude              | ✅             | `runner.rb:440-453` + commento di design                                   |
| 21 | `storage_overrides?` duplicato in 2 file                                    | claude, ds          | ❌             | In realtà 3: `runner.rb:382`, `dispatcher.rb:285`, `mutation_service.rb:76` |
| 22 | `storage_overrides?` duplicato in 3 file                                    | kimi                | ✅             | Conferma ai siti elencati                                                  |
| 23 | `immutable_json_copy` duplicato in `dispatcher.rb`                          | ds                  | ✅             | `dispatcher.rb:40-46` (HandlerOutcome) + `dispatcher.rb:106-112` (DispatchOutcome) |
| 24 | `to_dot` in `Graph` viola SRP                                               | kimi                | ✅             | `graph.rb:419-436` — accettabile ma scope creep                            |
| 25 | `nodes` ritorna dup-or-original a seconda di `frozen?`                      | kimi                | ⚠️             | `graph.rb:36`; nitpick (Hash usa `hash()`, non `object_id`)                |
| 26 | `frozen_copy` accetta frozen `Set` con elementi mutabili                    | kimi                | ⚠️             | `immutability.rb:17`; tecnicamente vero, no caso reale nel kernel          |
| 27 | `RECORD_SNAPSHOT_FIELDS` espone `payload_fingerprint`/`external_ref`        | claude              | ✅             | `record.rb:5-19`                                                           |
| 28 | `CONTRACT.md` ha 10 event types, codice ne ha 13                            | ds                  | ❌             | Entrambi 10: `CONTRACT.md:514-525` e `event.rb:61-72`                      |
| 29 | `RuntimeProfile.defaults` non è usato dal Runner                            | ds                  | ❌             | È `RuntimeProfile.default` (singolare); usato indirettamente dal profile creato dall'utente — `runner.rb:248` |
| 30 | `REVIEW.md` è di altro progetto                                             | claude, codex       | ✅             | Steps::Exec/Strategy/KILL_GRACE_SECONDS/Threads — niente esiste qui        |
| 31 | `production_readiness.rb` `build_large_graph` usa chain non Builder         | codex               | ✅             | `scripts/production_readiness.rb:770-796`                                  |
| 32 | `Definition::Builder` esiste                                                | codex               | ✅             | `lib/dag/workflow/definition/builder.rb`                                   |
| 33 | `Ports::Storage` ha ~30 metodi                                              | ds, kimi            | ✅             | 26 metodi pubblici (338 LOC); approssimazione ragionevole                  |
| 34 | Cycle detection O(V+E) per `add_edge`                                       | gemini              | ✅             | `graph.rb` `add_edge` chiama `reachable?` (commento esplicito)             |
| 35 | Storage port "fat"/scope gravity                                            | codex, gemini, kimi | ✅             | 26 metodi su 338 LOC; convergenza onesta                                   |
| 36 | `Memory::StorageState` è single mutable site dichiarato                     | claude, codex, ds   | ✅             | `storage_state.rb:6-13` + `Dag/NoInPlaceMutation` cop scope                |
| 37 | Test count: 515 (codex) o 490 (ds)                                          | codex, ds           | ⚠️             | Codex riporta `bundle exec rake` 515 tests / 39885 assertions. Da rieseguire. |
| 38 | Effect idempotency conflict deadlock operativo                              | codex               | ✅             | `spec/support/storage_contract/effects.rb:87` conferma; runner-level reale |
| 39 | Custom RuboCop cops attivi e funzionanti                                    | tutti               | ✅             | `CLAUDE.md` + cop test                                                     |
| 40 | `module_function` per `StorageState` è "anti-idiomatico"                    | kimi                | ❌             | Opinione, non fatto. Pattern "explicit state, single mutable site" valido  |
| 41 | "Bilanciamento perfetto OOP/FP" raggiunto                                   | gemini              | ⚠️             | Stratificazione, non bilanciamento; pragmatismo legittimo                  |
| 42 | `deep_freeze` "distrugge il GC" su workflow grandi                          | gemini              | ⚠️             | Plausibile in astratto; non verificato sul workload target nel repo        |

Totale: 42 claim. **34 ✅ vere — 5 ⚠️ sfumate — 3 ❌ falsificate**.

Reviewer più accurato sui dettagli: **Claude** (con un off-by-one su
`storage_overrides?`).
Reviewer più equilibrato sull'analisi architetturale: **Codex**.
Reviewer più aggressivo ma con claim non verificate: **DeepSeek** (2 falsi),
**Kimi** (1 opinione presentata come fatto).
Reviewer più sintetico ma con alcune assunzioni non probate: **Gemini**.

---

*— Antirez (channeled). La review che il codice meritava: fatti, file:line,
niente lodi. Ogni claim sopravvive al `git grep`, o muore.*
