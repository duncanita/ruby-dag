# ruby-dag v1.0.1 — Code Review (stile Antirez)

> Revisione richiesta: brutalmente onesta, niente carezze. Vision dell'utente
> validata punto per punto. Citazioni `file:line` per ogni claim.

---

## Context

Revisione completa di `ruby-dag` v1.0.1 (kernel deterministico per
DAG/workflow, ~6.4k LOC `lib/`, ~6.7k LOC `spec/`) e validazione punto per
punto della vision tecnica dichiarata:

1. Zero dipendenze esterne
2. Monadi
3. Tipi dati immutabili
4. Copy-on-write per garantire concorrenza futura
5. Bilanciamento perfetto OOP / programmazione funzionale
6. Ruby idiomatico
7. DRY

Stile Antirez: fatti, non lodi; pro e contro; proposte alternative che
rispettino la vision dopo averla validata.

**File ignorati**: `REVIEW.md` nel working tree è di un altro progetto (parla
di `Steps::Exec`, `Strategy.run_task`, `:threads`/`:processes`, `drain_pipes`,
`KILL_GRACE_SECONDS` — niente di tutto ciò esiste qui). Sembra spillage da un
altro repo. Da rimuovere o spostare; non vale come review di ruby-dag.

---

## 1. Validazione della vision

### 1.1 ✅ Zero dipendenze esterne — vero

`ruby-dag.gemspec` non dichiara runtime deps; `lib/dag.rb` carica solo file
relativi. Stdlib (JSON, SecureRandom, Set) — fine. Questo claim regge.

### 1.2 ⚠️ Monadi — parzialmente vero, parzialmente marketing

**Vero**: `DAG::Result` è una mini-monade onesta su `Success | Failure`:

- `result.rb:25` — modulo marker incluso da Success **e** Failure
- `result.rb:54-57` — `assert_result!` enforce alla bound del block, beccando
  il bug più comune ("forgot to wrap"). Questa è **buona ingegneria**.
- `success.rb:61-63`, `Failure#and_then` (`failure.rb:45`), `recover`
  (`failure.rb:58-60`) — left identity, associatività e short-circuit di
  `and_then`/`recover` sono rispettate.
- `result.rb:21-24` — la lista esplicita di metodi NON inclusi (`tap`,
  `tap_error`, `map_error`, `value_or`) è disciplina vera, non religione.

**Marketing**: `Effects::Await` (`effects/await.rb:5`) si proclama
"Monad-like". Falso.

- È un dispatcher su 4 stati di un effect snapshot (succeeded /
  failed_terminal / failed_retriable / nil-or-pending) con `yield` al
  continuation. Non c'è composizione `Await ∘ Await`, niente `pure`, niente
  `bind`. È una if-let con custodia di tipi. Va benissimo come helper —
  pessimo come "monade".
- Non si compone con se stesso: due Await consecutivi richiedono di rimbalzare
  attraverso `Result#and_then`, mescolando due astrazioni.

**Sum type fake**: `Success | Waiting | Failure` non è un ADT vero. Sono tre
`Data.define` separate; il dispatch è `case/when` su classi
(`runner.rb:228-264`, `step_protocol.rb:16`). Waiting **deliberatamente non
include** `Result` (`result.rb:4-5`) — design consapevole: "Waiting è
control-flow, non un valore monadico". Questa scelta è onesta e va
documentata come tale, ma cancella metà del claim "monadi".

**Verdetto vision**: il claim "monadi" regge solo per `Result` su
Success/Failure. Per Effects/Await è retorica. Cambia il vocabolario, non il
design.

### 1.3 ✅ Tipi dati immutabili — vero, eseguito con disciplina

- `Data.define` ovunque: Edge, Event, RunResult, RuntimeProfile, StepInput,
  Success, Failure, Waiting, Intent, PreparedIntent, Record, ProposedMutation,
  ReplacementGraph, RunContext, DispatchReport, HandlerResult — 16+
  occorrenze.
