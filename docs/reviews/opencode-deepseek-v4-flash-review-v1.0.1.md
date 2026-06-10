# Code Review: ruby-dag v1.0.1

*Recensione nello spirito di antirez — diretta, onesta, focalizzata sulla
semplicità e correttezza. 46 commit analizzati su master.*

---

## La tua visione — valutazione onesta

### Zero dipendenze esterne — **Raggiunto al 100%**

Solo stdlib Ruby: `digest`, `json`, `securerandom`. Niente Gemfile.lock
sorprese, niente CVEs transitive, niente "funziona sulla mia macchina".
Questo è il fondamento più solido del progetto. Rispetto.

### Monadi — **Parzialmente**

`Success` e `Failure` formano un Either monade con `and_then`, `map`,
`recover`. Funziona. I tipi sono immutabili, il `Result.try` cattura
eccezioni in modo pulito.

Ma `Waiting` è volutamente escluso dal `Result` marker. Lo step protocol
è `Success | Waiting | Failure`, non una monade a 3 stati. Il contratto
lo dice esplicitamente: *"Waiting is a valid step outcome, but it is not
a DAG::Result"*.

Questa è una scelta architetturale difendibile — `Waiting` ha semantica
diversa (non è un terminal value, è un "riprova dopo") — ma non chiamiamolo
"monadi" in senso pieno. Hai un Either monade e un tipo separato che il
Runner tratta come caso speciale nel suo state machine.

**Proposta**: Non cambiare. La chiarezza del contratto (3 outcome separati)
vale più della purezza algebrica. Se in futuro servisse una monade a 3
stati, si può unificare, ma oggi non serve.

### Tipi dati immutabili — **Fatelo bene**

`Data.define` ovunque. `deep_freeze` con cycle detection (visto!
`seen[value.object_id]`). `frozen_copy` come boundary helper. JSON safety
enforced in ogni costruttore. La disciplina è reale e applicata.

### Copy-on-write per mutazioni — **Onestamente: copia profonda, non CoW**

`ExecutionContext#merge` ritorna una nuova istanza ma fa deep-dup completo
dell'hash interno. Vero CoW (strutture condivise con lazy clone) sarebbe
più performante ma molto più complesso. Quello che hai è semanticamente
immutabile per copia. Funziona. Non cambiarlo — la complessità di vero CoW
non vale il beneficio per workflow con decine di nodi.

### Bilanciamento OOP e FP — **Il meglio del progetto**

Il Graph è OOP classico con stato interno mutabile prima del freeze. I
value objects (Success, Failure, Event, Intent, Record) sono FP puro. Il
Runner è un oggetto congelato che orchestra funzioni pure. `Step::Base` è
OOP con un contratto FP (`#call(StepInput) -> Success|Waiting|Failure`).
L'equilibrio è genuino e applicato coerentemente.

### Ruby idiomatico — **Sì, con un'eccezione**

`Data.define` + `remove_method :[]` + keyword constructor custom è una
pattern ripetuto ~15 file × 8 linee ≈ 120 linee di boilerplate. Funziona,
è esplicito, è debuggabile. La scelta è difendibile.

D'altro canto, la decisione di non includere `Enumerable` in Graph (per
evitare ambiguità `graph.map` = nodes? edges?) è idiomatica e coraggiosa.
Nomi in snake_case, `!` per metodi validanti, `module_function` — tutto
Ruby classico.

### DRY — **Promosso con riserva**

C'è una copia reale di `storage_overrides?` in:

- `runner.rb:382-386`
- `effects/dispatcher.rb:285-289`

Stessa logica, stesse 5 linee. Identiche. Questo è un DRY violation.

Anche `immutable_json_copy` è duplicato in:
- `effects/dispatcher.rb` classe `HandlerOutcome` (linea 40-46)
- `effects/dispatcher.rb` classe `DispatchOutcome` (linea 106-112)

Stesso file!

---

## Analisi per componente

### Graph (`lib/dag/graph.rb`, 696 linee) — **Voto 9/10**

Il miglior pezzo del progetto. Scelte giuste ovunque:

- Nodi come Symbol (`to_sym` su input)
- Edge come `Data.define(:from, :to, :metadata)` — primo cittadino
- Cycle detection O(V+E) su ogni `add_edge`
- Topological sort deterministico con tie-break ASCII ad ogni frontiera Kahn
- Lazy caching su freeze di layers, sort, roots, leaves, edges
- `each_node` / `each_edge` SOLI entry point di iterazione
- Senza `Enumerable` mixin — scelta coraggiosa e corretta
- Path algorithms (shortest, longest, critical) con topological relaxation
- `frozen_layers` che freeze ogni layer individualmente

