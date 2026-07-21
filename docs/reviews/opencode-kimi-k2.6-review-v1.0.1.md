# Code Review: ruby-dag v1.0.1

> Revisione completa del progetto `ruby-dag`.  
> Analisi onesta, basata su fatti, senza complimenti inutili.

---

## La tua visione: giusto e sbagliato

### Zero dipendenze esterne — Giusto, ma con un costo

È una scelta di design legittima, ma va compreso il prezzo che si paga.  
`ExecutionContext` effettua un `deep_dup` + `deep_freeze` completo ad ogni merge. Con librerie di strutture dati persistenti (es. `hamster`) si otterrebbe **structural sharing**, eliminando allocazioni sui rami non modificati.  
**Verdetto:** "Zero deps" è un vincolo, non un pregio in sé. Va accettato il trade-off prestazionale.

### Monadi — Parzialmente sbagliato

`Success` e `Failure` espongono `and_then`, `map`, `recover`. Mancano operazioni fondamentali: `value_or`, `tap`, `map_error`. Il commento in `lib/dag/result.rb` che giustifica l'esclusione è debole.

Il problema più grave è che **`Waiting` non è una monade**. Il tipo di ritorno dello step è quindi eterogeneo (`Success | Waiting | Failure`), e il `Runner` è costretto a pattern matching imperativo (`case result when DAG::Success...`).  
**Verdetto:** se dichiari di usare monadi, il tipo di ritorno deve essere chainable in modo omogeneo. Altrimenti non sono monadi, sono semplici value objects.

### Tipi immutabili — Corretto, con un buco

`DAG.frozen_copy` assume che se un oggetto è `frozen?` e non è Hash/Array, sia sicuro. Questo è falso: un `Set` frozen contenente elementi mutabili passa il controllo. Un oggetto custom con `freeze` superficiale passa. La validazione è troppo fiduciosa.

### Copy-on-write — Sbagliato nel nome

Quello che fai non è CoW, è **"copy every time"**. CoW vero implica che i dati condivisi tra versioni non vengono mai toccati. Tu fai `deep_dup` + `deep_freeze`, che attraversa l'intero albero. È una copia totale mascherata.
**Proposta:** rinomina il concetto in `ImmutableCopy` e elimina la parola "on-write", che è fuorviante.

### Bilanciamento OOP/FP — Sbagliato, c'è confusione di confine

Non c'è bilanciamento, c'è **mescolanza di paradigmi senza regola**:
- `Graph` è OOP classico con stato mutabile interno + `freeze`
- `StorageState` è programmazione procedurale C-style (`module_function`, stato passato esplicito)
- `Runner` è imperativo con flag `paused`/`failed`
- `Data.define` è FP

**Verdetto:** scegli. O il grafo è puro e immutable con builder separato (FP), o è un oggetto che si muta e poi si congela (OOP). Mescolarli senza una regola chiara è disordinato.

### Ruby idiomatico — A tratti

`module_function` per 760 linee di storage state è **anti-idiomatico** Ruby 3.4. Sovrascrivere `initialize` su `Data.define` per fare validazione è contro lo scopo di `Data.define` (documentato come: "for simple struct-like objects"; se serve validazione, usa una classe normale).

A favore: `each_predecessor` senza allocare Set è ben fatto.

### DRY — Nella media

Il pattern `storage_overrides?` è copiato in `Runner`, `MutationService`, `Dispatcher` (3 volte identico). La validazione sui `Data.define` custom è ripetuta ogni volta.

---

## Problemi concreti, file per file

### `lib/dag/graph.rb` (696 linee) — Fa troppe cose

Una sola classe gestisce:
- Mutazione
- Query transitive
- Topological sort
- Shortest path / longest path / critical path
- Subgraph
- Rendering Graphviz (`to_dot`)

**Problema:** `to_dot` non ha alcun motivo di esistere in questa classe. Se domani vuoi supportare Mermaid, aggiungi un altro metodo? Estrai un `DAG::Graph::DotFormatter`.

`shortest_path` e `longest_path` sono algoritmi generici su DAG pesati. Dovrebbero essere in `DAG::Graph::Algorithms` o moduli separati.

```ruby
def nodes
  frozen? ? @nodes : @nodes.dup.freeze
end
```
Questo è pericoloso: l'object_id del ritorno cambia a seconda dello stato interno. Chi usa il grafo come chiave di Hash prima e dopo `freeze` rompe i bucket. O ritorni sempre una copia, o mai. Non entrambi.

### `lib/dag/runner.rb` (497 linee) — Violazione di SRP

Gestisce:
1. Acquisizione workflow stato
2. Costruzione contesto esecuzione
3. Loop di scheduling layered
4. Esecuzione step + exception handling
5. Commit atomico + emissione eventi
6. Preparazione effects
7. Finalization (4 stati terminali)
8. Costruzione risultato

**Verdetto:** questa classe viola il Single Responsibility Principle in modo flagrante.

Il `canonical_committed_attempt` è ottimizzato con un loop manuale per evitare allocazioni. Questa ottimizzazione è **prematura**: se lo storage è memory, le allocazioni sono irrilevanti. Se lo storage è SQLite, questa logica dovrebbe essere una query `ORDER BY ... LIMIT 1`. Il fatto che esista questo sort manuale suggerisce che stai mischiando concern.

**Proposta:** spezza in `RunContextBuilder`, `NodeExecutor`, `WorkflowFinalizer`.

### `lib/dag/adapters/memory/storage_state.rb` (760 linee) — C-style Ruby

Il peggior file del progetto. Non per la mutabilità (giustificata), ma per la forma:

```ruby
module StorageState
  module_function
  def create_workflow(state, id:, ...)
    state[:workflows][id] = { ... }
  end
end
```

Ogni metodo prende `state` come primo argomento. Stai scrivendo **C con sintassi Ruby**.

La scusa "è l'unico posto dove mutare è permesso" non giustifica la forma procedurale. Una classe `MemoryStorageBackend` con `@state` come istanza variabile sarebbe incapsulata e testabile unitariamente. Invece hai un modulo con funzioni libere che operano su un hash passato dall'esterno.

**Proposta:** sostituisci con classi incapsulate, anche se internamente mutano. Es:

```ruby
class Adapters::Memory::Backend
  def initialize
    @workflows = {}
    @attempts = {}
  end

  def create_workflow(...)
    # opera su @workflows
  end
end
```

### `lib/dag/effects/dispatcher.rb` (339 linee) — Troppi compiti

`tick(limit:)` fa: claim, dispatch, normalizza risultato handler, marca success/failure, rilascia nodi waiting, aggrega report. Sono 5 operazioni diverse.

`HandlerOutcome` e `DispatchOutcome` sono `Data.define` con `initialize` sovrascritto solo per validare. Questo è boilerplate ripetuto.

### `lib/dag/ports/storage.rb` (338 linee) — Port monolitico

~30 metodi. Un port dovrebbe essere un contratto coeso. Qui hai:
- Workflow CRUD
- Node state machine
- Attempt lifecycle
- Event log append-only
- Effect ledger
- Lease management
- Claim logic

Questo non è un port, è un'interfaccia di database intero. Chi vuole scrivere un adapter SQLite deve implementare 30 metodi con semantica atomica complessa.

**Proposta:** spezza in port separati:
- `WorkflowStorage`
- `NodeAttemptStorage`
- `EventStorage`
- `EffectStorage`

Il runner dipende da 4 port invece di 1, ma ogni port ha 5-8 metodi. La barriera all'implementazione di un nuovo adapter crolla.

---

## Cosa funziona davvero

### 1. Atomic boundaries nel port storage

`commit_attempt` che committa risultato + stato nodo + evento + effects in un colpo è corretto. Senza questo, un crash tra scritture lascia workflow in stato irrecuperabile.

### 2. Custom RuboCop cops

`NoThreadOrRactor`, `NoMutableAccessors`, `NoInPlaceMutation`, `NoExternalRequires` sono un modo elegante di enforce architettura a compile time. Questo è DRY fatto bene: la regola è scritta una volta, applicata ovunque.

### 3. Pattern `storage_overrides?`

Permettere allo storage di sovrascrivere metodi "default" del runner è intelligente. Il runner ha un fallback generico, lo storage può ottimizzare. Questo pattern dovrebbe essere usato di più.

### 4. `ExecutionContext` come boundary type

Avere un tipo specifico per il contesto invece di un Hash generico previene molti bug. Il CoW (anche se copia totale) garantisce che uno step non corrompa il contesto degli altri.

### 5. Contract tests condivisi

`spec/support/storage_contract/` è la cosa più matura del progetto. Ogni adapter futuro deve passare questi test. Questo è testing fatto bene.

---

## Proposte alternative

### 1. Spezza `Runner` in 3 classi

```ruby
class Runner
  def call(workflow_id)
    workflow = acquire_running(...)
    context = RunContextBuilder.new(storage, ...).build(workflow_id, workflow)
    executor = NodeExecutor.new(storage, registry, ...)
    finalizer = WorkflowFinalizer.new(storage, event_bus, clock)
    # ... loop orchestrato ...
  end
end
```

Il runner diventa un orchestrator di ~100 linee.

### 2. Rendi `Result` una monade completa

Aggiungi:

```ruby
def value_or(default) = is_a?(Success) ? value : default
def tap = is_a?(Success) ? yield(self) : self
def map_error = is_a?(Failure) ? yield(self) : self
```

Considera di rendere `Waiting` un `Result` con `and_then` che restituisce `self` (short-circuit). Il tipo di ritorno diventa omogeneo e chainable.

### 3. Estrai algoritmi da `Graph`

```ruby
class Graph
  # solo struttura e mutazione
end

module Graph::Algorithms
  def self.shortest_path(graph, from, to) ... end
  def self.longest_path(graph, from, to) ... end
  def self.critical_path(graph) ... end
end

class Graph::DotFormatter
  def self.format(graph, name: "dag") ... end
end
```

`Graph` torna a fare una cosa sola.

### 4. Sostituisci `StorageState` procedurale con classi incapsulate

Vedi proposta nella sezione del file.

### 5. Spezza il port Storage in 4 port

Vedi proposta nella sezione del file.

### 6. Elimina `to_dot` da `Graph`

Spostalo in `lib/dag/formatters/dot.rb`. `Graph` non deve sapere cos'è Graphviz.

---

## Verdetto

Il progetto ha le fondamenta giuste: atomic boundaries, immutabilità sistematica, contract tests, cops architetturali. Ma soffre di:
- **classi troppo grandi** (`Runner`, `Graph`, `StorageState`)
- **mixing di paradigmi** senza regola chiara
- **monade incompleta** che non giustifica il nome

Non è un disastro. È un buon progetto con problemi di taglio.

**La cosa peggiore che puoi fare** è continuare ad aggiungere feature (R3 mutations, effects) senza prima spezzare `Runner`, `Graph`, e `StorageState`. Se arrivi a R4 con `Runner` a 700 linee, il progetto diventa unmaintainable.

**Raccomandazione:** prima di toccare roadmap R4, fai un refactoring che spezza i 3 file più grandi. Altrimenti stai costruendo su fondamenta che reggono, ma sono troppo affollate.