- `immutability.rb:16-19` — `frozen_copy` evita il pattern
  `deep_freeze(deep_dup(...))` ed è usato 36+ volte ai confini dei costruttori
  (success.rb:41-45, failure.rb:28-30, waiting.rb:62-66, edge.rb, intent.rb,
  prepared_intent.rb:119-130, record.rb:194-215). Disciplinato.
- `runner.rb:66` — `freeze` finale del Runner. `RunContext` (linee 142-161) e
  `predecessors_by_node` (linea 150) frozen.
- `graph.rb` — frozen graph eagerly cacha layers, sort, roots, leaves, edges
  (commento + cache invalidation pattern).

Buco onesto, **dichiarato dal codice stesso**:
`adapters/memory/storage_state.rb` — 760 LOC di mutation in-place. Il commento
in cima dice esplicitamente "the ONLY spot in `lib/dag/**` allowed to mutate"
(richiamato anche in `CLAUDE.md`). È un'ammissione, non un nascondiglio.

### 1.4 ⚠️ Copy-on-write per concorrenza futura — overstatement

**Vero per i value objects**: ogni mutazione di Definition / Graph /
ExecutionContext ritorna una nuova istanza congelata. Una `Definition` o
`Graph` frozen è safe da condividere tra thread.

**Falso per lo stato durabile**:
`adapters/memory/storage_state.rb` ha read-modify-write loops senza alcun
meccanismo di concorrenza:

```ruby
# storage_state.rb (pattern ricorrente)
row = fetch_workflow!(state, id)
unless row[:state] == from
  raise StaleStateError, ...
end
row[:state] = to
```

Due thread che chiamano `transition_workflow_state` sullo stesso workflow in
parallelo → race condition con lost update. Il commento in cima del file
dichiara "single-process" — è onesto. Ma "copy-on-write per concorrenza
futura" implica un design di concorrenza che **non è stato disegnato**.

CoW dei value objects è una **precondizione necessaria** per la concorrenza,
non sufficiente. Per arrivare a concorrenza vera serve uno di:

1. Spostare TUTTO lo stato dietro un Storage transazionale (SQLite/Postgres,
   roadmap S0). Allora il Memory adapter è solo per testing e il Runner non
   ha bisogno di nulla.
2. Disegnare un protocollo CAS/MVCC al livello del port `Ports::Storage`. Es.
   `transition_workflow_state(id:, from:, to:, expected_version:)`.

Il primo è il path implicito della roadmap. Il secondo non è iniziato.

**Verdetto vision**: "CoW per concorrenza futura" è vero solo per i value
objects passati attraverso il kernel (Definition, ExecutionContext, eventi).
Lo stato condiviso (storage) **non** è preparato. Chiarisci il claim nel
README come "frozen value objects safe to share; concurrent storage requires
SQLite/durable adapter (S0)".

### 1.5 ❌ "Bilanciamento perfetto OOP/FP" — retorica

Il codice è **layered**, non bilanciato:

- Value objects → FP puro (Data.define + frozen_copy).
- Result/Success/Failure → mini-monade FP.
- Step → classe OOP con `#call` (`step/base.rb:24`).
- Runner → orchestrator OOP con stato implicito viaggiante (`RunContext`
  attraverso ~15 metodi privati, `runner.rb:102-127, 200-225, 227-265`).
- Storage adapter → OOP classico (mutation tracker dentro StorageState).

Non c'è composizione orizzontale tra i livelli. Non puoi comporre due Runner
in pipeline. Non puoi comporre due Await. Il "bilanciamento" è in realtà
"ogni layer sceglie il paradigma comodo".

Niente di sbagliato in questo — è pragmatismo. Ma chiamarlo "bilanciamento
perfetto" è retorica. Più onesto: "FP per i valori, OOP per la coordinazione,
ports per le dipendenze esterne".

### 1.6 ✅ Ruby idiomatico — buono, con un'eccezione