```ruby
def freeze
  return self if frozen?
  @nodes.freeze
  @adjacency.each_value(&:freeze)
  @adjacency.freeze
  @reverse.each_value(&:freeze)
  @reverse.freeze
  @edge_metadata.each_value(&:freeze)
  @edge_metadata.freeze
  @cached_layers = frozen_layers(compute_topological_layers)
  @cached_sort = @cached_layers.flatten.freeze
  @cached_roots = nodes_with_no(@reverse).freeze
  @cached_leaves = nodes_with_no(@adjacency).freeze
  @cached_edges = compute_edges.freeze
  super
end
```

La `:nocov:` a linea 575-579 con spiegazione del perché è irraggiungibile
ma tenuta come difesa mostra attenzione ai dettagli rara.

**Cosa non mi piace**:
- `replace_node` è 20 linee. Non complesso, ma lungo.
- `relax` usa `Array(sources)` per normalizzare singolo/array — flessibilità
  che costa chiarezza nell'API.

### Runner (`lib/dag/runner.rb`, 497 linee) — **Voto 6/10**

Fa troppo. Un singolo orchestratore che:

1. `run_workflow` (linea 102-127) — loop principale con controllo flow
2. `acquire_running` (linea 129-139) — transizione stato
3. `build_run_context` (linea 142-161) — costruzione contesto
4. `build_step_instances` (linea 163-174) — caching step
5. `append_workflow_started_once` (linea 177-184) — emissione eventi
6. `eligible_nodes` (linea 189-198) — calcolo eligibility
7. `execute_node` (linea 200-225) — esecuzione singolo nodo
8. `handle_outcome` (linea 227-265) — gestione 3 outcome × 2+ sub-casi
9. `commit_and_emit` (linea 267-293) — commit atomico + eventi
10. `build_step_input` (linea 295-306) — costruzione input
11. `prepare_effects` (linea 311-328) — preparazione effetti
12. `effective_context` (linea 353-364) — merge contesto
13. `committed_results_for_predecessors` (linea 366-380) — batch query
14. `canonical_committed_attempt` (linea 393-412) — scelta attempt vincitore
15. `safe_call_step` (linea 414-429) — invocazione con safety net
16. `finalize` (linea 440-453) — terminal state machine
17. `transition_and_emit_terminal` (linea 455-458) — transizione atomica
18. `atomic_transition_with_event` (linea 463-468) — CAS + evento
19. `build_run_result` / `build_event` / `append_event` — factory

`handle_outcome` (38 linee) ha logica di retry, logica di commit,
emissione eventi, e transizione workflow in un unico case statement.

**Proposta concreta**: Estrarre:

- **`Eligibility`** (`eligible_nodes`, ~50 linee)
- **`OutcomeHandler`** (`handle_outcome` + `commit_and_emit`, ~100 linee)
- **`Finalizer`** (`finalize` + `build_run_result`, ~80 linee)

Il Runner resterebbe un orchestratore di ~200 linee. Ancora frozen,
ancora stateless, ancora zero dipendenze.

**Nota importante**: La logica è **corretta**. I test di fingerprint
deterministico a 100 run lo confermano. Ma 497 linee per un orchestratore
fanno male alla manutenibilità. Fallo quando tocchi il Runner per la
prossima feature.

### Memory::StorageState (`lib/dag/adapters/memory/storage_state.rb`, 760 linee) — **Voto 5/10**

Unico file mutabile in tutto `lib/dag/`. 760 linee. Nessuna struttura
interna. Qui è dove vivono i bug.

Il cop `Dag/NoInPlaceMutation` lo esenta — giustamente — ma 760 linee di
hash mutations, CAS checks, e bookkeeping è troppo per un singolo file.

I metodi spaziano da workflow lifecycle a node state a attempt management
a effect reservation a event log append a retry prepare. Ogni metodo muta
stato direttamente.

**Proposta**: Dividere in 3 sub-componenti sotto `StorageState`:

- **`StorageState::WorkflowStorage`** — create, load, transition, retry
- **`StorageState::NodeStorage`** — node states, attempts, abort
- **`StorageState::EffectStorage`** — effect reservation, claim, lease,
  release, mark

Ogni sub-componente resta l'unica fonte di mutazione per il suo dominio.
`StorageState` diventa un facade che delega. Il cop esenta il modulo,
non il singolo file.

### Effetti Subsystem (`lib/dag/effects/`, ~1078 linee totali) — **Voto 8/10**

Architettura solida: `Intent` → `PreparedIntent` → `Record` con status
set chiuso, lease management, handler dispatcher. La catena di
elaborazione è lineare e tracciabile.

`Dispatcher#tick` (linea 140-159) è pulito:

```ruby
def tick(limit:)
  now_ms = @clock.now_ms
  claimed = @storage.claim_ready_effects(limit:, owner_id: @owner_id,
                                         lease_ms: @lease_ms, now_ms: now_ms)
  outcomes = claimed.map { |record| dispatch_record(record) }
  DispatchReport[claimed:, succeeded: outcomes.map(&:succeeded_record).compact,
                 failed: outcomes.map(&:failed_record).compact,
                 released: outcomes.flat_map(&:released),
                 errors: outcomes.map(&:error).compact]
end
```

**DRY violations reali** (stesso file `dispatcher.rb`):

1. `storage_overrides?` identico a `runner.rb:382-386`:
   ```ruby
   def storage_overrides?(method_name)
     return false unless @storage.respond_to?(method_name)
     @storage.method(method_name).owner != DAG::Ports::Storage
   end
   ```

2. `immutable_json_copy` duplicato in `HandlerOutcome` e `DispatchOutcome`:
   ```ruby
   def immutable_json_copy(value)
     return nil if value.nil?
     return value if value.frozen?
     DAG.frozen_copy(value)
   end
   ```

Entrambi da estrarre in helper condivisi (`DAG::Ports::Storage` o
`DAG::Effects` come module_function).

### Validation (`lib/dag/validation.rb`, 182 linee) — **Voto 7/10**

20 metodi che fanno tutti `is_a?` + raise con messaggio. `array!`,
`hash!`, `string!`, `symbol!`, `integer!`, `boolean!`, `string_or_symbol!`,
`optional_hash!`, `optional_integer!`, `optional_instance!`,
`positive_integer!`, `nonnegative_integer!`, `member!`, `revision!`,
`node_id!`, `dependency!`, `nonempty_string!`, `instance!`.

Potresti ridurlo a ~5 metodi polimorfi:
```ruby
def type!(value, klass, label)
def optional!(value, klass, label)
def range!(value, range, label)
```

Ma onestamente: funziona. È esplicito. Ogni chiamata dice esattamente
cosa controlla. Il costo di refactoring non vale il beneficio. Il mio
voto è "lascia stare, funziona".

### Test Suite (52 file, ~7000 linee, 490 test) — **Voto 9/10**

Eccellente. Cose che pochi progetti fanno:

- **Graph fuzz test** (`graph_fuzz_test.rb`, 708 linee, 25 test) con seed
  deterministico (`DAG_FUZZ_SEED`) e iterazioni configurabili
  (`DAG_FUZZ_ITERATIONS`). Checks differenziali contro implementazione naive.
- **Fingerprint stability test** a 100 run indipendenti con stesso risultato
  (`context_merge_order_test.rb`)
- **Crash simulation** (`CrashableStorage`) con recupero via `resume`
  (`resume_after_crash_test.rb`)
- **Storage contract framework** (`spec/support/storage_contract/`) —
  moduli condivisi testabili da qualsiasi adapter (SQLite futuro)
- **RuboCop cops test** (`spec/r0/rubocop_cops_test.rb`) — verifica che
  i cop custom funzionano

**Gaps reali**:

| Gap | Impatto |
|-----|---------|
| R3 mutation test superficiale (7 file, test singoli) | Medio — mutation è la parte meno usata |
| `DAG::Validation` senza test unitari | Basso — testato indirettamente |
| `Runner#call` con workflow sconosciuto | Medio — errore non documentato |
| `Dispatcher#tick` con storage vuoto | Basso — comportamento ovvio |
| `resume` con workflow `:failed` (solo 1 test) | Medio — resume da failed è caso critico |
| `replace_subtree` multi-entry/multi-exit | Medio — non testato |

Ma 490 test per 6000 linee di kernel è un rapporto eccellente.

### Errori minori trovati

- **`storage_overrides?`** duplicato in 2 file
- **`immutable_json_copy`** duplicato in 2 classi dello stesso file
- **Event types count**: `CONTRACT.md` dice 10, il codice ne ha 13
  (mancano probabilmente quelli aggiunti con effects/mutations)