**Bene**:

- Niente `attr_accessor` (`runner.rb:31-44` solo `attr_reader`, e il cop
  `Dag/NoMutableAccessors` lo enforce).
- Niente `method_missing`, niente `define_method` magico.
- `Data.define` per ogni value object.
- Lazy `enum_for` su `each_predecessor`/`each_successor`
  (`graph.rb:394, 400`) — pattern Ruby corretto.
- `private_constant` (`runner.rb:187, 309`) per le costanti interne.

**Eccezione documentabile, non sbagliata**: il pattern "custom factory []"

```ruby
class << self
  remove_method :[]
  def [](kw:); new(...); end
end

def initialize(kw:); validate!; super(...); end
```

è ripetuto in ~9 file (success.rb:13-31, failure.rb:11-21, waiting.rb:10-28,
run_result.rb:9-25, event.rb, step_input.rb, intent.rb:9-20,
prepared_intent.rb:22-86, record.rb:47-144). È un trick conosciuto per
sostituire il costruttore positional di `Data.define` con uno keyword-only,
ma è ~10-15 righe di boilerplate per file. Vedere §3.1.

### 1.7 ⚠️ DRY — vero per validation, falso per il pattern Data.define

**Vero**: `validation.rb` (182 LOC, 14 helper) è centralizzato, ben usato e
recentemente refactored (commit `45b5257`, `480d187`, `95786de`). Ogni
costruttore di value object lo invoca ai confini. Esempi:
prepared_intent.rb:107-115, record.rb:172-185, waiting.rb:49-58.

**Falso**: ~9 file ripetono il pattern `class << self; remove_method :[];
def []; end; end; def initialize; validate; super; end`. Stima conservativa:
~150-200 righe di duplicazione "soft" attraverso il sotto-sistema di value
objects. La duplicazione è regolare, non casuale, ma non è eliminata.

`CLAUDE.md` dice "Avoid `method_missing`, broad metaprogramming, or generic
'validate schema' layers". È una scelta consapevole di **vivere con la
duplicazione** invece di scivolare in metaprogramming. Antirez approverebbe
la motivazione. Ma allora cancella il claim "DRY" come universale. Diventa:
"DRY per le check di validazione; duplicazione regolare e accettata per la
forma dei value object".

### Riassunto vision

| Claim                              | Stato       |
| ---------------------------------- | ----------- |
| Zero dipendenze                    | ✅ vero     |
| Monadi                             | ⚠️ parziale |
| Tipi dati immutabili               | ✅ vero     |
| CoW per concorrenza futura         | ⚠️ parziale |
| Bilanciamento OOP/FP               | ❌ retorica |
| Ruby idiomatico                    | ✅ vero     |
| DRY                                | ⚠️ parziale |

Tre veri, tre parziali con onestà del codice ad ammetterlo, uno retorico.

---

## 2. Cosa brilla davvero

Antirez-style: chi ha scritto questo ha letto Wadler **e** ha shippato Ruby
in produzione. Cose specifiche che meritano d'essere viste:

- **`Result.assert_result!`** (`result.rb:54-57`) — beccare il "forgot to
  wrap" è il bug #1 di chi inizia con monadi. Enforced al limite del block,
  con messaggio puntuale.
- **`Result.exception_failure`** (`result.rb:44-51`) — un solo posto fa il
  contratto `{code:, message:, error_class:, **extras}`. Riusato in
  `runner.rb:428` e nei test. Niente drift.
- **Niente Enumerable mixin su Graph** — scelta deliberata, esposta da
  `each_node`/`each_edge`. Decision-by-refusal.
- **`graph.rb:394-401`** — `each_predecessor` **e** `each_successor` esistono
  entrambi. Sono usati in `runner.rb:147` (`each_predecessor`) e disponibili
  per il chiamante.
- **`runner.rb:142-161` `build_run_context`** — precomputa
  `predecessors_by_node` una volta per `#call`, evita `set.dup` per nodo nel
  loop principale. Hot-path optimization motivata.
- **`runner.rb:382-386` `storage_overrides?`** — verifica con
  `method.owner != Ports::Storage` se l'adapter implementa il fast-path
  ottimale o se il Runner deve fare il fallback. Trick semplice, robusto.
- **`runner.rb:177-184` `append_workflow_started_once`** — l'idempotenza è
  fatta scansionando il primo evento, non con un flag in storage. Survives
  retry, survives crash.
- **`runner.rb:440-453` `finalize`** — il commento esplicita il design: NO
  fallback a `:waiting` se non c'è almeno un nodo waiting; surface `:failed`
  con `diagnostic: :no_eligible_but_incomplete`. Onestà sopra eleganza.
- **`runner.rb:54-57`** — i 7 keyword sono richiesti, niente default
  injection di port nascosti. Il cop `Dag/NoThreadOrRactor` enforce
  l'assenza di `Thread`/`Mutex`/`Queue`/`Ractor` nell'intero `lib/dag/**`.
- **Test fuzz su Graph** — `spec/graph_fuzz_test.rb` (708 LOC) e
  `spec/graph_test.rb` (1235 LOC). 100% line + 90% branch floor in
  `spec/test_helper.rb`. Per una libreria foundation è il livello giusto.
- **Validation centralizzato e usato uniformemente** (`validation.rb`).
- **Errori gerarchici e specifici** (`errors.rb` + `effects/*_error.rb`).

---

## 3. Critiche reali (in ordine di priorità)

### 3.1 Priorità ALTA — DRY mancato sui value objects

**Problema**: 9 file (`success.rb`, `failure.rb`, `waiting.rb`,
`run_result.rb`, `event.rb`, `step_input.rb`, `intent.rb`,
`prepared_intent.rb`, `record.rb`) ripetono la stessa struttura:

```ruby
Foo = Data.define(:a, :b, :c) do
  class << self
    remove_method :[]
    def [](a:, b: default, c: {})
      new(a: a, b: b, c: c)
    end
  end

  def initialize(a:, b: default, c: {})
    Validation.foo!(a, "a")
    Validation.bar!(b, "b") if b
    DAG.json_safe!(c, "$root.c")
    super(a: a, b: DAG.frozen_copy(b), c: DAG.frozen_copy(c))
  end
end
```

Ripetuto, in alcuni casi, con 12+ campi (`record.rb` ha 21 campi e ~150
righe di sole boilerplate dichiarative).

**Impatto**: la vision "DRY" è la più colpita. Tutto il resto del kernel
**è** DRY; questo strato è chiaramente non.

**Proposte alternative (rispettose della vision)**:

Opzione A — **un helper dedicato, non metaprogramming generico**.

```ruby
module DAG
  def self.frozen_value(*field_names, &validate)
    Data.define(*field_names) do
      define_method(:initialize) do |**kwargs|
        instance_exec(kwargs, &validate) if validate
        super(**kwargs.transform_values { |v| DAG.frozen_copy(v) })
      end
    end
  end
end
```

Ma `CLAUDE.md` esplicitamente bandisce "broad metaprogramming". Quindi:

Opzione B (**raccomandata**) — **vivi con la duplicazione, ma estrai i
pezzi ripetuti che non richiedono metaprog**:

- `frozen_copy` è già fatto.
- Aggiungi `Validation.json_safe_at!(value, label)` come alias di
  `DAG.json_safe!` per uniformare il chiamante.
- **Documenta** la regolarità del pattern in `CLAUDE.md` come "intentional
  duplication: every value object follows the same skeleton; do not
  refactor without removing 200 LOC and gaining substantial type safety".

Opzione C — **drop "remove_method :[]"**. È un trick per nascondere il
costruttore positional di `Data.define`. Se accetti `Foo.new(a: ..., b: ...)`
ovunque, perdi 8 righe per file. Ma perdi anche default kwargs e la firma
esplicita del costruttore pubblico. Trade-off non vincente.