- **`RuntimeProfile.defaults`**: `max_attempts_per_node: 3` e
  `max_workflow_retries: 0` non sono usati dal Runner — sono default nel
  value object ma il costruttore di Runner non applica default. I default
  sono applicati da chi crea il profilo. La documentazione dice
  "Defaults are max_attempts_per_node: 3" ma chi crea workflow deve
  ricordarsi di passarli.

### Coerenza architetturale

**Hexagonal architecture**: Intatta. Nessun boundary violation trovato.
Il kernel non chiama mai adattatori direttamente, solo attraverso port
interfacce. Le dipendenze vanno tutte verso l'interno.

**Cop enforcement**: I custom cop funzionano. `NoThreadOrRactor` ha
catturato:
```
lib/dag/adapters/memory/event_bus.rb: subscriber dispatch via `dup`
```
che è stato fixato. Il cop ha valore.

**Determinismo**: La scelta di `id.to_s` ASCII tie-break in ogni
frontiera Kahn garantisce bit-identicità tra run. I test lo confermano.

---

## Riepilogo

| Componente | Voto | Giudizio |
|---|---|---|
| Graph | 9/10 | Pulito, testato, deterministico. Il meglio del progetto |
| Runner | 6/10 | Corretto ma troppo lungo. 497 linee per un orchestratore |
| StorageState | 5/10 | 760 linee mutabili senza struttura. Il rischio più grande |
| Effetti | 8/10 | Architettura solida, 2 DRY violations minori |
| Validation | 7/10 | Funziona, verboso ma esplicito. Lascia stare |
| Immutabilità | 9/10 | `deep_freeze` con cycle detection. Fatto bene |
| Test | 9/10 | Eccellente. R3 sottotestato |
| DRY | 6/10 | 3 violations identificate |
| Vision match | 8/10 | Monadi e CoW non sono esattamente quello che dici |

### Cosa lascerei invariato

1. Sistema di immutabilità e `frozen_copy`
2. Struttura ports-and-adapters (hexagon intatto)
3. Scelta di non includere `Waiting` in `Result`
4. Graph layer nella sua interezza
5. Pattern `Data.define` + `remove_method :[]` — verboso ma chiaro
6. JSON safety enforcement nei costruttori — ha valore difensivo
7. Custom RuboCop cops — funzionano e hanno già catturato bug

### Cosa cambierei (per priorità)

1. **Runner** (priorità: media) — Estrarre `Eligibility`, `OutcomeHandler`,
   `Finalizer` quando tocchi il Runner per la prossima feature.
2. **StorageState** (priorità: media-bassa) — Dividere in 3 sub-componenti.
   Fallo quando aggiungi un nuovo metodo allo storage.
3. **storage_overrides?** (priorità: bassa, 5 minuti) — Estrarre in
   `DAG::Ports::Storage` come helper o in un module condiviso.
4. **immutable_json_copy** (priorità: bassa, 2 minuti) — Refactor inline
   nel dispatcher o in un helper condiviso.
5. **CONTRACT.md event types** (priorità: bassa, 1 minuto) — Allineare
   la lista ai 13 tipi reali.
6. **RuntimeProfile defaults** (priorità: bassa) — O rimuovere i default
   dal value object o farli applicare dal Runner.

### La domanda che conta

*Vale la pena rifattorizzare il Runner oggi?*

Se il Runner funziona (e i test dicono di sì) e non hai un bug da fixare
lì dentro, no. Il rischio di introdurre regressioni in 490 test non vale
il beneficio estetico. Segna il refactor come prossimo passo quando
tocchi quel file per una nuova feature. I refactor si pagano da soli
quando riducono il costo della prossima modifica.

---

## Conclusione

Hai costruito un workflow engine pulito, deterministico, zero-dependency.
Le scelte architetturali sono coerenti (hexagon, immutabilità, ports-and-
adapters), il testing è di alta qualità (fuzz, crash simulation, fingerprint
stability), e i custom cop proteggono i constraint di progetto.

I difetti sono di **scala**, non di **architettura**. Runner è 497 linee
invece di 200. StorageState è 760 linee invece di 3×250. `storage_overrides?`
è duplicato. Niente di strutturale.

Questo è un buon segno. Un progetto con difetti solo di scala è un
progetto con le fondamenta giuste. I refactor sono chirurgici e
opzionali, non sistemici e obbligatori.

*— antirez (well, channeling his spirit: simplicity is the ultimate
sophistication)*