**La mia raccomandazione**: Opzione B. Lasciare il pattern, dichiararlo
intenzionale in `CLAUDE.md`, e considerare il claim "DRY" come "DRY dove non
costa metaprogramming".

### 3.2 Priorità ALTA — `Effects::Await` chiamato "monade" senza esserlo

**Problema**: `effects/await.rb:5` "Monad-like step helper". Falso. Vedi
§1.2.

**Fix proposto** (10 minuti):

```ruby
# Helper to translate an effect snapshot into a legal step result. On
# `:succeeded` it yields the effect result to a continuation; on
# `:failed_terminal` it returns Failure; on `:failed_retriable` and
# `:reserved`/`:dispatching`/missing it returns Waiting.
#
# This is NOT a monad: there is no `bind`/`pure`/`flat_map` and two
# `Await.call` cannot be composed without going through `Result#and_then`.
# The block return value is type-checked at the boundary (line 26) so
# the contract stays explicit.
```

E rinomina mentalmente: non è `Await` come un Future, è
`Effects.translate_snapshot` con continuation.

### 3.3 Priorità MEDIA — `RunResult` non valida `state`

**Problema**: `run_result.rb:27-37` accetta qualsiasi Symbol come `state`.
Tutti gli altri value object validano i campi enumerati con
`Validation.member!`. RunResult no.

**Costruttore unico**: solo il Runner costruisce `RunResult`
(`runner.rb:471-477`), e passa solo i 4 valori validi
(`:completed | :paused | :waiting | :failed`). Ma se la libreria espone
`RunResult.new` come API pubblica (lo è — `@api public` a `run_result.rb:7`),
un caller esterno può costruirne uno con stato spazzatura.

**Fix** (3 righe):

```ruby
# Aggiungi nelle costanti pubbliche o in run_result.rb
RUN_RESULT_STATES = %i[completed paused waiting failed].freeze

# In initialize
DAG::Validation.member!(state, RUN_RESULT_STATES, "state")
```

### 3.4 Priorità MEDIA — `canonical_committed_attempt` ottimizzazione locale fragile

**Problema**: `runner.rb:393-412`. 19 righe di mutation loop con tre
variabili (`best`, `best_id`, `candidate_id`) per evitare l'allocazione di un
Array intermedio. Il commento (`runner.rb:388-392`) **giustifica** invece di
**spiegare**.

**Quanto vale l'ottimizzazione?** Per un workflow con 100 nodi e ~3 attempts
per nodo, sono ~300 array di 2 elementi e ~300 stringhe per `Runner#call`.
Su qualunque profilo realistico, è polvere.

**Quanto costa?** Ogni reviewer deve fermarsi 30 secondi a verificare che lo
stato `best_id ||= best.fetch(:attempt_id).to_s` non leak across iterazioni
quando `best` viene riassegnato (linea 401: `best_id = nil` lo resetta —
corretto, ma serve il check mentale).

**Proposta alternativa**:

```ruby
def canonical_committed_attempt(attempts)
  attempts
    .select { |a| a[:state] == :committed }
    .max_by { |a| [a.fetch(:attempt_number), a.fetch(:attempt_id).to_s] }
end
```

3 righe. Equivalente. Più lente di 1-2 microsecondi. **Migra l'ottimizzazione
allo storage adapter** (`Memory::Storage` la fa con un dispatch al
`storage_state`; SQLite la farà con `ORDER BY attempt_number DESC,
attempt_id DESC LIMIT 1`). Il Runner non dovrebbe sapere.

### 3.5 Priorità MEDIA — `effective_context` con fallback O(predecessori) per nodo

**Problema**: `runner.rb:353-379`. Se lo storage non override
`list_committed_results_for_predecessors` (default port → fallback), il
Runner fa una query `list_attempts` per **ogni predecessore**, per **ogni
nodo eseguito**. Per un layer con N nodi e M predecessori medi, sono
O(N×M) round-trips a storage.

Il fast-path (`storage_overrides?` linea 367) salva la situazione su Memory
adapter; ma lascia il default port debole.

**Proposta**:

- Spostare `list_committed_results_for_predecessors` da extension opzionale
  a metodo richiesto del port `Ports::Storage`.
- L'implementazione default può vivere come module helper riusabile dagli
  adapter, non come fallback runtime nel Runner.

Costo: refactoring del port (`ports/storage.rb`, ~5 righe), eliminazione di
`storage_overrides?` (3 righe in `runner.rb:382-386`), semplificazione di
`committed_results_for_predecessors` a singolo path.

### 3.6 Priorità MEDIA — `handle_outcome` mescola decisione e side-effect

**Problema**: `runner.rb:227-265`. Il `case result` decide simultaneamente:

1. Lo stato del nodo (`:committed | :pending | :waiting | :failed`).
2. Il tipo di evento (`:node_committed | :node_failed | :node_waiting`).
3. Il payload dell'evento (3 forme diverse).
4. Se il workflow deve transire a `:paused`/`:failed`.
5. Cosa restituire al loop (`:continue | :paused | :failed_terminal`).

E IO immediato: `commit_and_emit` chiama storage + event_bus.

Test isolati della logica di retry sono difficili: per testare "fallimento
retriable con budget esaurito → terminale" devi simulare storage che
risponde a count_attempts, begin_attempt, commit_attempt,
transition_workflow_state — è quasi un test integrazione.

**Proposta**: separare in due metodi:

```ruby
# pure: input result + budget → output decision
def decide_outcome(result, attempt_number, max_attempts)
  case result
  when DAG::Success
    Decision.committed_success(result)
  when DAG::Waiting
    Decision.waiting(result)
  when DAG::Failure
    if result.retriable && attempt_number < max_attempts
      Decision.retriable_failure(result)
    else
      Decision.terminal_failure(result)
    end
  end
end

# impure: applies the decision
def apply_outcome(run, node_id, attempt_id, attempt_number, decision)
  ...
end
```

Costo: +30-40 LOC, ma test della decisione diventano property-style.

Trade-off: il codice attuale è denso ma in **un solo posto**. Se preferisci
"un posto solo per la verità" sopra "testabilità isolata" — non ti sbagli.
Antirez approverebbe entrambi gli approcci, dipende dalla traiettoria
prevista del codice (più stati di outcome → più valore della separazione).

### 3.7 Priorità BASSA — `storage_state.rb` monolitico (760 LOC)

Confessato dal codice stesso (commento iniziale + `CLAUDE.md`). È il punto
dove l'immutabilità si rompe per design. Quando arriverà SQLite (S0 in
`ROADMAP.md`), questo file sarà la blueprint.

**Proposta**: split per dominio prima di S0. Workflow CRUD, Attempt CRUD,
Effect ledger, Event log → 4 file da ~150-200 LOC. Niente cambio di
comportamento, solo chiarezza architettura. La porta `Ports::Storage`
(`ports/storage.rb`, 338 LOC) è già il contratto unico — facile splittare
l'adapter dietro.

Costo: ~2h di refactoring meccanico, zero rischio.

### 3.8 Priorità BASSA — Snapshot `Effects::Record#to_snapshot` leak

**Problema**: `record.rb:223-225` espone `payload_fingerprint`,
`not_before_ms`, `external_ref` agli step via `metadata[:effects]`. Sono
campi infrastrutturali (lease, idempotenza). Lo step **può** ignorarli, ma
li vede.

**Proposta**: filtra `RECORD_SNAPSHOT_FIELDS` (`record.rb:5-19`) ai soli
campi semantici (`id`, `ref`, `type`, `key`, `payload`, `blocking`, `status`,
`result`, `error`, `metadata`). Esclude `payload_fingerprint` (idempotenza
storagica), `external_ref` (lease integration). 4 righe.

Trade-off: rompe API se qualcuno già legge `payload_fingerprint` dallo
snapshot. Vista la fase alpha (memoria utente), accettabile.

### 3.9 Priorità BASSA — Ridondanza `Intent` → `PreparedIntent` → `Record`

`type, key, payload, metadata` sono campi in tutti e tre. La
`prepared_intent.rb:69-85 from_intent` e `record.rb:101-143 from_prepared`
mitigano il problema (factory che lifta). Ma:

- `validate_ref_part!` è chiamato in `intent.rb:23-24`,
  `prepared_intent.rb:105-106`, `record.rb:173-174`.
- Validazione di `payload` come json_safe è in tutti e tre.
- Validazione di `type, key` come stringhe è in tutti e tre.

**È evitabile?** Solo con composition (`Record { intent:; durability:; ... }`)
che richiederebbe accessor delegation per ergonomia (`record.type` al posto
di `record.intent.type`). In Ruby, `Forwardable.def_delegators` fa il lavoro,
ma aggiunge una dipendenza concettuale.

**Verdetto**: trade-off accettabile. La duplicazione è regolare, validata,
e ogni livello aggiunge campi reali. Cambierei solo se cambiassi il modello
(es. astrarre `EffectIdentity = Data.define(:type, :key, :payload, :metadata)`
e tenerlo come campo in PreparedIntent/Record). Non è un cambio piccolo —
non lo farei senza un trigger forte.

---

## 4. Proposte concrete che rispettano la vision

Ordinate per costo/beneficio:

| #   | Cambiamento                                                                                  | Costo  | Vision-aligned                            |
| --- | -------------------------------------------------------------------------------------------- | ------ | ----------------------------------------- |
| 1   | Rinomina commento `Effects::Await` "Monad-like" → "Effect snapshot dispatcher" (§3.2)        | 10min  | sì — onestà semantica                     |
| 2   | `Validation.member!(state, RUN_RESULT_STATES)` in `RunResult#initialize` (§3.3)              | 15min  | sì — DRY/uniformità                       |
| 3   | Filtra campi infrastrutturali da `Record#to_snapshot` (§3.8)                                 | 30min  | sì — separazione semantica/infra          |
| 4   | Sostituisci `canonical_committed_attempt` con `select.max_by` (§3.4)                         | 20min  | sì — leggibilità sopra micro-perf         |
| 5   | Promuovi `list_committed_results_for_predecessors` a port-required (§3.5)                    | 1h     | sì — semplifica fast/slow path            |
| 6   | Documenta CoW limitato a value objects + storage-CoW pendente di SQLite (§1.4)               | 30min  | sì — onestà del claim                     |
| 7   | Documenta in `CLAUDE.md` che il boilerplate Data.define è intenzionale (§3.1)                | 30min  | sì — chiude il falso claim DRY            |
| 8   | Split `storage_state.rb` per dominio prima di S0 (§3.7)                                      | 2h     | sì — preparazione SQLite                  |
| 9   | Separa `decide_outcome` da `apply_outcome` in Runner (§3.6)                                  | 2h     | dipende — testabilità sopra densità       |
| 10  | Rimuovi `REVIEW.md` o spostalo in `docs/legacy/`                                             | 5min   | sì — pulizia working tree                 |

Totale "low-hanging" (1-7): ~3h. Sposterebbero la honest-claim count da 3/7
a 6/7 e migliorerebbero leggibilità senza toccare il design.

---

## 5. Verdetto stile Antirez

Codice **serio**, scritto da chi conosce sia Wadler sia il fatto che in
produzione i bug arrivano alle 3 di notte. Tre marcatori:

1. **`Result.assert_result!`** beccare il bug più comune al boundary del
   block — questo è esperienza, non teoria.
2. **Cop custom** (`Dag/NoThreadOrRactor`, `Dag/NoMutableAccessors`,
   `Dag/NoInPlaceMutation`, `Dag/NoExternalRequires`) — la disciplina è
   enforced, non confidata.
3. **`finalize` con commento di design** (`runner.rb:435-453`) — surface
   `:failed` con diagnostic invece di forgive a `:waiting`. Onestà sopra
   eleganza.

Ma **non chiamiamolo "monadi e bilanciamento OOP/FP"**. Sono parole. Quello
che hai è:

- Un kernel deterministico immutabile, con value objects ben validati e
  congelati ai confini.
- Una mini-monade legittima su `Success | Failure`.
- Un Runner orchestratore OOP, denso ma coerente.
- Un'astrazione effect ledger con due strati di lift (Intent →
  PreparedIntent → Record) ridondanti ma funzionali.
- Uno storage in-memory mutable single-process, dichiarato come tale.

**Niente bug critici. Tre debt manageable**:

1. Boilerplate Data.define ripetuta (~200 righe). Vivila o documentala.
2. Una manciata di overstatement nei commenti / vision (Await "monad-like",
   CoW per concorrenza). Riformula.
3. Un'ottimizzazione locale (`canonical_committed_attempt`) e un fallback
   O(N) (`effective_context`) che andrebbero spostati al port.

**Vision validata con due correzioni**:

1. **Sii preciso sui monadi**: hai uno solo (`Result`). `Effects::Await` è
   un dispatcher su snapshot di effetti. Non è meno utile, è solo un'altra
   cosa. Cambia il vocabolario, non il design.
2. **Decidi cosa significa "concorrenza futura"**: se è multi-thread Ruby
   in MRI, il GIL ti salva e CoW dei value objects è sufficiente per la
   parte "dati". Lo storage rimane single-writer. Se è multi-process o
   multi-host (S0+), il design del port `Storage` deve esprimere CAS o
   versioning — e non lo fa ancora. Definisci il target.

Tutto il resto — DRY, immutabilità, idiomaticità, zero deps, ports, tests —
**regge**.

Useresti questa libreria? Sì, se il dominio è "workflow deterministico
single-process con futuro durable adapter". No, se ti aspetti
multi-process out-of-the-box.

Stato della codebase: **production-ready alpha** per il workload dichiarato.
Niente da riscrivere. Una lista di nit di tre ore di lavoro per chiudere il
gap tra il codice e la sua narrazione.

---

## 6. Verifiche fatte (per onestà del processo)

Prima di scrivere questa review ho controllato di persona, perché due dei
tre agent di esplorazione hanno fornito informazioni inesatte:

| Verifica                                                       | Risultato                                                |
| -------------------------------------------------------------- | -------------------------------------------------------- |
| `Graph#each_successor` esiste?                                 | ✅ sì, `graph.rb:400` (un agent sosteneva il contrario)  |
| `Graph#each_predecessor` esiste?                               | ✅ sì, `graph.rb:394`                                     |
| `REVIEW.md` è sul progetto attuale?                            | ❌ no, è di un altro progetto (`Steps::Exec`, etc.)       |
| `Result` è una vera mini-monade?                               | ✅ sì, su Success+Failure (Waiting escluso by design)     |
| `Effects::Await` è una monade?                                 | ❌ no, è un dispatcher con continuation                   |
| `RunResult` valida `state`?                                    | ❌ no, `run_result.rb:27-37` non lo controlla             |
| `frozen_copy` è usato disciplinatamente?                       | ✅ sì, 36+ occorrenze in `lib/dag/**`                     |
| `Validation` è centralizzato?                                  | ✅ sì, `validation.rb` 14 helper, usato uniformemente     |
| `storage_state.rb` è davvero l'unica zona mutabile?            | ✅ sì, dichiarato + cop `Dag/NoInPlaceMutation`           |

Quindi: la review è basata su lettura diretta dei file, non solo su sintesi
degli agent. Le claim citate hanno tutte un `file:line` controllato.
