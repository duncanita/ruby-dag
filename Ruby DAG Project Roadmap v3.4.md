# Master Playbook & RFC Unificato: `ruby-dag` ➔ `delphic`

**Versione:** 3.4.1 — implementation-ready, Ractor rimossi; concorrenza via processi e fiber; S0 SQLite spostata nel consumer `delphic`  
**Target:** Ruby 3.4+  
**Filosofia:** kernel funzionale + ports/adapters + immutabilità profonda + storage Compare-And-Swap + concorrenza tramite processi isolati e fiber cooperative; nessun Ractor.  
**Ordine esecutivo:** completare e taggare `ruby-dag` v1.0, poi implementare S0 come adapter SQLite dentro `delphic`, poi procedere con D0-D4.

**Decisione vincolante v3.4.1:** non esiste più una fase obbligatoria come gemma/repo separato `ruby-dag-sqlite`. `ruby-dag` resta una gemma zero runtime dependency e non assorbe SQLite. La persistenza durable iniziale vive in `delphic`, sotto namespace `Delphic::Adapters::Sqlite`, e implementa il port pubblico `DAG::Ports::Storage` definito da `ruby-dag` v1.0. L'eventuale estrazione futura in una gemma `ruby-dag-sqlite` è consentita solo come refactor, non come prerequisito del roadmap.

> Questo documento è la fonte operativa unica. Ogni fase è progettata per essere eseguita punto per punto da una persona o da un coding agent. Una fase non parte finché tutti i suoi DoD non sono verdi. Tutti i file in "Output file obbligatori" devono esistere alla chiusura della fase, anche solo come stub motivati.

---

## Indice

1. [Regola operativa principale](#1-regola-operativa-principale)
2. [I 4 pilastri architetturali](#2-i-4-pilastri-architetturali)
   - [Mappatura dei domini](#25-mappatura-dei-domini)
3. [Decisioni di progetto congelate](#3-decisioni-di-progetto-congelate)
4. [Grafo delle dipendenze fra fasi](#4-grafo-delle-dipendenze-fra-fasi)
   - [Danza operativa end-to-end](#41-danza-operativa-end-to-end)
5. [FASE 1: `ruby-dag` R0–R3](#5-fase-1-ruby-dag-r0r3)
6. [FASE S0: adapter SQLite di `delphic`](#6-fase-s0-adapter-sqlite-di-delphic)
7. [Contratto di confine `CONTRACT.md`](#7-contratto-di-confine-contractmd)
8. [FASE 2: `delphic` D0–D4](#8-fase-2-delphic-d0d4)
9. [Anti-pattern di reiezione](#9-anti-pattern-di-reiezione)
10. [Appendici implementative](#10-appendici-implementative)
11. [Prompt operativo per delegare una fase](#11-prompt-operativo-per-delegare-una-fase)
12. [Gate aggiornati per `delphic`](#12-gate-aggiornati-per-delphic)

---

## 1. Regola operativa principale

L’ordine corretto è:

```text
R0 ─▶ R1 ─▶ R2 ─▶ R3 ─▶ ruby-dag v1.0
                              │
                              └▶ S0 adapter SQLite in delphic
                                      │
                                      └▶ D0 ─▶ D1 ─▶ D2 ─▶ D3 ─▶ delphic v1.0
                                                                       │
                                                                       └▶ D4 post-v1.0
```

`delphic` usa workflow durable e casi di resume basati su SQLite. Quindi S0 non è opzionale, ma non è una gemma separata: è il primo adapter durable consumer-side dentro `delphic`. D0 e le fasi agentiche successive devono usare quell'adapter, non aggiungere SQLite al kernel.

Regole di avanzamento:

- una fase = un branch + una PR;
- non implementare task di fasi successive;
- ogni task deve avere test, documentazione, o una motivazione esplicita se non testabile;
- prima di aprire la fase successiva devono passare `bundle exec rake test` e `bundle exec rubocop`;
- per S0 devono passare anche i test della storage contract suite condivisa su `Memory::Storage` e `Delphic::Adapters::Sqlite::Storage`.

---

## 2. I 4 pilastri architetturali

### 2.1 Air-gap

`ruby-dag` è un motore deterministico generico. Non conosce LLM, prompt, token, budget, chat, approval umane o tool agentici.

Regola pratica:

> Se una feature non servirebbe anche per un workflow ETL, CI/CD o data pipeline, non vive in `ruby-dag`; vive in `delphic`.

### 2.2 Architettura esagonale

Tutto ciò che è I/O, stato persistente, tempo, ID, fingerprint o serializzazione passa da ports dichiarativi.

Gli adapter concreti possono vivere:

- dentro `ruby-dag`, solo se sono zero-dep e stdlib-only;
- nel consumer (`delphic`) o in una gemma estratta dal consumer, se richiedono dipendenze esterne come `sqlite3` o `pg`.

### 2.3 Immutabilità profonda

Tutto lo stato del kernel è immutabile e profondamente frozen.

`Data.define` non basta da solo: congela l’oggetto Data, ma non protegge automaticamente array/hash annidati. Per questo R0 deve introdurre:

```text
DAG.deep_freeze
DAG.deep_dup
DAG.json_safe!
```

Ogni oggetto che attraversa il confine pubblico del kernel deve essere deep-frozen o restituito come deep copy.

### 2.4 Concorrenza: processi e fiber, zero Ractor

`ruby-dag` non usa Ractor. La concorrenza viene trattata su due piani distinti:

1. **Kernel deterministico e sequenziale.** `Graph`, `Workflow::Definition`, `ExecutionContext`, `Runner`, `DefinitionEditor`, `MutationService` e tagged types non creano concorrenza, non fanno I/O concorrente, non generano processi e non usano lock.
2. **Concorrenza reale demandata agli adapter durable.** Se più esecutori devono condividere stato, usano processi separati e uno storage durable con CAS transazionale. In v3.4.1 il primo adapter durable è `Delphic::Adapters::Sqlite::Storage`, implementato nel consumer `delphic`.
3. **Concorrenza cooperativa nel layer agentico.** `delphic` usa fiber tramite `async` per orchestration I/O, streaming e coordinator loop. Le fiber non cambiano il contratto del kernel: gli step restano idempotenti e il commit resta atomico nello storage.

Regole operative:

- Nessun `Ractor` in nessun repo.
- Nessun `Thread`, `Mutex`, `Monitor`, `Queue`, `SizedQueue`, `ConditionVariable` nel kernel e negli adapter Memory.
- Nessun `Process.fork`, `Process.spawn`, backtick shell o `system` in `lib/dag/**`.
- I test possono usare processi solo dove serve verificare la concorrenza reale; per `ruby-dag` core i test restano single-process, mentre i test process-level vivono in S0 su SQLite dentro `delphic`.
- `Memory::Storage` e `Memory::EventBus` sono adapter **single-process** per test, REPL e sviluppo. Non sono backend process-safe e non devono fingere di esserlo.
- `Delphic::Adapters::Sqlite::Storage` è il primo backend process-safe: ogni processo apre una propria connessione SQLite e si coordina tramite transazioni.
- `delphic` usa `Async::Task` / fiber per concorrenza applicativa. I processi sono ammessi solo per isolamento esplicito di tool esterni, worker o test di integrazione; non per rendere concorrente il kernel.

Sono kernel puro:

```text
Graph
Workflow::Definition
ExecutionContext
StepProtocol
Runner
DefinitionEditor
MutationService
Tagged Types
```

Sono adapter stateful single-process:

```text
DAG::Adapters::Memory::Storage
DAG::Adapters::Memory::EventBus
DAG::Adapters::Memory::CrashableStorage
```

| Percorso | Thread/Ractor | Process spawn/fork | Mutex/Queue | Mutazione interna | Note |
|---|---:|---:|---:|---:|---|
| `lib/dag/graph.rb` | vietati | vietato | vietati | vietata | kernel puro |
| `lib/dag/workflow/**` | vietati | vietato | vietati | vietata | kernel puro |
| `lib/dag/runner.rb` | vietati | vietato | vietati | vietata su `self` | kernel puro |
| `lib/dag/types.rb` | vietati | vietato | vietati | vietata | kernel puro |
| `lib/dag/mutation_service.rb` | vietati | vietato | vietati | vietata | kernel puro |
| `lib/dag/definition_editor.rb` | vietati | vietato | vietati | vietata | kernel puro |
| `lib/dag/adapters/memory/storage.rb` | vietati | vietato | vietati | consentita privata | single-process adapter |
| `lib/dag/adapters/memory/event_bus.rb` | vietati | vietato | vietati | consentita privata | single-process adapter |
| `test/**` core | vietati | consentito solo se dichiarato nel test | vietati | consentito nei fake | niente Ractor |
| `test/s0/**` in `delphic` | vietati | consentito | vietati | consentito nei fixture | process concurrency SQLite |
| `lib/delphic/**` | vietati | consentito solo in adapter/process runner espliciti | vietati | consentita negli storage applicativi | fiber-first |

Pattern di riferimento per gli adapter Memory:

- possiedono stato privato mutabile;
- ogni metodo pubblico è sincrono e non deve fare `Fiber.yield`, `sleep`, I/O o callback che possa rientrare nello stesso adapter;
- ogni metodo pubblico fa una singola operazione logica completa sullo stato;
- ogni valore restituito è deep copy + deep-frozen;
- la CAS resta testabile in modo deterministico, ma non rappresenta garanzia inter-process.

Pattern di riferimento per gli adapter durable:

- ogni processo crea la propria istanza dello storage;
- nessun oggetto storage viene condiviso tra processi;
- ogni operazione CAS usa una transazione del backend;
- i test process-level verificano race reali su file SQLite condiviso o database equivalente.

> Razionale: Ractor introduce vincoli di shareability e compatibilità API che non sono necessari per questo progetto. Il kernel deve restare puro e deterministico; la concorrenza reale viene spostata dove è più naturale e verificabile: processi + storage transazionale. Le fiber restano nel layer applicativo per I/O cooperativo, streaming e orchestration.

### 2.5 Mappatura dei domini (Option B+ / Effect-Aware Kernel)

Questa architettura segue il modello **Option B+**: il kernel `ruby-dag` è **effect-aware**, ma non **adapter-aware**. Conosce il protocollo astratto degli effetti durabili, ma non i sistemi fisici esterni.

#### Dominio 1: `ruby-dag` — meccanismo esagonale ed effetti astratti

`ruby-dag` gestisce soltanto il meccanismo di workflow e la sicurezza del ledger:

- **Graph & Definition:** topologia pura immutabile, revisione, fingerprint deterministico.
- **Runner:** macchina a stati funzionale basata su eleggibilità topologica.
- **ExecutionContext:** dizionario copy-on-write, deep-frozen, JSON-safe quando durable.
- **Effects:** intenti durabili (`DAG::Effects::Intent`), payload fingerprint, lease coordination, CAS state transitions per effetti astratti.
- **Ports:** `Storage`, `EventBus`, `Fingerprint`, `Clock`, `IdGenerator`, `Serializer`.
- **Mutation:** pianificazione strutturale pura + applicazione tramite `MutationService` atomico.

Non gestisce prompt, chat, token, budget, approval, tool reali, provider LLM, UI, handler di rete o memoria semantica.

#### Dominio 2: `delphic` — semantica agentica e dispatch fisico

`delphic` interpreta l'intento umano, definisce la sicurezza esterna e usa `ruby-dag` come motore:

- **Conversation & Instance:** storico conversazionale e lifecycle applicativo.
- **Skill & Tool:** template di workflow e primitive esterne.
- **Dispatch & Handlers:** ricezione degli intenti durabili e chiamate fisiche effettive (HTTP, LLM, ecc.) con policy di retry ed exactly-once protection (remote idempotency keys).
- **Model/Tool Ledgers:** protezione da doppia esecuzione di chiamate costose o con side effect non coperte dagli ID esterni.
- **Policy & RuntimeProfile applicativo:** approval, limiti, budget, human-in-the-loop.
- **ArtifactStore:** content-addressed storage applicativo, distinto dal CAS Compare-And-Swap dello storage kernel.
- **Coordinator:** super-loop che usa il dispatcher per reclamare effetti, chiama `Runner`, legge stati/eventi e decide la prossima azione.

> **Regola di Pinning:** Durante lo sviluppo coordinato e la fase di stabilizzazione del protocollo effetti, `delphic` deve puntare a `ruby-dag` tramite path locale o branch di feature esplicito nel Gemfile. Dopo il merge upstream, deve puntare a uno SHA di commit pinnato o a un tag. Non dipendere mai da `main` floating per l'esecuzione in Delphi.

> Nota terminologica: in questo documento **CAS storage** significa Compare-And-Swap; **Artifact CAS** significa Content-Addressed Storage. Non usare “CAS” senza qualificatore.

---

## 3. Decisioni di progetto congelate

| Decisione | Valore | Note operative |
|---|---|---|
| Ruby minimo | `>= 3.4` | Requisito di progetto. I test di correttezza non devono dipendere da uno specifico scheduler o modello di concorrenza implicito. |
| Naming gemma | `ruby-dag` | Eccezione esplicita alla convenzione underscore; entrypoint pubblico `require "ruby-dag"`. |
| Namespace | `DAG` | Neutro, non legato a `delphic`. |
| Test framework | `minitest` | Runtime stdlib/default; dev dependency ammessa. |
| Runtime deps `ruby-dag` | `0` | Solo stdlib/default libraries: `digest`, `securerandom`, `json`, `set`, `forwardable`, `time`, `logger`, `pathname`, `fileutils`. |
| Dev deps `ruby-dag` | `minitest`, `rake`, `rubocop`, eventuale `simplecov` | Nessuna di queste diventa runtime dependency. |
| Storage default | `DAG::Adapters::Memory::Storage` | In-RAM, utile per test/REPL; single-process, non process-safe. |
| EventBus default | `DAG::Adapters::Null::EventBus` | No-op; `Memory::EventBus` per test e CLI, single-process. |
| Concorrenza kernel | Sequenziale e deterministica | Niente `Thread`, niente `Mutex`, niente `Ractor`, niente process spawn in `lib/dag/**`. |
| Concorrenza durable | Processi + storage transazionale | Test reali in S0 su SQLite; ogni processo apre una propria connessione. S0 vive nel repo `delphic`, non nel kernel. |
| Concorrenza `delphic` | Fiber via `async` + processi isolati per tool/worker | Vietati Thread e Ractor; processi ammessi solo in boundary espliciti. |
| Retry policy | Due livelli: `max_attempts_per_node` + `max_workflow_retries` | Un nodo può ritentare fino a `max_attempts_per_node` volte; un workflow può rientrare in `:failed -> :running` fino a `max_workflow_retries` volte tramite `Runner#retry_workflow`. |

### 3.1 Naming e file entrypoint

Struttura obbligatoria:

```text
ruby-dag.gemspec
lib/ruby-dag.rb       # entrypoint pubblico
lib/dag.rb            # caricato da ruby-dag.rb
lib/dag/**/*.rb       # implementazione
```

Nel `Gemfile` di `delphic`:

```ruby
gem "ruby-dag", "~> 1.0", require: "ruby-dag"
```

DoD R0 dedicato:

```ruby
def test_public_require
  assert system(Gem.ruby, "-e", "require 'ruby-dag'; puts DAG.name")
end
```

---

## 4. Grafo delle dipendenze fra fasi

```text
ruby-dag
  R0  Setup, ports, tagged types, immutability, cops, contract
   │
   ▼
  R1  Core deterministico, Runner, Memory storage, default adapters
   │
   ▼
  R2  Resume, CAS contract, crash recovery, fingerprint deterministico
   │
   ▼
  R3  Adaptive planning strutturale, invalidation, mutation service
   │
   ▼
  ruby-dag v1.0
   │
   ▼
delphic
  S0  SQLite storage adapter + storage contract suite
   │
   ▼
  D0  Setup agentico
   │
   ▼
  D1  LLM/tool steps, ledger, budget, sicurezza effetti esterni
   │
   ▼
  D2  Interfacce, conversation store, planner base
   │
   ▼
  D3  Coordinator, approval, artifact store
   │
   ▼
  delphic v1.0
   │
   ▼
  D4  Automazione e produzione post-v1.0
```

### 4.1 Danza operativa end-to-end

Scenario: l'utente chiede all'agente di pulire vecchi log del server.

1. **`delphic` capisce l'intento.** Il Planner carica una Skill `ServerAdmin`, costruisce una `DAG::Workflow::Definition` e crea un workflow durable nello storage SQLite.
2. **`ruby-dag` avvia il workflow.** Il Runner calcola l'eleggibilità topologica e invoca uno step registrato, senza conoscere LLM o tool.
3. **`delphic` produce un'intenzione, non un side effect.** Uno `LLMStep` o `ToolPlanningStep` propone l'azione simbolica `delete_old_logs`, con payload JSON-safe. Non viene eseguito nessun comando shell dentro il kernel.
4. **Il kernel checkpointa.** Lo step ritorna `Waiting[reason: :approval_required, resume_token: ..., metadata: ...]` oppure `Success` con `proposed_mutations`. Il Runner committa l'attempt e porta il workflow in `:waiting` o `:paused` secondo il contratto.
5. **`delphic` applica policy e ledger.** Il Coordinator legge eventi e stato, scrive una riga `planned` nel ledger applicativo e richiede approvazione umana.
6. **L'utente approva.** Il Coordinator registra la decisione, esegue il tool tramite registry, marca il ledger come `executed`, salva il risultato applicativo e richiama `Runner#resume(workflow_id)`.
7. **`ruby-dag` riprende deterministicamente.** Il Runner ricarica workflow, revisione e node states. I nodi già committati non vengono rieseguiti; i nodi pendenti ripartono.
8. **Gli output finali diventano artifact.** `delphic` promuove gli output a `ArtifactStore` content-addressed e aggiorna la conversazione.

Regola di sicurezza dell'esempio: nel documento e nei test non usare comandi distruttivi reali come stringhe operative. Usare sempre tool simbolici e adapter fake; l'esecuzione fisica avviene solo nel layer `delphic` e solo dopo ledger + policy.

---

## 5. FASE 1: `ruby-dag` R0–R3

### R0 — Setup, ports, tagged types, immutability, cops

**Obiettivo:** creare lo scheletro della gemma e congelare tutti i contratti prima di implementare logica.

#### Output file obbligatori

```text
ruby-dag.gemspec
Gemfile
Rakefile
.rubocop.yml
.rubocop_todo.yml             # vuoto, presente per CI
lib/ruby-dag.rb
lib/dag.rb
lib/dag/version.rb
lib/dag/errors.rb
lib/dag/immutability.rb
lib/dag/types.rb
lib/dag/workflow.rb           # stub: module DAG::Workflow; end
lib/dag/ports/storage.rb
lib/dag/ports/event_bus.rb
lib/dag/ports/fingerprint.rb
lib/dag/ports/clock.rb
lib/dag/ports/id_generator.rb
lib/dag/ports/serializer.rb
rubocop/cop/dag/no_thread_or_ractor.rb
rubocop/cop/dag/no_mutable_accessors.rb
rubocop/cop/dag/no_in_place_mutation.rb
rubocop/cop/dag/no_external_requires.rb
CONTRACT.md
README.md
CHANGELOG.md
.github/workflows/ci.yml
test/test_helper.rb
test/r0/test_public_require.rb
test/r0/test_types_are_deep_frozen.rb
test/r0/test_json_safety.rb
test/r0/test_zero_runtime_deps.rb
test/r0/test_rubocop_cops.rb
```

#### Checklist R0

- [ ] Creare la gemma `ruby-dag` con `spec.required_ruby_version = ">= 3.4"`.
- [ ] `gemspec`: nessuna `add_dependency`; solo `add_development_dependency`.
- [ ] Implementare `lib/ruby-dag.rb` e `lib/dag.rb`.
- [ ] Implementare `DAG.deep_freeze`, `DAG.deep_dup`, `DAG.json_safe!`.
- [ ] Definire errori pubblici:
  - `PortNotImplementedError`
  - `StaleRevisionError`
  - `StaleStateError`
  - `CycleError`
  - `FingerprintMismatchError`
  - `ConcurrentMutationError`
  - `UnknownNodeError`
  - `UnknownStepTypeError`
  - `UnknownWorkflowError`
  - `WorkflowRetryExhaustedError`
- [ ] Definire tagged types:
  - `Success`
  - `Waiting`
  - `Failure`
  - `StepInput`
  - `ProposedMutation`
  - `ReplacementGraph`
  - `RuntimeProfile`
  - `RunResult`
  - `Event`
- [ ] Definire i ports:
  - `Storage`
  - `EventBus`
  - `Fingerprint`
  - `Clock`
  - `IdGenerator`
  - `Serializer`
- [ ] Scrivere `CONTRACT.md` usando la sezione 7 di questo playbook.
- [ ] Configurare CI con matrix Ruby `[3.4, head]`.
- [ ] Configurare RuboCop custom con scope corretto:
  - no `Thread`/`Ractor` nel repo;
  - no process spawn nel runtime `lib/dag/**`;
  - no mutable accessors in tutto `lib/dag/**`;
  - no in-place mutation nel kernel puro;
  - no external requires non stdlib.

#### DoD R0

- [ ] `require "ruby-dag"` funziona in un processo Ruby pulito.
- [ ] `DAG::Success[value: 1].frozen? == true`.
- [ ] `DAG::Success[value: {a: []}].value[:a] << 1` solleva `FrozenError`.
- [ ] `DAG.json_safe!({a: 1, "a" => 2})` solleva `ArgumentError`.
- [ ] `DAG::Waiting[reason: :rate_limited, not_before_ms: 1_700_000_000_000]` è valido.
- [ ] `DAG::Waiting[reason: :rate_limited, not_before_ms: Time.now]` solleva `ArgumentError`.
- [ ] Il gemspec non contiene runtime dependencies.
- [ ] RuboCop fallisce su `Thread.new`, `Thread.start`, `Thread.fork` in tutto il repo.
- [ ] RuboCop fallisce su `Ractor.new` in tutto il repo.
- [ ] RuboCop fallisce su `Mutex.new`, `Monitor.new`, `Queue.new`, `SizedQueue.new`, `ConditionVariable.new` in tutto il repo.
- [ ] RuboCop fallisce su `Process.fork`, `Process.spawn`, `system`, backtick shell e `%x` dentro `lib/dag/**`, ma non nei test.
- [ ] RuboCop fallisce su `attr_accessor` in `lib/dag/**`.
- [ ] `DAG::VERSION` è definita ed è una stringa SemVer 0.x.0.

---

### R1 — Core deterministico + default adapters

**Obiettivo:** workflow ephemeral in-memory completamente funzionanti, con execution deterministica e storage contract base.

#### Output file obbligatori

```text
lib/dag/graph.rb
lib/dag/workflow/definition.rb
lib/dag/execution_context.rb
lib/dag/step_protocol.rb
lib/dag/step/base.rb
lib/dag/runner.rb
lib/dag/step_type_registry.rb
lib/dag/builtin_steps/noop.rb
lib/dag/builtin_steps/passthrough.rb
lib/dag/adapters/memory/storage.rb
lib/dag/adapters/memory/event_bus.rb
lib/dag/adapters/null/event_bus.rb
lib/dag/adapters/stdlib/fingerprint.rb
lib/dag/adapters/stdlib/clock.rb
lib/dag/adapters/stdlib/id_generator.rb
lib/dag/adapters/stdlib/serializer.rb
test/support/workflow_builders.rb
test/support/step_helpers.rb
test/support/runner_factory.rb
test/r1/test_linear_workflow.rb
test/r1/test_fan_out_fan_in.rb
test/r1/test_cycle_detection.rb
test/r1/test_context_merge_order.rb
test/r1/test_memory_storage_cas.rb
test/r1/test_runner_signature.rb
test/r1/test_many_workflows_single_process.rb
```

#### Checklist R1

- [ ] Implementare `DAG::Graph` immutabile:
  - `#add_node(id, payload = {}) -> Graph`
  - `#add_edge(from, to) -> Graph`
  - `#topological_order -> Array`
  - `#predecessors(id)`
  - `#successors(id)`
  - `#descendants_of(root_id, include_self: true)`
  - `#exclusive_descendants_of(root_id, include_self: true)`
  - `#shared_descendants_of(root_id)`
  - `#to_h` canonico per serializer/fingerprint
- [ ] `#add_edge` solleva `CycleError` se introduce un ciclo, includendo l’arco offensivo nel messaggio.
- [ ] `#topological_order` è deterministico: tie-break su `id.to_s` ASCII-comparato.
- [ ] Implementare `DAG::Workflow::Definition`:
  - wrappa `Graph` + mapping `node_id -> step_type_ref + config`;
  - `#revision` parte da `1`;
  - `#fingerprint(via:)` usa `Ports::Fingerprint`;
  - nessuna memoization mutabile dopo costruzione.
- [ ] Implementare `DAG::ExecutionContext`:
  - CoW deep-frozen;
  - `#merge(patch) -> ExecutionContext`;
  - `#fetch`, `#dig`, `#to_h`;
  - `#to_h` restituisce deep copy, non riferimento interno.
- [ ] Definire il context effettivo di un nodo:
  - parte da `initial_context` persistito nel workflow;
  - i predecessori del nodo target vengono ordinati secondo `topological_order` ristretto ai soli predecessori, con tie-break su `id.to_s`;
  - i `context_patch` vengono applicati in quell'ordine, deep CoW;
  - in caso di collisione di chiave, vince il patch del predecessore che arriva *dopo* nell'ordine ristretto;
  - per la stessa definizione e gli stessi attempt committati, il context effettivo è bit-identico (verificabile via fingerprint).
- [ ] Implementare `DAG::StepProtocol`:
  - uno step espone `#call(StepInput) -> Success | Waiting | Failure`;
  - se uno step alza `StandardError`, il Runner converte in `Failure[error: {class:, message:}, retriable: false]`;
  - `NoMemoryError`, `SystemExit`, `Interrupt` non vengono catturati.
- [ ] Implementare `DAG::Step::Base` con freeze automatico in `initialize`.
- [ ] Implementare `DAG::StepTypeRegistry`:
  - `register(name:, klass:, fingerprint_payload:, config: {})`;
  - `lookup(name)`;
  - `freeze!` dopo la fase di registrazione;
  - stesso name + stesso fingerprint = no-op;
  - stesso name + fingerprint diverso = `FingerprintMismatchError`;
  - lookup sconosciuto = `UnknownStepTypeError`.
- [ ] Implementare solo questi built-in step:
  - `:noop`
  - `:passthrough`
- [ ] Non implementare `:branch` in R1. Senza edge metadata condizionali sarebbe ambiguo.
- [ ] Implementare `DAG::Runner#call(workflow_id)`.
- [ ] `Runner#call` non riceve `initial_context:`. Il context iniziale è salvato in `Storage#create_workflow`.
- [ ] Costruttore vincolante:

```ruby
DAG::Runner.new(
  storage:,           # implementa Ports::Storage
  event_bus:,         # implementa Ports::EventBus
  registry:,          # DAG::StepTypeRegistry frozen
  clock:,             # implementa Ports::Clock
  id_generator:,      # implementa Ports::IdGenerator
  fingerprint:,       # implementa Ports::Fingerprint
  serializer:         # implementa Ports::Serializer
)
```

Il Runner è frozen dopo l'inizializzazione. Tutte le dipendenze sono iniettate; nessuna è opzionale (no default singleton). Vedi anche Appendice H per `runner_factory`.

- [ ] Implementare default adapters:
  - `Memory::Storage` (single-process, stateful, no Thread/Ractor/Mutex)
  - `Null::EventBus`
  - `Memory::EventBus` (single-process, stateful, no Thread/Ractor/Mutex)
  - `Stdlib::Fingerprint`
  - `Stdlib::Clock`
  - `Stdlib::IdGenerator`
  - `Stdlib::Serializer` (`JSON` wrapper)
- [ ] `Memory::Storage` e `Memory::EventBus` possiedono stato privato mutabile ma restano single-process: nessun `Thread`, `Ractor`, `Mutex`, `Queue`, I/O, `sleep` o `Fiber.yield` nei metodi pubblici.
- [ ] `Memory::Storage` non è dichiarato process-safe; la concorrenza process-level viene testata solo con `Delphic::Adapters::Sqlite::Storage` in S0.
- [ ] `Memory::EventBus#events` restituisce array deep-frozen, non riferimenti mutabili.

#### Algoritmo vincolante `Runner#call`

```text
call(workflow_id):
  transition_workflow_state(pending|waiting|paused -> running) via CAS
  append workflow_started se è il primo run
  definition = storage.load_current_definition(id)
  node_states = storage.load_node_states(id, definition.revision)
  workflow = storage.load_workflow(id)

  loop:
    eligible_nodes = nodi con predecessori committed e stato pending
    break se eligible_nodes.empty?

    for node in eligible_nodes sorted by definition.topological_order:
      attempt_number = storage.count_attempts(workflow_id: id,
                                              revision: definition.revision,
                                              node_id: node) + 1

      attempt_id = storage.begin_attempt(
        workflow_id: id,
        revision: definition.revision,
        node_id: node,
        expected_node_state: :pending,
        attempt_number: attempt_number
      )

      input = StepInput(context: effective_context(node), node_id:, attempt_number:, metadata: ...)
      result = safe_call_step(step, input)

      case result
      when Success
        commit node as committed
        if result.proposed_mutations.any?
          transition workflow running -> paused
          append workflow_paused
          return RunResult[state: :paused, ...]
        end
      when Waiting
        commit node as waiting
      when Failure
        if result.retriable && attempt_number < runtime_profile.max_attempts_per_node
          commit attempt as failed; node resta pending nel ciclo successivo
        else
          commit attempt as failed; node committed as :failed
          transition workflow running -> failed
          break
        end
      end
    end
  end

  if all nodes committed:
    transition running -> completed
  elsif any node waiting:
    transition running -> waiting
  elsif any node failed:
    transition running -> failed
  else:
    transition running -> failed con diagnostic: no eligible nodes but workflow incomplete
```

Note vincolanti:

- `attempt_number` è per nodo per revisione; conta gli attempt non `:aborted`.
- `max_attempts_per_node` viene letto da `RuntimeProfile` salvato in `create_workflow`.
- Il secondo livello (`max_workflow_retries`) NON è gestito da `#call`; è gestito da `Runner#retry_workflow(workflow_id)` chiamabile solo se workflow è `:failed` e `workflow_retry_count < max_workflow_retries`. Vedi DoD R1.

#### DoD R1

- [ ] Lineare `A -> B -> C` con `:passthrough` e `initial_context: {x: 1}` completa con context propagato.
- [ ] Fan-out/fan-in `A -> {B, C} -> D` esegue B e C in ordine deterministico; D parte solo dopo entrambi.
- [ ] Ciclo `A -> B -> A` solleva `CycleError` con messaggio leggibile contenente l'arco offensivo.
- [ ] A e B indipendenti producono entrambi `{x: ...}`; C fan-in riceve il valore del predecessore che arriva dopo nell'ordine ristretto ai predecessori (tie-break `id.to_s`). Il risultato è deterministico in 100 run.
- [ ] Due chiamate consecutive a `transition_workflow_state(id:, from: :pending, to: :running)` sullo stesso workflow: la prima riesce, la seconda riceve `StaleStateError`.
- [ ] 100 workflow indipendenti completano nello stesso processo senza stati corrotti.
- [ ] Due chiamate consecutive a `transition_node_state` sullo stesso nodo con lo stesso `from:`: una vince, una riceve `StaleStateError`.
- [ ] Nessun file R1 usa `Ractor`, `Thread`, `Mutex` o `Queue`.
- [ ] Un nodo retriable fallisce 2 volte, riesce alla terza, con `max_attempts_per_node: 3`.
- [ ] Un nodo retriable fallisce 3 volte con `max_attempts_per_node: 3`: workflow va in `:failed`.
- [ ] `Runner#retry_workflow(workflow_id)` su workflow `:failed` con `workflow_retry_count < max_workflow_retries` resetta i nodi `:failed` a `:pending` e ricrea attempt nuovi (i nodi `:committed` restano).
- [ ] `Runner#retry_workflow` su workflow `:failed` con `workflow_retry_count == max_workflow_retries` solleva `WorkflowRetryExhaustedError`.
- [ ] Il costruttore di `Runner` solleva `ArgumentError` se manca uno dei keyword argument obbligatori.

---

### R2 — Resume, CAS contract, crash recovery

**Obiettivo:** rendere il kernel sufficiente per workflow durable, anche prima di implementare SQLite.

#### Output file obbligatori

```text
lib/dag/adapters/memory/crashable_storage.rb
test/r2/test_fingerprint_determinism.rb
test/r2/test_fingerprint_json_safety.rb
test/r2/test_resume_after_crash.rb
test/r2/test_resume_in_flight_attempt.rb
test/r2/test_workflow_retry.rb
test/support/storage_contract.rb
test/support/storage_contract/workflow_lifecycle.rb
test/support/storage_contract/revision_cas.rb
test/support/storage_contract/attempt_atomicity.rb
test/support/storage_contract/event_log.rb
```

> Nota: `test/support/workflow_builders.rb`, `step_helpers.rb` e `runner_factory.rb` sono già stati creati in R1.

#### Checklist R2

- [ ] Formalizzare e testare il fingerprint contract:
  - input solo JSON-safe;
  - chiavi hash canonicalizzate a stringa;
  - collisione `:a` / `"a"` solleva `ArgumentError`;
  - `NaN` e `Infinity` vietati;
  - `Time` vietato: usare epoch milliseconds o ISO8601 normalizzata.
- [ ] Implementare `Runner#resume(workflow_id)`:
  - carica workflow e revisione corrente;
  - chiama `abort_running_attempts(workflow_id:)` prima di calcolare eleggibilità;
  - non riesegue nodi già `committed` nella revisione corrente;
  - procede con lo stesso algoritmo di `#call`.
- [ ] Definire la semantica degli attempt `waiting`:
  - non vengono rieseguiti automaticamente;
  - possono essere riprovati solo se il Coordinator/app aggiorna token/context o decide esplicitamente il retry.
- [ ] Implementare `Memory::CrashableStorage` con trigger deterministici, non solo "dopo N operazioni".

API consigliata:

```ruby
storage = DAG::Adapters::Memory::CrashableStorage.new(
  crash_on: { method: :commit_attempt, node_id: :b, before_commit: true }
)

# Dopo che il crash è stato "raccolto" come eccezione SimulatedCrash,
# il test promuove lo stato verso una storage sana per simulare il riavvio:
healthy_storage = storage.snapshot_to_healthy
# => DAG::Adapters::Memory::Storage con lo stato pre-crash importato
```

`snapshot_to_healthy` è metodo pubblico di `CrashableStorage` ed è obbligatorio per i test di resume.

- [ ] Estrarre una storage contract suite riutilizzabile da Memory e SQLite.
- [ ] Documentare in `CONTRACT.md` idempotenza degli step:
  - lo step deve essere progettato come funzione pura del proprio `StepInput`;
  - se ha effetti esterni, è il consumer (`delphic`) a doverli proteggere via ledger;
  - il kernel garantisce *at-most-once commit del risultato*: un attempt `:committed` non viene mai sovrascritto;
  - il kernel non garantisce *at-most-once invocazione di `step.call`* in presenza di crash: lo step può essere invocato più volte se il commit non è andato a buon fine.

#### DoD R2

- [ ] Fingerprint stabile per hash con chiavi ordinate diversamente.
- [ ] Collisione `:a` / `"a"` rilevata.
- [ ] Kill prima del commit di B: resume riesegue B.
- [ ] Kill dopo commit di B ma prima di C: resume parte da C.
- [ ] Attempt `running` abortito viene marcato `:aborted`.
- [ ] A non viene rieseguito nei test di resume.
- [ ] `commit_attempt` rispetta atomicità: risultato + attempt state + node state + durable event.
- [ ] `append_revision` rispetta CAS su `parent_revision`.

---

### R3 — Adaptive planning strutturale

**Obiettivo:** permettere a un workflow di evolvere forma in modo controllato e durable.

#### Output file obbligatori

```text
lib/dag/definition_editor.rb
lib/dag/mutation_service.rb
test/r3/test_invalidate.rb
test/r3/test_replace_subtree_preserves_parallel.rb
test/r3/test_stale_revision.rb
test/r3/test_mutation_active_run_guard.rb
test/r3/test_mutation_stress.rb
```

#### Checklist R3

- [ ] `ProposedMutation` supporta solo:
  - `:replace_subtree`
  - `:invalidate`
- [ ] Usare `ReplacementGraph` esplicito con:
  - `graph`
  - `entry_node_ids`
  - `exit_node_ids`
- [ ] Non inferire entry/exit se il replacement graph ha più sorgenti o più sink.
- [ ] Implementare `DAG::DefinitionEditor#plan(definition, mutation)` come servizio puro:
  - nessuno storage;
  - nessun event bus;
  - nessun side-effect;
  - ritorna `PlanResult` o equivalente con `valid?`, `new_definition`, `invalidated_node_ids`, `reason`.
- [ ] Implementare `DAG::MutationService#apply(workflow_id:, mutation:, expected_revision:)`:
  - carica workflow e definizione corrente;
  - richiede workflow state `:paused` o `:waiting`;
  - se `:running`, solleva `ConcurrentMutationError`;
  - chiama `DefinitionEditor#plan`;
  - chiama `Storage#append_revision` con CAS su `expected_revision`;
  - pubblica `mutation_applied` su EventBus dopo commit durable.
- [ ] `append_revision` deve essere atomico con:
  - append revisione;
  - invalidazione nodi;
  - append event `mutation_applied`.
- [ ] `Runner#call` riconosce `Success` con `proposed_mutations`:
  - committa il nodo;
  - transiziona workflow `running -> paused`;
  - appende `workflow_paused`;
  - ritorna `RunResult[state: :paused]`.

> **Confine di responsabilità.** In R3, dopo `RunResult[state: :paused]` non c'è un coordinator interno al kernel. I test R3 fanno il giro a mano: leggono `proposed_mutations` da `storage.list_attempts(...).last.result.proposed_mutations`, decidono se applicarle, chiamano `MutationService#apply`, e poi chiamano `Runner#resume`. Il vero coordinator vive in `delphic` (D3). Un workflow `:paused` con mutation pending che non riceve mai una `apply` resta `:paused` per sempre: è valido per il kernel, ed è responsabilità del consumer evitare il deadlock applicativo.

#### Semantica vincolante di `replace_subtree`

In un DAG, “subtree” è ambiguo. La mutation conserva il nome `:replace_subtree` per leggibilità, ma la semantica è questa:

1. Calcolare `removed = exclusive_descendants_of(target, include_self: true)`.
2. Calcolare `preserved_impacted = descendants_of(target) - removed`.
3. Rimuovere solo `removed`.
4. Collegare ogni predecessore esterno del target agli entry node del replacement graph.
5. Collegare ogni exit node del replacement graph ai successori esterni dei nodi rimossi.
6. Invalidare `preserved_impacted`, perché dipendono da output cambiati.
7. Preservare i branch indipendenti non raggiungibili dal target.

Esempio:

```text
A ─▶ B ─▶ D
└──▶ C ───┘
```

`replace_subtree(B, B' -> B'')` produce:

```text
A ─▶ B' ─▶ B'' ─▶ D
└────▶ C ─────────┘
```

Stati attesi:

```text
A        committed preservato
C        committed preservato
B        rimosso/inattivo nella nuova revision
D        invalidated
B', B''  pending
```

#### DoD R3

- [ ] `invalidate(B)` su `A -> B -> C -> D` preserva A e invalida B/C/D.
- [ ] `replace_subtree(B)` su `A -> {B,C} -> D` preserva A/C, rimpiazza B, invalida D.
- [ ] Apply con `expected_revision: 1` quando current è 2 solleva `StaleRevisionError`.
- [ ] Apply mentre workflow è `:running` solleva `ConcurrentMutationError`.
- [ ] Stress logico con 10 tentativi consecutivi di apply su workflow `:running`: nessun apply riesce, tutti ricevono `ConcurrentMutationError`.
- [ ] La race reale fra processi su mutation CAS viene coperta in S0 usando `Delphic::Adapters::Sqlite::Storage`.

---

### Traguardo FASE 1: `ruby-dag v1.0`

Prima di taggare `ruby-dag v1.0` devono essere veri tutti questi punti:

- [ ] R0, R1, R2, R3 verdi in CI.
- [ ] Runtime dependencies = 0.
- [ ] README con esempio hello world in meno di 10 righe.
- [ ] README con esempio resume minimale.
- [ ] `CONTRACT.md` aggiornato e linkato.
- [ ] Storage contract suite passa su `Memory::Storage`.
- [ ] RuboCop custom attivi.
- [ ] API pubbliche documentate con YARD.

---

## 6. FASE S0: adapter SQLite di `delphic`

**Obiettivo:** implementare lo storage durable minimo nel repo `delphic`, come adapter consumer-side di `DAG::Ports::Storage`, prima di introdurre semantica agentica. Questa fase sostituisce la vecchia idea di una gemma obbligatoria `ruby-dag-sqlite`.

S0 dipende da `ruby-dag` v1.0 e non modifica `ruby-dag`. Il kernel resta zero runtime dependency. L'adapter SQLite puo' essere estratto in una gemma separata in futuro, ma per il roadmap corrente vive in `delphic`.

### Output file obbligatori

```text
delphic.gemspec                              # scaffold minimo se il repo non esiste ancora
Gemfile
Rakefile
lib/delphic.rb
lib/delphic/version.rb
lib/delphic/adapters/sqlite/storage.rb
lib/delphic/adapters/sqlite/schema.rb
lib/delphic/adapters/sqlite/serializer.rb
test/storage_contract/**/*.rb
test/s0/test_storage_contract.rb
test/s0/test_crash_atomicity.rb
test/s0/test_process_concurrency.rb
test/s0/test_mutation_process_race.rb
README.md                                    # stub S0, completato in D0-D2
CONTRACT.md                                  # sezione storage durable consumer-side
```

### Checklist S0

- [ ] Creare o estendere la gemma `delphic`.
- [ ] Dipendenze runtime minime S0:
  - `ruby-dag`, `~> 1.0`, `require: "ruby-dag"`
  - `sqlite3`
- [ ] Implementa l'intero port effect-aware `DAG::Ports::Storage` come `Delphic::Adapters::Sqlite::Storage`.
- [ ] L'adapter vive nel namespace `Delphic`, non in `DAG`; non monkey-patcha il kernel e non aggiunge dipendenze runtime a `ruby-dag`.
- [ ] Implementa schema isolato con prefisso `dag_`.
- [ ] All'apertura della connessione applica i pragma vincolanti:
  ```sql
  PRAGMA journal_mode = WAL;
  PRAGMA synchronous = NORMAL;
  PRAGMA foreign_keys = ON;
  PRAGMA busy_timeout = 5000;
  ```
- [ ] Schema migration deterministica: `Delphic::Adapters::Sqlite::Schema.install!(db)` è idempotente, crea tabelle solo se mancanti, e versiona via `dag_schema_version(version, applied_at_ms)`. Versione iniziale: `1`.
- [ ] Usa transazioni SQLite per ogni operazione atomica (`BEGIN IMMEDIATE` per write).
- [ ] CAS revision via transazione e condizione su `current_revision`.
- [ ] CAS node/workflow state via `UPDATE ... WHERE state = ?` e verifica `db.changes == 1`.
- [ ] `commit_attempt(effects: [])` è una singola transazione: attempt result, attempt state, node state, event, effect records e attempt-effect links vengono committati o rollbackati insieme.
- [ ] Effect ledger storage:
  - `dag_effects` conserva status, lease, idempotency identity `(type, key)`, `payload_fingerprint`, payload/result/error JSON-safe ed eventuale `external_ref`.
  - `dag_attempt_effects` collega attempt ed effects, distinguendo blocking/detached.
  - stesso `(type, key)` + stesso `payload_fingerprint` riusa/linka il record; fingerprint diverso solleva `DAG::Effects::IdempotencyConflictError`.
- [ ] Implementa `list_effects_for_node`, `list_effects_for_attempt`, `claim_ready_effects`, `mark_effect_succeeded`, `mark_effect_failed`, `release_nodes_satisfied_by_effect`.
- [ ] `transition_workflow_state(event:)` è una singola transazione quando `event` è presente.
- [ ] `append_revision` è una singola transazione.
- [ ] Serializer JSON compatibile con i tipi canonici del kernel.
- [ ] Costruttore accetta `path:` (file) e `pool_size: 1` di default. Per v1.0 una connessione SQLite per istanza, niente connection pool.
- [ ] Nei test process-level ogni processo figlio apre una nuova istanza `Delphic::Adapters::Sqlite::Storage`; nessuna connessione SQLite viene condivisa dopo `fork`.
- [ ] Il DB workflow kernel e' distinto dal DB applicativo di `delphic`: default `~/.delphic/workflows.sqlite3` per S0, `~/.delphic/state.sqlite3` per D0+.
- [ ] Nessuna tabella agentica (`conversation`, ledger, approval, budget, artifact) entra nel DB workflow S0.

### Schema minimo

```text
dag_schema_version(
  version,
  applied_at_ms
)

dag_workflows(
  id,
  state,
  current_revision,
  workflow_retry_count,
  initial_context_json,
  runtime_profile_json,
  created_at_ms,
  updated_at_ms
)

dag_revisions(
  workflow_id,
  revision,
  definition_json,
  fingerprint,
  created_at_ms
)

dag_node_states(
  workflow_id,
  revision,
  node_id,
  state,
  updated_at_ms
)

dag_attempts(
  id,
  workflow_id,
  revision,
  node_id,
  attempt_number,
  state,
  result_json,
  created_at_ms,
  updated_at_ms
)

dag_effects(
  id,
  ref,
  workflow_id,
  revision,
  node_id,
  attempt_id,
  type,
  key,
  payload_json,
  payload_fingerprint,
  blocking,
  status,
  result_json,
  error_json,
  external_ref,
  not_before_ms,
  lease_owner,
  lease_until_ms,
  created_at_ms,
  updated_at_ms,
  metadata_json,
  UNIQUE(type, key)
)

dag_attempt_effects(
  attempt_id,
  effect_id,
  blocking,
  created_at_ms,
  PRIMARY KEY(attempt_id, effect_id)
)

dag_events(
  workflow_id,
  seq,
  type,
  revision,
  node_id,
  attempt_id,
  at_ms,
  payload_json
)
```

### DoD S0

- [ ] Storage contract suite passa su `DAG::Adapters::Memory::Storage` e `Delphic::Adapters::Sqlite::Storage`, incluse le sezioni effect ledger.
- [ ] CAS revision usa transazione SQLite.
- [ ] `commit_attempt(effects: [])` è atomico e coperto da contract test: attempt/node/event/effect records/effect links non possono half-committare.
- [ ] Contract test effect-aware passano anche su SQLite:
  - riserva idempotente su `(type, key)` + `payload_fingerprint`;
  - conflict su stesso `(type, key)` + fingerprint diverso;
  - due claim concorrenti non ottengono lo stesso effetto;
  - `mark_effect_succeeded` / `mark_effect_failed` richiedono lease owner valido;
  - `release_nodes_satisfied_by_effect` rimette `:pending` solo quando tutti gli effetti blocking collegati all'attempt waiting sono terminali.
- [ ] `transition_workflow_state(event:)` è atomico: uno stato terminale durable non puo' esistere senza il corrispondente evento terminale durable.
- [ ] Crash simulato durante transazione non lascia half-commit: il test usa un processo figlio terminato con `KILL` oppure una transazione `BEGIN IMMEDIATE` interrotta; mai Ractor.
- [ ] WAL abilitato e verificato via `PRAGMA journal_mode`.
- [ ] 10 processi che chiamano `Runner#call` sullo stesso workflow condiviso non corrompono lo stato: al massimo un processo entra nella transizione iniziale, gli altri ricevono errore coerente o osservano stato già avanzato.
- [ ] 100 workflow indipendenti processati da 10 processi su stesso file SQLite completano tutti.
- [ ] 10 processi che tentano `MutationService#apply` con stesso `expected_revision` producono una sola revision nuova; gli altri ricevono `StaleRevisionError`.
- [ ] Tutti i test R1 e R2 elencati di seguito passano sostituendo `Memory::Storage` con `Delphic::Adapters::Sqlite::Storage`:
  - `test/r1/test_linear_workflow.rb`
  - `test/r1/test_fan_out_fan_in.rb`
  - `test/r1/test_context_merge_order.rb`
  - `test/r1/test_memory_storage_cas.rb` (riusato come `test_storage_cas` con il backend SQLite)
  - `test/r2/test_resume_after_crash.rb`
  - `test/r2/test_resume_in_flight_attempt.rb`
  - `test/r2/test_workflow_retry.rb`
  - `test/r2/test_runner_effects.rb`
  - `test/r2/test_effects_dispatcher.rb`
  - `test/support/storage_contract/effects.rb`
- [ ] Non si applicano a SQLite: `test/r1/test_cycle_detection.rb` (puro test di Graph, non tocca storage), `test/r0/**` (R0 non ha storage).
- [ ] `bundle exec rake test` passa nel repo `delphic` con S0 incluso.

### Gate S0 -> D0

D0 puo' partire solo quando S0 e' verde. Se S0 ha creato lo scaffold minimo di `delphic`, D0 continua sugli stessi file: non creare un secondo progetto e non reintrodurre `ruby-dag-sqlite` come dipendenza.

---

## 7. Contratto di confine `CONTRACT.md`

`ruby-dag` espone solo questi contratti. `delphic` e qualsiasi altro consumer devono attenersi a questi punti.

### 7.1 Step protocol

```text
#call(StepInput) -> Success | Waiting | Failure
```

Lo step deve essere frozen. Per workflow durable, input/output applicativi devono essere JSON-safe.

**Idempotenza.** Lo step è una funzione del proprio `StepInput`: per gli stessi input deve produrre lo stesso `Success | Waiting | Failure` (modulo metadati di tracing). Il kernel garantisce *at-most-once commit del risultato* e prenotazione durabile degli intenti effetto astratti, NON *at-most-once invocazione* dello step e NON exactly-once fisico verso sistemi esterni. Gli step non eseguono I/O esterno direttamente: descrivono side effect tramite `proposed_effects`, mentre gli handler consumer proteggono la chiamata fisica con idempotency key remota, reconciliation e retry/backoff.

### 7.2 Step result contract

`ruby-dag` trasporta senza interpretare:

```text
value
context_patch
proposed_mutations
proposed_effects
metadata
```

`proposed_effects` è un Array di `DAG::Effects::Intent`.

- Su `Success`, gli effetti sono detached: il nodo può committare, mentre gli effetti vengono registrati e dispatchati senza bloccare il completamento del nodo.
- Su `Waiting`, gli effetti sono blocking: il nodo resta `:waiting` finché gli effect records collegati all'attempt waiting non diventano terminali.

Il Runner prepara gli intenti in `DAG::Effects::PreparedIntent`, calcola `payload_fingerprint` tramite il port `fingerprint`, e li passa a `storage.commit_attempt(..., effects: prepared_effects)` nello stesso boundary atomico di attempt/node/event. `DAG::Effects::Await` legge gli snapshot risolti in `input.metadata[:effects]` e mappa lo stato dell'effetto in `Waiting` / `Success` / `Failure`. `DAG::Effects::Dispatcher` è il boundary astratto claim -> handler -> mark -> release; gli handler concreti vivono nel consumer.

`metadata` è opaco e può contenere attributi semantici del consumer, ma deve restare JSON-safe. Token usage, latency, model name e simili vivono in `delphic`, non nel kernel.

### 7.3 ExecutionContext

Il context è un dizionario copy-on-write gestito dal kernel. Chiavi e valori sono scelti dal consumer, ma devono essere JSON-safe se il workflow è durable.

### 7.4 State model

#### Workflow states

```ruby
WORKFLOW_STATES = %i[
  pending
  running
  waiting
  paused
  completed
  failed
].freeze
```

Transizioni consentite:

| From | To | Causa |
|---|---|---|
| `pending` | `running` | `Runner#call` |
| `waiting` | `running` | `Runner#resume` o evento esterno gestito dal consumer |
| `paused` | `running` | `Runner#resume` dopo mutation/approval |
| `running` | `completed` | tutti i nodi committati |
| `running` | `waiting` | almeno uno step ritorna `Waiting` e nessun nodo eleggibile resta eseguibile |
| `running` | `paused` | step ritorna `Success` con `proposed_mutations` non vuote |
| `running` | `failed` | failure non retriable o max attempts superato |

#### Node states per revisione

```ruby
NODE_STATES = %i[
  pending
  running
  committed
  waiting
  failed
  invalidated
].freeze
```

Ogni node state è relativo a una `definition_revision`.

#### Attempt states

```ruby
ATTEMPT_STATES = %i[
  running
  committed
  waiting
  failed
  aborted
].freeze
```

Un nodo può avere più attempt. Solo un attempt `committed` valido per la revisione corrente contribuisce al context effettivo.

### 7.5 ProposedMutation API

Il consumer può proporre mutation con:

```text
kind
target_node_id
replacement_graph
rationale
confidence
metadata
```

L’applicazione applica tramite:

```ruby
DAG::MutationService#apply(workflow_id:, mutation:, expected_revision:)
```

Non usare `Definition#apply_mutation` con side-effect su storage.

### 7.6 Eventi coarse

Lista chiusa:

```ruby
EVENT_TYPES = %i[
  workflow_started
  node_started
  node_committed
  node_waiting
  node_failed
  workflow_paused
  workflow_waiting
  workflow_completed
  workflow_failed
  mutation_applied
].freeze
```

Gli stessi eventi sono:

- salvati durabilmente da `Storage#append_event` o da operazioni atomiche come `commit_attempt`;
- pubblicati live tramite `EventBus#publish` dopo il commit durable.

### 7.7 RuntimeProfile

Configurazione passata al workflow:

```text
durability
max_attempts_per_node
max_workflow_retries
event_bus_kind
metadata
```

È frozen e JSON-safe. Default: `max_attempts_per_node: 3`, `max_workflow_retries: 0` (cioè nessun retry a livello workflow se non lo si richiede esplicitamente).

### 7.8 StepTypeRegistry

Il consumer registra step custom tramite:

```ruby
register(name:, klass:, fingerprint_payload:, config: {})
```

Il fingerprint deve essere stabile e deterministico.

---

## 8. FASE 2: `delphic` D0–D4

`delphic` è il layer consumer di `ruby-dag`. Contiene sia l'adapter SQLite durable S0 sia la semantica agentica D0-D4: LLM, tool, budget, approval, chat e artifacts. Dipende da `ruby-dag` v1.0; `ruby-dag` non dipende da `delphic`.

### D0 — Setup agentico

#### Output file obbligatori

```text
delphic.gemspec                              # creato in S0 se S0 ha inizializzato il repo
Gemfile
Rakefile
.rubocop.yml
lib/delphic.rb
lib/delphic/version.rb
lib/delphic/errors.rb
lib/delphic/config.rb
lib/delphic/state_db.rb                       # apre/migra ~/.delphic/state.sqlite3
lib/delphic/adapters/sqlite/storage.rb         # da S0, non riscrivere
lib/delphic/adapters/sqlite/schema.rb          # da S0, non riscrivere
lib/delphic/adapters/sqlite/serializer.rb      # da S0, non riscrivere
lib/delphic/cops/no_thread_or_ractor.rb         # eredita/specializza il cop di ruby-dag
lib/delphic/cops/no_direct_step_call.rb
test/test_helper.rb
test/support/fake_model_adapter.rb
test/support/fake_tool.rb
test/support/durable_workflow_factory.rb
test/d0/test_smoke_durable_workflow.rb
test/d0/test_fake_model_determinism.rb
.github/workflows/ci.yml
CHANGELOG.md
README.md
CONTRACT.md                                   # delphic-side, separato da quello di ruby-dag
```

#### Checklist D0

- [ ] Creare gemma `delphic` se S0 non l'ha gia' creata; altrimenti completare lo scaffold S0.
- [ ] Dipendenze runtime:
  - `ruby-dag`, `~> 1.0`, `require: "ruby-dag"`
  - `async`
  - `sqlite3`
- [ ] Cop custom adattati:
  - vieta `Thread`, `Mutex`, `Ractor` nel layer agentico;
  - permette processi solo in boundary espliciti di tool/worker/test;
  - la concorrenza applicativa ordinaria si fa con `Async::Task`;
  - vieta chiamate dirette a `step.call(...)` bypassando il Runner.
- [ ] **Storage applicativo separato.** Tutto lo stato applicativo di `delphic` (ledger, conversation, approval, artifact metadata, budget) vive in un file SQLite **distinto** dal file workflow usato da `Delphic::Adapters::Sqlite::Storage`. Path applicativo di default: `~/.delphic/state.sqlite3`, configurabile via `Delphic::Config`. Il file workflow kernel resta `~/.delphic/workflows.sqlite3` (o path passato esplicitamente).
- [ ] `Delphic::StateDb.install!(path)` crea/migra le tabelle applicative; versionato via `delphic_schema_version`.
- [ ] Implementare `FakeModelAdapter` deterministico in `test/support/`.
- [ ] CI:
  - job bloccante con `ruby-dag ~> 1.0` e SQLite adapter S0 locale;
  - job opzionale/non bloccante con `ruby-dag@head` per regressioni anticipate.

#### DoD D0

- [ ] `bundle exec rake test` passa.
- [ ] `FakeModelAdapter` ritorna risposte deterministiche dato lo stesso prompt.
- [ ] `delphic` riesce a creare un workflow `ruby-dag` durable usando `Delphic::Adapters::Sqlite::Storage` su un file, e a salvare un record applicativo (es. una conversation row) sull'altro file SQLite, in due connessioni separate.
- [ ] I due DB non si "vedono": un drop/reset del DB applicativo non altera lo stato dei workflow kernel.

---

### D1 — Core agentico, ledger, sicurezza effetti esterni

#### Output file obbligatori

```text
lib/delphic/llm_step.rb
lib/delphic/tool_step.rb
lib/delphic/tool_registry.rb
lib/delphic/tools/base.rb
lib/delphic/tool_process_runner.rb             # boundary esplicito per processi esterni
lib/delphic/ledgers/model_invocation_ledger.rb
lib/delphic/ledgers/tool_invocation_ledger.rb
lib/delphic/ledgers/budget_ledger.rb
lib/delphic/fine_stream_bus.rb
lib/delphic/model_adapter.rb                  # port verso provider LLM
lib/delphic/state_db_migrations/002_ledgers.rb
test/d1/test_llm_step_idempotency.rb
test/d1/test_tool_step_destructive_safety.rb
test/d1/test_budget_hard_stop.rb
test/d1/test_resume_does_not_double_charge.rb
test/d1/test_fine_stream_bus_volatile.rb
```

#### Checklist D1

- [ ] Implementare `Delphic::LLMStep`:
  - chiama model adapter;
  - fingerprint da `(model, prompt_template, tools_signature, parser_signature)`;
  - ritorna `Success | Waiting | Failure`.
- [ ] Implementare `Delphic::ToolStep`:
  - invoca tool registrati;
  - fingerprint da `(tool_name, schema_hash, effect)`.
- [ ] Implementare `ToolRegistry` con tassonomia effetti:
  - `:pure`
  - `:idempotent_write`
  - `:destructive`
  - `:external_effect`
- [ ] Firma vincolante della registrazione:
  ```ruby
  Delphic::ToolRegistry.register(
    name:,                    # Symbol, univoco
    klass:,                   # implementa Delphic::Tools::Base
    effect:,                  # uno di :pure, :idempotent_write, :destructive, :external_effect
    input_schema:,            # Hash JSON-Schema-like, frozen
    output_schema:,           # Hash JSON-Schema-like, frozen
    side_effect_token_proc:   # ->(input) { String }, deterministico, richiesto se effect != :pure
  )
  ```
- [ ] Linter: ogni tool registrato senza `effect` esplicito solleva `Delphic::MissingEffectDeclarationError`.
- [ ] Implementare `ToolInvocationLedger` nel DB applicativo separato (`~/.delphic/state.sqlite3`).
- [ ] Implementare `ToolProcessRunner` come unico boundary ammesso per processi esterni: input/output JSON-safe, timeout, working directory esplicita, environment controllato, niente shell implicita.
- [ ] Implementare `ModelInvocationLedger` o cache deterministica per chiamate LLM, stesso DB applicativo.
- [ ] Implementare `BudgetLedger`, stesso DB applicativo.
- [ ] Implementare `FineStreamBus` volatile in RAM per token streaming UI (`Async::Channel` o equivalente Fiber-safe; mai `Queue` thread-based).
- [ ] Fine streaming non viene mai persistito nello storage kernel né nei ledger.

#### Schema ledger consigliato

```text
model_invocations(
  id,
  workflow_id,
  attempt_id,
  model,
  request_fingerprint,
  state,
  planned_at_ms,
  executed_at_ms,
  response_json,
  usage_json
)

tool_invocations(
  id,
  workflow_id,
  attempt_id,
  tool,
  request_fingerprint,
  state,
  planned_at_ms,
  executed_at_ms,
  side_effect_token,
  payload_json
)

budget_entries(
  id,
  workflow_id,
  attempt_id,
  kind,
  amount,
  currency,
  metadata_json,
  created_at_ms
)
```

#### Regola D1 per tool `:destructive` o `:external_effect`

1. Scrive `planned` nel ledger.
2. Genera `side_effect_token` deterministico.
3. Controlla se l’effetto è già stato eseguito.
4. Esegue solo se non già eseguito.
5. Scrive `executed`.
6. Ritorna `Success`.

#### Nota su LLM

Una chiamata LLM è un effetto esterno con costo. Se il processo crasha dopo la chiamata ma prima del commit kernel, il resume non deve generare automaticamente una seconda chiamata a pagamento. Per questo D1 deve usare ledger/cache anche per model invocation.

#### DoD D1

- [ ] `summarize_text_skill` esegue `LLMStep -> ToolStep(:write_file)` in modalità durable.
- [ ] Budget hard stop ritorna `Waiting[reason: :budget_exceeded]`, non eccezione kernel.
- [ ] Kill durante `write_file` copre tre casi:

| Caso | Aspettativa |
|---|---|
| crash prima dell’effetto fisico | resume esegue una volta |
| crash dopo effetto fisico ma prima di `executed` | resume rileva token e non duplica |
| crash dopo `executed` ma prima di commit kernel | resume riusa ledger result e non duplica |

- [ ] FineStreamBus non scrive eventi token-by-token nello storage kernel.

---

### D2 — Interfacce e memoria conversazionale

#### Output file obbligatori

```text
lib/delphic/conversation_store.rb
lib/delphic/conversation.rb
lib/delphic/message.rb
lib/delphic/skill.rb
lib/delphic/skill_registry.rb
lib/delphic/planner.rb
lib/delphic/cli.rb
lib/delphic/cli/run.rb
lib/delphic/cli/chat.rb
lib/delphic/cli/resume.rb
lib/delphic/repl.rb
lib/delphic/state_db_migrations/003_conversations.rb
test/d2/test_planner_selects_skill.rb
test/d2/test_conversation_persistence.rb
test/d2/test_cli_resume.rb
test/d2/test_interfaces_use_coordinator_only.rb
```

#### Checklist D2

- [ ] Conversation Store nel DB applicativo (`~/.delphic/state.sqlite3`):
  - `conversations(id, title, created_at_ms, updated_at_ms, metadata_json)`
  - `messages(id, conversation_id, role, content, tool_calls_json, artifact_refs_json, created_at_ms)`
- [ ] Implementare `Planner` base:
  - legge chat;
  - sceglie Skill via `SkillRegistry`;
  - istanzia Definition template-generata.
- [ ] Implementare CLI:
  - `delphic run <skill>`
  - `delphic chat`
  - `delphic resume <workflow_id>`
- [ ] Implementare REPL con `Reline` stdlib.
- [ ] Regola di confinamento:
  - interfacce chiamano solo `Coordinator`;
  - mai `Runner` direttamente;
  - cop `Delphic::NoDirectRunnerCall` enforce.

#### DoD D2

- [ ] Una conversazione può creare un workflow, ricevere output e salvare messaggi.
- [ ] `delphic resume <workflow_id>` riprende workflow durable.
- [ ] CLI e REPL non bypassano `Coordinator`: il test grep verifica che nessun file in `lib/delphic/cli/**` o `lib/delphic/repl.rb` faccia `require` di `ruby-dag` direttamente.

---

### D3 — Coordinator, approval, artifacts

#### Output file obbligatori

```text
lib/delphic/coordinator.rb
lib/delphic/policy_engine.rb
lib/delphic/approval_request.rb
lib/delphic/approval_store.rb
lib/delphic/artifact_store.rb
lib/delphic/artifact.rb
lib/delphic/state_db_migrations/004_approvals.rb
lib/delphic/state_db_migrations/005_artifacts.rb
test/d3/test_coordinator_approval_loop.rb
test/d3/test_policy_destructive_requires_approval.rb
test/d3/test_artifact_store_content_addressed.rb
test/d3/test_end_to_end_skill_with_approval.rb
```

#### Checklist D3

- [ ] Implementare `Coordinator`:
  - chiama `Runner#call` / `Runner#resume`;
  - legge eventi e `Waiting` reasons;
  - applica policy;
  - decide next action.
- [ ] Implementare `PolicyEngine`:
  - tool `:destructive` o `:external_effect` richiedono approval salvo policy test `auto_approve`;
  - proposed mutation con `confidence < threshold` o `metadata[:high_impact] == true` richiede approval.
- [ ] Implementare `ApprovalRequest` storage:

```text
delphic_approval_requests(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  workflow_id TEXT NOT NULL,
  attempt_id TEXT,
  kind TEXT NOT NULL,                -- 'tool_invocation' | 'mutation' | 'budget_extension'
  payload_json TEXT NOT NULL,
  state TEXT NOT NULL,               -- 'pending' | 'approved' | 'rejected' | 'expired'
  decided_at_ms INTEGER,
  created_at_ms INTEGER NOT NULL,
  decided_by TEXT
)
```

- [ ] Implementare `ArtifactStore` content-addressed:
  - SHA256 del contenuto come ID;
  - filesystem `~/.delphic/artifacts/<sha[0..1]>/<sha[2..]>`;
  - URI `artifact://<sha>`;
  - tabella `delphic_artifacts(sha PRIMARY KEY, mime_type, size_bytes, created_at_ms, metadata_json)` per il metadata, blob su disco.

#### DoD D3

- [ ] Un workflow complesso si interrompe per approval di `:replace_subtree`.
- [ ] Dopo approval, `Coordinator` applica mutation tramite `MutationService`.
- [ ] Completa il workflow.
- [ ] Salva output come artifact.
- [ ] Cita l'artifact nella conversazione successiva via `artifact://<sha>`.
- [ ] `delphic_approval_requests.id` è `PRIMARY KEY AUTOINCREMENT` e i test verificano unicità.

---

### Traguardo FASE 2: `delphic v1.0`

- [ ] D0, D1, D2, D3 verdi in CI.
- [ ] Workflow durable end-to-end con SQLite.
- [ ] LLM/tool ledger copre resume senza doppio effetto.
- [ ] Approval flow funzionante.
- [ ] ArtifactStore funzionante.
- [ ] CLI base funzionante.

---

### D4 — Automazione e produzione post-v1.0

D4 non blocca `delphic v1.0`.

- [ ] Scheduler daemon `delphic-scheduler`:
  - risveglia workflow `Waiting[not_before_ms: T]` quando `T <= now_ms`.
- [ ] Memoria semantica:
  - integrazione VectorDB / Engram / adapter dedicato.
- [ ] Multi-tenancy, se serve:
  - namespace per workspace/utente nei DB.
- [ ] Osservabilità production:
  - metrics;
  - structured logs;
  - tracing applicativo.

---

## 9. Anti-pattern di reiezione

Una PR che introduce anche solo una di queste violazioni non passa review.

### 9.1 Repo `ruby-dag`

| Anti-pattern | Dove è vietato | Mitigazione |
|---|---|---|
| `Ractor`, `Ractor.new`, `Ractor.receive`, `Ractor.yield` | tutto il repo, incluso `test/**` | `DAG::NoThreadOrRactor` |
| `Thread.new`, `Thread.start`, `Thread.fork` | tutto il repo, incluso `test/**` | `DAG::NoThreadOrRactor` |
| `Mutex`, `Monitor`, `Queue`, `SizedQueue`, `ConditionVariable` | tutto il repo, incluso `test/**` e adapter Memory | `DAG::NoThreadOrRactor` |
| `Process.fork`, `Process.spawn`, `system`, backtick shell, `%x` | `lib/dag/**` | `DAG::NoThreadOrRactor`; `Process.clock_gettime` resta consentito |
| `attr_accessor`, `attr_writer` | tutto `lib/dag/**` | `DAG::NoMutableAccessors` |
| `push`, `<<`, `merge!`, `update`, `delete`, `clear`, `shift`, `pop`, `[]=` su stato kernel | kernel puro | `DAG::NoInPlaceMutation` |
| `add_dependency` nel gemspec `ruby-dag` | gemspec | test zero runtime deps |
| `require` di librerie non stdlib | runtime | `DAG::NoExternalRequires` |
| Termini AI nel kernel: `prompt`, `token`, `model`, `skill`, `conversation`, `llm` | kernel | grep test + review |
| Budget o approval dentro `Runner` | kernel | restano in `delphic` |
| Fine events token-by-token salvati su `Storage` | kernel | storage non espone API di streaming |
| Mutation applicata direttamente da `Definition` con side-effect | kernel | usare `MutationService` |
| Default singleton iniettato in `Runner.new` | kernel | tutte le 7 dipendenze sono argument keyword obbligatori |

### 9.2 Adapter SQLite S0 in `delphic`

| Anti-pattern | Dove è vietato | Mitigazione |
|---|---|---|
| Implementare SQLite dentro `ruby-dag` | kernel | l'adapter durable vive in `Delphic::Adapters::Sqlite::Storage` |
| Condividere una connessione SQLite tra processi dopo `fork` | test e runtime S0 | ogni processo apre il proprio `Delphic::Adapters::Sqlite::Storage` |
| CAS implementato fuori transazione | storage SQLite S0 | `BEGIN IMMEDIATE`, `UPDATE ... WHERE state = ?`, controllo `changes == 1` |
| Test process-level su `Memory::Storage` | test | usare SQLite per concorrenza reale |
| `Thread`/`Ractor` per parallelizzare test | tutto il repo `delphic` | usare processi figli |

### 9.3 Repo `delphic`

| Anti-pattern | Mitigazione |
|---|---|
| `Thread.new`, `Mutex.new`, `Ractor.new` nel layer agentico | usare `Async::Task`; cop custom |
| `Process.spawn`, `Process.fork`, backtick shell o `system` fuori da `ToolProcessRunner`, worker espliciti o test | usare boundary processuale dedicato, con timeout e input/output JSON-safe |
| Chiamata diretta `step.call(...)` bypassando `Runner` | cop `Delphic::NoDirectStepCall` |
| Tool destructive eseguito senza ledger `planned` | test integrazione + linter |
| Chiamata LLM durable senza ledger/cache | test resume + ledger obbligatorio |
| Chat history dentro storage kernel | DB applicativo separato |
| Scheduler che avvia workflow bypassando `Coordinator` | scheduler emette richieste al Coordinator |

## 10. Appendici implementative

### Appendice A — Immutability utilities

```ruby
# lib/dag/immutability.rb
module DAG
  module_function

  JSON_KEY_CLASSES = [String, Symbol].freeze
  JSON_SCALAR_CLASSES = [String, Integer, Float, TrueClass, FalseClass, NilClass, Symbol].freeze

  def deep_freeze(value)
    case value
    when Hash
      value.each { |k, v| deep_freeze(k); deep_freeze(v) }
    when Array
      value.each { |v| deep_freeze(v) }
    end
    value.freeze
  end

  def deep_dup(value)
    case value
    when Hash
      value.each_with_object({}) { |(k, v), h| h[deep_dup(k)] = deep_dup(v) }
    when Array
      value.map { |v| deep_dup(v) }
    when String
      value.dup
    else
      value
    end
  end

  def json_safe!(value, path = "$root")
    case value
    when Hash
      seen = {}
      value.each do |k, v|
        unless k.is_a?(String) || k.is_a?(Symbol)
          raise ArgumentError, "non JSON-safe key at #{path}: #{k.class}"
        end

        canonical_key = k.to_s
        if seen.key?(canonical_key)
          raise ArgumentError, "canonical key collision at #{path}: #{canonical_key.inspect}"
        end

        seen[canonical_key] = true
        json_safe!(v, "#{path}.#{canonical_key}")
      end
    when Array
      value.each_with_index { |v, i| json_safe!(v, "#{path}[#{i}]") }
    when Float
      raise ArgumentError, "non-finite float at #{path}" if value.nan? || value.infinite?
    when String, Integer, TrueClass, FalseClass, NilClass, Symbol
      true
    else
      raise ArgumentError, "non JSON-safe value at #{path}: #{value.class}"
    end
    value
  end
end
```

---

### Appendice B — Tagged types

```ruby
# lib/dag/types.rb
module DAG
  Success = Data.define(:value, :context_patch, :proposed_mutations, :metadata) do
    def self.[](value: nil, context_patch: {}, proposed_mutations: [], metadata: {})
      DAG.json_safe!(value, "$root.value")
      DAG.json_safe!(context_patch, "$root.context_patch")
      DAG.json_safe!(metadata, "$root.metadata")

      proposed_mutations.each do |mutation|
        unless mutation.is_a?(DAG::ProposedMutation)
          raise ArgumentError, "proposed_mutations must contain ProposedMutation"
        end
      end

      new(
        value: DAG.deep_freeze(DAG.deep_dup(value)),
        context_patch: DAG.deep_freeze(DAG.deep_dup(context_patch)),
        proposed_mutations: DAG.deep_freeze(proposed_mutations.dup),
        metadata: DAG.deep_freeze(DAG.deep_dup(metadata))
      )
    end
  end

  Waiting = Data.define(:reason, :resume_token, :not_before_ms, :metadata) do
    def self.[](reason:, resume_token: nil, not_before_ms: nil, metadata: {})
      raise ArgumentError, "reason must be Symbol" unless reason.is_a?(Symbol)
      unless not_before_ms.nil? || not_before_ms.is_a?(Integer)
        raise ArgumentError, "not_before_ms must be Integer milliseconds or nil"
      end

      DAG.json_safe!(resume_token, "$root.resume_token")
      DAG.json_safe!(metadata, "$root.metadata")

      new(
        reason: reason,
        resume_token: DAG.deep_freeze(DAG.deep_dup(resume_token)),
        not_before_ms: not_before_ms,
        metadata: DAG.deep_freeze(DAG.deep_dup(metadata))
      )
    end

    def self.at(reason:, time:, resume_token: nil, metadata: {})
      self[
        reason: reason,
        resume_token: resume_token,
        not_before_ms: (time.to_f * 1000).to_i,
        metadata: metadata
      ]
    end
  end

  Failure = Data.define(:error, :retriable, :metadata) do
    def self.[](error:, retriable: false, metadata: {})
      DAG.json_safe!(error, "$root.error")
      DAG.json_safe!(metadata, "$root.metadata")

      new(
        error: DAG.deep_freeze(DAG.deep_dup(error)),
        retriable: !!retriable,
        metadata: DAG.deep_freeze(DAG.deep_dup(metadata))
      )
    end
  end

  StepInput = Data.define(:context, :node_id, :attempt_number, :metadata) do
    def self.[](context:, node_id:, attempt_number: 1, metadata: {})
      DAG.json_safe!(metadata, "$root.metadata")

      new(
        context: context,
        node_id: node_id,
        attempt_number: attempt_number,
        metadata: DAG.deep_freeze(DAG.deep_dup(metadata))
      )
    end
  end

  ReplacementGraph = Data.define(:graph, :entry_node_ids, :exit_node_ids) do
    def self.[](graph:, entry_node_ids:, exit_node_ids:)
      raise ArgumentError, "entry_node_ids cannot be empty" if entry_node_ids.empty?
      raise ArgumentError, "exit_node_ids cannot be empty" if exit_node_ids.empty?

      new(
        graph: graph,
        entry_node_ids: DAG.deep_freeze(entry_node_ids.dup),
        exit_node_ids: DAG.deep_freeze(exit_node_ids.dup)
      )
    end
  end

  ProposedMutation = Data.define(
    :kind,
    :target_node_id,
    :replacement_graph,
    :rationale,
    :confidence,
    :metadata
  ) do
    KINDS = %i[replace_subtree invalidate].freeze

    def self.[](kind:, target_node_id:, replacement_graph: nil, rationale: nil, confidence: 1.0, metadata: {})
      raise ArgumentError, "invalid kind: #{kind}" unless KINDS.include?(kind)
      if kind == :replace_subtree && !replacement_graph.is_a?(DAG::ReplacementGraph)
        raise ArgumentError, "replace_subtree requires replacement_graph"
      end
      if kind == :invalidate && !replacement_graph.nil?
        raise ArgumentError, "invalidate does not accept replacement_graph"
      end

      DAG.json_safe!(rationale, "$root.rationale")
      DAG.json_safe!(confidence, "$root.confidence")
      DAG.json_safe!(metadata, "$root.metadata")

      new(
        kind: kind,
        target_node_id: target_node_id,
        replacement_graph: replacement_graph,
        rationale: DAG.deep_freeze(DAG.deep_dup(rationale)),
        confidence: confidence,
        metadata: DAG.deep_freeze(DAG.deep_dup(metadata))
      )
    end
  end

  RuntimeProfile = Data.define(:durability, :max_attempts_per_node, :max_workflow_retries, :event_bus_kind, :metadata) do
    DURABILITY = %i[ephemeral durable].freeze

    def self.[](durability:, max_attempts_per_node:, max_workflow_retries:, event_bus_kind:, metadata: {})
      raise ArgumentError, "invalid durability" unless DURABILITY.include?(durability)
      unless max_attempts_per_node.is_a?(Integer) && max_attempts_per_node.positive?
        raise ArgumentError, "max_attempts_per_node must be a positive Integer"
      end
      unless max_workflow_retries.is_a?(Integer) && !max_workflow_retries.negative?
        raise ArgumentError, "max_workflow_retries must be a non-negative Integer"
      end
      DAG.json_safe!(metadata, "$root.metadata")

      new(
        durability: durability,
        max_attempts_per_node: max_attempts_per_node,
        max_workflow_retries: max_workflow_retries,
        event_bus_kind: event_bus_kind,
        metadata: DAG.deep_freeze(DAG.deep_dup(metadata))
      )
    end

    def self.default
      self[
        durability: :ephemeral,
        max_attempts_per_node: 3,
        max_workflow_retries: 0,
        event_bus_kind: :null,
        metadata: {}
      ]
    end
  end

  RunResult = Data.define(:state, :last_event_seq, :outcome, :metadata)

  Event = Data.define(
    :seq,
    :type,
    :workflow_id,
    :revision,
    :node_id,
    :attempt_id,
    :at_ms,
    :payload
  ) do
    TYPES = %i[
      workflow_started
      node_started
      node_committed
      node_waiting
      node_failed
      workflow_paused
      workflow_waiting
      workflow_completed
      workflow_failed
      mutation_applied
    ].freeze

    def self.[](seq: nil, type:, workflow_id:, revision:, node_id: nil, attempt_id: nil, at_ms:, payload: {})
      raise ArgumentError, "invalid event type: #{type}" unless TYPES.include?(type)
      DAG.json_safe!(payload, "$root.payload")

      new(
        seq: seq,
        type: type,
        workflow_id: workflow_id,
        revision: revision,
        node_id: node_id,
        attempt_id: attempt_id,
        at_ms: at_ms,
        payload: DAG.deep_freeze(DAG.deep_dup(payload))
      )
    end
  end
end
```

---

### Appendice C — Storage port

```ruby
# lib/dag/ports/storage.rb
module DAG
  module Ports
    module Storage
      def create_workflow(id:, initial_definition:, initial_context:, runtime_profile:)
        raise PortNotImplementedError
        # => WorkflowRecord/hash:
        #    id, state, current_revision, initial_context, runtime_profile
      end

      def load_workflow(id:)
        raise PortNotImplementedError
      end

      def transition_workflow_state(id:, from:, to:, event: nil)
        raise PortNotImplementedError
        # atomico: CAS workflow state e, quando event è presente,
        # append dell'evento nello stesso step.
        # => {id:, state:, event: stamped_or_nil}
      end

      def append_revision(id:, parent_revision:, definition:, invalidated_node_ids:, event:)
        raise PortNotImplementedError
        # atomico: append revision + mark invalidations + append mutation_applied event
        # => new_revision
      end

      def load_revision(id:, revision:)
        raise PortNotImplementedError
      end

      def load_current_definition(id:)
        raise PortNotImplementedError
      end

      def load_node_states(workflow_id:, revision:)
        raise PortNotImplementedError
      end

      def transition_node_state(workflow_id:, revision:, node_id:, from:, to:)
        raise PortNotImplementedError
      end

      def begin_attempt(workflow_id:, revision:, node_id:, expected_node_state:, attempt_number:)
        raise PortNotImplementedError
        # CAS node state -> :running + create attempt(:running)
        # attempt_number è calcolato dal Runner e persistito dallo storage senza ricalcolo
        # => attempt_id
      end

      def commit_attempt(attempt_id:, result:, node_state:, event:, effects: [])
        raise PortNotImplementedError
        # atomico: persist result + attempt state + node state + append event
        # + reserve/link effect records.
        # node_state: :committed | :waiting | :failed | :pending
        # :pending è ammesso solo per failure retriable, dopo aver marcato l'attempt failed.
        # effects: Array<DAG::Effects::PreparedIntent>
        # => stamped Event
      end

      def list_effects_for_node(workflow_id:, revision:, node_id:)
        raise PortNotImplementedError
        # => Array<DAG::Effects::Record>
      end

      def list_effects_for_attempt(attempt_id:)
        raise PortNotImplementedError
        # => Array<DAG::Effects::Record>
      end

      def claim_ready_effects(limit:, owner_id:, lease_ms:, now_ms:)
        raise PortNotImplementedError
        # atomico: claim di :reserved, :failed_retriable due, o :dispatching scaduti
        # => Array<DAG::Effects::Record>
      end

      def mark_effect_succeeded(effect_id:, owner_id:, result:, external_ref:, now_ms:)
        raise PortNotImplementedError
        # richiede lease owner valido, altrimenti DAG::Effects::StaleLeaseError
        # => DAG::Effects::Record
      end

      def mark_effect_failed(effect_id:, owner_id:, error:, retriable:, not_before_ms:, now_ms:)
        raise PortNotImplementedError
        # retriable true -> :failed_retriable; retriable false -> :failed_terminal
        # richiede lease owner valido, altrimenti DAG::Effects::StaleLeaseError
        # => DAG::Effects::Record
      end

      def release_nodes_satisfied_by_effect(effect_id:, now_ms:)
        raise PortNotImplementedError
        # node :waiting -> :pending solo quando tutti gli effetti blocking
        # collegati all'attempt waiting sono terminali.
        # => Array<Hash>
      end

      def abort_running_attempts(workflow_id:)
        raise PortNotImplementedError
        # idempotente: attempt :running -> :aborted, node :running -> :pending
      end

      def list_attempts(workflow_id:, revision: nil, node_id: nil)
        raise PortNotImplementedError
      end

      def count_attempts(workflow_id:, revision:, node_id:)
        raise PortNotImplementedError
      end

      def append_event(workflow_id:, event:)
        raise PortNotImplementedError
        # => Event con seq monotonic assegnato
      end

      def read_events(workflow_id:, after_seq: nil, limit: nil)
        raise PortNotImplementedError
      end

      def prepare_workflow_retry(id:, from: :failed, to: :pending, event: nil)
        raise PortNotImplementedError
        # atomico: CAS workflow state + retry budget, abort failed attempts,
        # reset failed nodes, increment workflow_retry_count, transition workflow,
        # append event quando presente.
        # => {id:, state:, reset:, workflow_retry_count:, event: stamped_or_nil}
      end
    end
  end
end
```

---

### Appendice D — Altri ports

```ruby
# lib/dag/ports/event_bus.rb
module DAG
  module Ports
    module EventBus
      def publish(event)
        raise PortNotImplementedError
      end

      def subscribe(&block)
        raise PortNotImplementedError
      end
    end
  end
end

# lib/dag/ports/fingerprint.rb
module DAG
  module Ports
    module Fingerprint
      def compute(value)
        raise PortNotImplementedError
      end
    end
  end
end

# lib/dag/ports/clock.rb
module DAG
  module Ports
    module Clock
      def now
        raise PortNotImplementedError
      end

      def now_ms
        raise PortNotImplementedError
      end

      def monotonic_ms
        raise PortNotImplementedError
      end
    end
  end
end

# lib/dag/ports/id_generator.rb
module DAG
  module Ports
    module IdGenerator
      def call
        raise PortNotImplementedError
      end
    end
  end
end

# lib/dag/ports/serializer.rb
module DAG
  module Ports
    module Serializer
      def dump(value)
        raise PortNotImplementedError
      end

      def load(blob)
        raise PortNotImplementedError
      end
    end
  end
end
```

---

### Appendice E — Default adapters

```ruby
# lib/dag/adapters/stdlib/fingerprint.rb
require "digest"
require "json"

module DAG
  module Adapters
    module Stdlib
      class Fingerprint
        include Ports::Fingerprint

        def compute(value)
          DAG.json_safe!(value)
          Digest::SHA256.hexdigest(JSON.generate(deep_canonical(value)))
        end

        private

        def deep_canonical(value)
          case value
          when Hash
            seen = {}
            pairs = value.map do |k, v|
              key = k.to_s
              raise ArgumentError, "canonical key collision: #{key.inspect}" if seen[key]
              seen[key] = true
              [key, deep_canonical(v)]
            end
            pairs.sort_by(&:first).to_h
          when Array
            value.map { |v| deep_canonical(v) }
          when Symbol
            value.to_s
          when Float
            raise ArgumentError, "non-finite float" if value.nan? || value.infinite?
            value
          when String, Integer, TrueClass, FalseClass, NilClass
            value
          else
            raise ArgumentError, "unsupported fingerprint type: #{value.class}"
          end
        end
      end
    end
  end
end
```

```ruby
# lib/dag/adapters/stdlib/clock.rb
module DAG
  module Adapters
    module Stdlib
      class Clock
        include Ports::Clock

        def now
          Time.now
        end

        def now_ms
          (now.to_f * 1000).to_i
        end

        def monotonic_ms
          (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
        end
      end
    end
  end
end
```

```ruby
# lib/dag/adapters/stdlib/id_generator.rb
require "securerandom"

module DAG
  module Adapters
    module Stdlib
      class IdGenerator
        include Ports::IdGenerator

        def call
          SecureRandom.uuid
        end
      end
    end
  end
end
```

```ruby
# lib/dag/adapters/null/event_bus.rb
module DAG
  module Adapters
    module Null
      class EventBus
        include Ports::EventBus

        def initialize(logger: nil)
          @logger = logger
          freeze
        end

        def publish(event)
          @logger&.debug("[dag] #{event.inspect}")
          nil
        end

        def subscribe(&block)
          nil
        end
      end
    end
  end
end
```

```ruby
# lib/dag/adapters/memory/event_bus.rb
module DAG
  module Adapters
    module Memory
      class EventBus
        include Ports::EventBus

        def initialize(buffer_size: 1000)
          @buffer_size = buffer_size
          @events = []
          @subscribers = []
        end

        def publish(event)
          frozen_event = DAG.deep_freeze(DAG.deep_dup(event))
          @events << frozen_event
          @events.shift if @events.size > @buffer_size
          @subscribers.each { |subscriber| subscriber.call(frozen_event) }
          nil
        end

        def subscribe(&block)
          raise ArgumentError, "block required" unless block

          @subscribers << block
          -> { @subscribers.delete(block) }
        end

        def events
          DAG.deep_freeze(DAG.deep_dup(@events))
        end
      end
    end
  end
end
```

`Memory::EventBus` è volutamente single-process e non thread-safe. Serve per test, REPL e CLI locali. Il bus live per streaming agentico vive in `delphic` come `FineStreamBus` fiber-safe.

```ruby
# lib/dag/adapters/memory/storage.rb
module DAG
  module Adapters
    module Memory
      class Storage
        include Ports::Storage

        def initialize(initial_state: nil)
          @state = initial_state || {
            workflows: {},
            revisions: {},
            node_states: {},
            attempts: {},
            events: Hash.new { |h, k| h[k] = [] },
            seq: Hash.new(0)
          }
        end

        def create_workflow(**args)
          dispatch(:create_workflow, args)
        end

        def load_workflow(**args)
          dispatch(:load_workflow, args)
        end

        def transition_workflow_state(**args)
          dispatch(:transition_workflow_state, args)
        end

        def append_revision(**args)
          dispatch(:append_revision, args)
        end

        def load_revision(**args)
          dispatch(:load_revision, args)
        end

        def load_current_definition(**args)
          dispatch(:load_current_definition, args)
        end

        def load_node_states(**args)
          dispatch(:load_node_states, args)
        end

        def transition_node_state(**args)
          dispatch(:transition_node_state, args)
        end

        def begin_attempt(**args)
          dispatch(:begin_attempt, args)
        end

        def commit_attempt(**args)
          dispatch(:commit_attempt, args)
        end

        def abort_running_attempts(**args)
          dispatch(:abort_running_attempts, args)
        end

        def list_attempts(**args)
          dispatch(:list_attempts, args)
        end

        def count_attempts(**args)
          dispatch(:count_attempts, args)
        end

        def append_event(**args)
          dispatch(:append_event, args)
        end

        def read_events(**args)
          dispatch(:read_events, args)
        end

        private

        def dispatch(method_name, args)
          safe_args = DAG.deep_freeze(DAG.deep_dup(args))
          result = StorageState.dispatch(@state, method_name, safe_args)
          DAG.deep_freeze(DAG.deep_dup(result))
        end
      end
    end
  end
end
```

`DAG::Adapters::Memory::StorageState` è il modulo che possiede la logica mutabile privata dello storage in-memory. Può modificare lo hash `@state` in-place perché è un adapter single-process, escluso dal cop `NoInPlaceMutation`, e non espone mai riferimenti mutabili.

Vincoli per `Memory::Storage`:

- non usare `Thread`, `Mutex`, `Queue`, `Ractor`, `Process.fork`, `Process.spawn`;
- non fare I/O, `sleep`, `Fiber.yield`, callback o await dentro metodi pubblici;
- non dichiararsi process-safe;
- usare solo come backend per test deterministici e workflow ephemeral;
- usare SQLite o altro adapter durable per concorrenza reale.

---

### Appendice F — Custom RuboCop cops

---

### Appendice F — Custom RuboCop cops

#### `NoThreadOrRactor`

Regole:

- vieta `Thread.new`, `Thread.start`, `Thread.fork` ovunque, incluso `test/**`;
- vieta `Ractor`, `Ractor.new`, `Ractor.receive`, `Ractor.yield` ovunque, incluso `test/**`;
- vieta `Mutex.new`, `Monitor.new`, `Queue.new`, `SizedQueue.new`, `ConditionVariable.new` ovunque, incluso `test/**` e adapter Memory;
- vieta process spawn nel runtime `lib/dag/**`: `Process.fork`, `Process.spawn`, `Process.daemon`, `Kernel.system`, backtick shell e `%x`; `Process.clock_gettime` resta consentito;
- i test S0 possono usare `Process.fork` perché verificano il backend SQLite, non il kernel.

```ruby
# rubocop/cop/dag/no_thread_or_ractor.rb
module RuboCop
  module Cop
    module DAG
      class NoThreadOrRactor < Base
        MSG = "ruby-dag forbids concurrency primitive %<n>s here."

        FORBIDDEN_THREAD_CALLS = {
          Thread: %i[new start fork]
        }.freeze

        FORBIDDEN_CONSTANTS_NEW = %i[
          Mutex Monitor Queue SizedQueue ConditionVariable
        ].freeze

        FORBIDDEN_RACTOR_CALLS = %i[
          new receive yield select make_shareable shareable?
        ].freeze

        FORBIDDEN_PROCESS_CALLS_IN_KERNEL = %i[
          fork spawn daemon
        ].freeze

        def on_send(node)
          receiver = node.receiver
          method = node.method_name

          check_constant_send(node, receiver, method) if receiver&.const_type?
          check_kernel_process_spawn(node, receiver, method)
        end

        def on_const(node)
          return unless node.const_name == "Ractor"

          add_offense(node, message: format(MSG, n: "Ractor"))
        end

        private

        def check_constant_send(node, receiver, method)
          name = receiver.const_name&.to_sym

          if FORBIDDEN_THREAD_CALLS.fetch(name, []).include?(method)
            add_offense(node, message: format(MSG, n: "#{name}.#{method}"))
            return
          end

          if name == :Ractor && FORBIDDEN_RACTOR_CALLS.include?(method)
            add_offense(node, message: format(MSG, n: "Ractor.#{method}"))
            return
          end

          if method == :new && FORBIDDEN_CONSTANTS_NEW.include?(name)
            add_offense(node, message: format(MSG, n: "#{name}.new"))
          end
        end

        def check_kernel_process_spawn(node, receiver, method)
          return unless processed_source.file_path.include?("/lib/dag/")

          if receiver&.const_type? && receiver.const_name == "Process" && FORBIDDEN_PROCESS_CALLS_IN_KERNEL.include?(method)
            add_offense(node, message: format(MSG, n: "Process.#{method}"))
            return
          end

          if receiver.nil? && method == :system
            add_offense(node, message: format(MSG, n: "system"))
          end
        end
      end
    end
  end
end
```

#### `NoMutableAccessors`

#### `NoMutableAccessors`

```ruby
# rubocop/cop/dag/no_mutable_accessors.rb
module RuboCop
  module Cop
    module DAG
      class NoMutableAccessors < Base
        MSG = "Public ruby-dag classes must be immutable. Use attr_reader only."
        RESTRICT_ON_SEND = %i[attr_accessor attr_writer].freeze

        def on_send(node)
          add_offense(node) if RESTRICT_ON_SEND.include?(node.method_name)
        end
      end
    end
  end
end
```

#### `NoExternalRequires`

```ruby
# rubocop/cop/dag/no_external_requires.rb
module RuboCop
  module Cop
    module DAG
      class NoExternalRequires < Base
        MSG = "ruby-dag must have zero runtime deps. '%<lib>s' is not allowed."

        STDLIB = %w[
          digest digest/sha2 securerandom json set forwardable singleton
          time logger pathname fileutils
        ].freeze

        def_node_matcher :require_call?, <<~PATTERN
          (send nil? :require (str $_))
        PATTERN

        def on_send(node)
          lib = require_call?(node)
          return unless lib
          return if STDLIB.include?(lib)

          add_offense(node, message: format(MSG, lib: lib))
        end
      end
    end
  end
end
```

#### `NoInPlaceMutation`

Scope: kernel puro. Gli adapter stateful sono esclusi ma non devono esporre riferimenti mutabili.

Metodi minimi da intercettare:

```text
push
<<
merge!
update
delete
clear
shift
pop
[]=
```

---

### Appendice G — Scenari di test esemplificativi

#### R1 — Linear workflow

```ruby
# test/r1/test_linear_workflow.rb
require "test_helper"

class TestLinearWorkflow < Minitest::Test
  def test_passthrough_chain_propagates_context
    storage = DAG::Adapters::Memory::Storage.new
    event_bus = DAG::Adapters::Memory::EventBus.new
    runner = build_runner(storage: storage, event_bus: event_bus)

    definition = DAG::Workflow::Definition.new
      .add_node(:a, type: :passthrough)
      .add_node(:b, type: :passthrough)
      .add_node(:c, type: :passthrough)
      .add_edge(:a, :b)
      .add_edge(:b, :c)

    workflow_id = SecureRandom.uuid
    storage.create_workflow(
      id: workflow_id,
      initial_definition: definition,
      initial_context: { x: 1 },
      runtime_profile: DAG::RuntimeProfile.default
    )

    result = runner.call(workflow_id)

    assert_equal :completed, result.state
    attempts = storage.list_attempts(workflow_id: workflow_id, node_id: :c)
    assert_equal({ x: 1 }, attempts.last[:result].context_patch)
    assert_includes event_bus.events.map(&:type), :workflow_completed
  end
end
```

#### R1 — Many workflows in process

```ruby
# test/r1/test_many_workflows_single_process.rb
require "test_helper"

class TestManyWorkflowsSingleProcess < Minitest::Test
  def test_100_workflows_complete_in_one_process
    storage = DAG::Adapters::Memory::Storage.new
    runner = build_runner(storage: storage)
    ids = Array.new(100) { SecureRandom.uuid }

    ids.each do |id|
      storage.create_workflow(
        id: id,
        initial_definition: simple_definition,
        initial_context: {},
        runtime_profile: DAG::RuntimeProfile.default
      )
    end

    ids.each { |id| runner.call(id) }

    ids.each do |id|
      assert_equal :completed, storage.load_workflow(id: id)[:state]
    end
  end
end
```

`Memory::Storage` non viene usato per test process-level perché non è uno storage condiviso fra processi. La concorrenza reale parte in S0 con SQLite.

#### S0 — Process-level runners with SQLite

```ruby
# test/s0/test_process_concurrency.rb
require "test_helper"

class TestSqliteProcessConcurrency < Minitest::Test
  def test_100_workflows_on_10_processes
    db_path = tmp_path("dag-process-concurrency.sqlite3")
    setup_storage = Delphic::Adapters::Sqlite::Storage.new(path: db_path)
    ids = Array.new(100) { SecureRandom.uuid }

    ids.each do |id|
      setup_storage.create_workflow(
        id: id,
        initial_definition: simple_definition,
        initial_context: {},
        runtime_profile: DAG::RuntimeProfile.default
      )
    end

    pids = ids.each_slice(10).map do |chunk|
      Process.fork do
        begin
          storage = Delphic::Adapters::Sqlite::Storage.new(path: db_path)
          runner = build_runner(storage: storage)
          chunk.each { |id| runner.call(id) }
          exit! 0
        rescue StandardError => e
          warn e.full_message
          exit! 1
        end
      end
    end

    pids.each do |pid|
      Process.wait(pid)
      assert $?.success?, "child process #{pid} failed"
    end

    verify_storage = Delphic::Adapters::Sqlite::Storage.new(path: db_path)
    ids.each do |id|
      assert_equal :completed, verify_storage.load_workflow(id: id)[:state]
    end
  end
end
```

Ogni processo figlio apre una nuova istanza dello storage. Non condividere mai una connessione SQLite creata prima del `fork`.

#### R2 — Crash recovery

#### R2 — Crash recovery

```ruby
# test/r2/test_resume_after_crash.rb
require "test_helper"

class TestResumeAfterCrash < Minitest::Test
  def test_kill_before_b_commit_resumes_from_b
    storage = DAG::Adapters::Memory::CrashableStorage.new(
      crash_on: { method: :commit_attempt, node_id: :b, before_commit: true }
    )

    call_log = []
    registry = registry_with_logging_step(call_log)
    runner = build_runner(storage: storage, registry: registry)

    id = create_workflow(storage, three_node_chain(:a, :b, :c))

    assert_raises(DAG::Adapters::Memory::SimulatedCrash) { runner.call(id) }

    healthy_storage = storage.snapshot_to_healthy
    runner = build_runner(storage: healthy_storage, registry: registry)
    result = runner.resume(id)

    assert_equal :completed, result.state
    assert_equal 1, call_log.count(:a)
    assert_equal 2, call_log.count(:b)
    assert_equal 1, call_log.count(:c)
  end
end
```

#### R3 — Replacement preserves parallel branch

```ruby
# test/r3/test_replace_subtree_preserves_parallel.rb
require "test_helper"

class TestReplaceSubtreePreservesParallel < Minitest::Test
  def test_replace_b_preserves_c_invalidates_d
    definition = DAG::Workflow::Definition.new
      .add_node(:a).add_node(:b).add_node(:c).add_node(:d)
      .add_edge(:a, :b).add_edge(:a, :c)
      .add_edge(:b, :d).add_edge(:c, :d)

    replacement_graph = DAG::Graph.new
      .add_node(:b_prime)
      .add_node(:b_double)
      .add_edge(:b_prime, :b_double)

    mutation = DAG::ProposedMutation[
      kind: :replace_subtree,
      target_node_id: :b,
      replacement_graph: DAG::ReplacementGraph[
        graph: replacement_graph,
        entry_node_ids: [:b_prime],
        exit_node_ids: [:b_double]
      ]
    ]

    result = mutation_service.apply(
      workflow_id: workflow_id,
      mutation: mutation,
      expected_revision: 1
    )

    assert_equal 2, result.definition.revision
    refute result.definition.has_node?(:b)
    assert result.definition.has_node?(:b_prime)
    assert_equal :committed, node_state(storage, workflow_id, :a)
    assert_equal :committed, node_state(storage, workflow_id, :c)
    assert_equal :invalidated, node_state(storage, workflow_id, :d)
  end
end
```

---

### Appendice H — Test helpers e Runner factory

I test in tutte le fasi usano questi helper, da introdurre in R1.

```ruby
# test/support/runner_factory.rb
module RunnerFactory
  def build_runner(storage:, event_bus: nil, registry: nil, clock: nil,
                   id_generator: nil, fingerprint: nil, serializer: nil)
    DAG::Runner.new(
      storage: storage,
      event_bus: event_bus || DAG::Adapters::Null::EventBus.new,
      registry: registry || default_test_registry,
      clock: clock || DAG::Adapters::Stdlib::Clock.new,
      id_generator: id_generator || DAG::Adapters::Stdlib::IdGenerator.new,
      fingerprint: fingerprint || DAG::Adapters::Stdlib::Fingerprint.new,
      serializer: serializer || DAG::Adapters::Stdlib::Serializer.new
    )
  end

  def default_test_registry
    registry = DAG::StepTypeRegistry.new
    registry.register(name: :passthrough, klass: DAG::BuiltinSteps::Passthrough,
                      fingerprint_payload: { v: 1 })
    registry.register(name: :noop, klass: DAG::BuiltinSteps::Noop,
                      fingerprint_payload: { v: 1 })
    registry.freeze!
    registry
  end
end
```

```ruby
# test/support/workflow_builders.rb
module WorkflowBuilders
  def simple_definition
    DAG::Workflow::Definition.new
      .add_node(:a, type: :passthrough)
      .add_node(:b, type: :passthrough)
      .add_edge(:a, :b)
  end

  def three_node_chain(a, b, c)
    DAG::Workflow::Definition.new
      .add_node(a, type: :passthrough)
      .add_node(b, type: :passthrough)
      .add_node(c, type: :passthrough)
      .add_edge(a, b)
      .add_edge(b, c)
  end

  def fan_out_fan_in(root, branches, sink)
    definition = DAG::Workflow::Definition.new.add_node(root, type: :passthrough)
    branches.each { |id| definition = definition.add_node(id, type: :passthrough).add_edge(root, id) }
    definition = definition.add_node(sink, type: :passthrough)
    branches.each { |id| definition = definition.add_edge(id, sink) }
    definition
  end

  def create_workflow(storage, definition, initial_context: {})
    id = SecureRandom.uuid
    storage.create_workflow(
      id: id,
      initial_definition: definition,
      initial_context: initial_context,
      runtime_profile: DAG::RuntimeProfile.default
    )
    id
  end
end
```

```ruby
# test/support/step_helpers.rb
module StepHelpers
  def registry_with_logging_step(call_log)
    registry = DAG::StepTypeRegistry.new
    log_class = Class.new(DAG::Step::Base) do
      define_method(:call) do |input|
        call_log << input.node_id
        DAG::Success[value: input.node_id, context_patch: { input.node_id => :seen }]
      end
    end
    registry.register(name: :logging, klass: log_class, fingerprint_payload: { v: 1 })
    registry.freeze!
    registry
  end

  def node_state(storage, workflow_id, node_id)
    storage.load_node_states(workflow_id: workflow_id, revision: storage.load_workflow(id: workflow_id)[:current_revision])[node_id]
  end
end
```

`test/test_helper.rb` deve fare `include RunnerFactory, WorkflowBuilders, StepHelpers` in `Minitest::Test`.

---

### Appendice I — `Memory::Storage` firme metodi pubblici

Per chiudere il gap tra port astratto e adapter concreto, queste sono le firme pubbliche effect-aware che `DAG::Adapters::Memory::Storage` deve esporre.

```ruby
# lib/dag/adapters/memory/storage.rb (firme pubbliche)
class DAG::Adapters::Memory::Storage
  include DAG::Ports::Storage

  def create_workflow(id:, initial_definition:, initial_context:, runtime_profile:); end
  def load_workflow(id:); end
  def transition_workflow_state(id:, from:, to:, event: nil); end

  def append_revision(id:, parent_revision:, definition:, invalidated_node_ids:, event:); end
  def load_revision(id:, revision:); end
  def load_current_definition(id:); end

  def load_node_states(workflow_id:, revision:); end
  def transition_node_state(workflow_id:, revision:, node_id:, from:, to:); end

  def begin_attempt(workflow_id:, revision:, node_id:, expected_node_state:, attempt_number:); end
  def commit_attempt(attempt_id:, result:, node_state:, event:, effects: []); end
  def list_effects_for_node(workflow_id:, revision:, node_id:); end
  def list_effects_for_attempt(attempt_id:); end
  def claim_ready_effects(limit:, owner_id:, lease_ms:, now_ms:); end
  def mark_effect_succeeded(effect_id:, owner_id:, result:, external_ref:, now_ms:); end
  def mark_effect_failed(effect_id:, owner_id:, error:, retriable:, not_before_ms:, now_ms:); end
  def release_nodes_satisfied_by_effect(effect_id:, now_ms:); end
  def abort_running_attempts(workflow_id:); end
  def list_attempts(workflow_id:, revision: nil, node_id: nil); end
  def count_attempts(workflow_id:, revision:, node_id:); end

  def append_event(workflow_id:, event:); end
  def read_events(workflow_id:, after_seq: nil, limit: nil); end
  def prepare_workflow_retry(id:, from: :failed, to: :pending, event: nil); end
end
```

Vincoli aggiuntivi:

- ogni metodo pubblico è sincrono e completa una singola operazione logica;
- nessun metodo pubblico fa I/O, `sleep`, `Fiber.yield`, callback utente o await;
- ogni valore restituito è deep copy + deep-frozen;
- in caso di violazione di precondizione CAS, l'adapter solleva l'errore tipizzato (`StaleStateError`, `StaleRevisionError`, `UnknownWorkflowError`);
- `Memory::Storage` non è thread-safe né process-safe;
- non condividere `Memory::Storage` tra processi;
- per concorrenza reale usare `Delphic::Adapters::Sqlite::Storage` o altro adapter durable con storage transazionale.

---

### Appendice J — Release & versioning

### Appendice J — Release & versioning

Policy operativa per i repo del roadmap (`ruby-dag`, `delphic`). S0 e' una fase del repo `delphic`, non un repo obbligatorio separato.

- **Versioning:** SemVer 2.0.0. `0.x` durante lo sviluppo R0–R3 e D0–D3; `1.0.0` al traguardo di fase corrispondente.
- **Branch model:** `main` protetto. Una fase = un branch `phase/<id>` (es. `phase/r2`) → una PR squash-merge in `main`.
- **Tag:** `v<MAJOR>.<MINOR>.<PATCH>` su `main` dopo merge della PR di chiusura fase. Tag firmato (`git tag -s`).
- **Changelog:** `CHANGELOG.md` in formato [Keep a Changelog](https://keepachangelog.com/). Una sezione per release; categorie `Added / Changed / Deprecated / Removed / Fixed / Security`.
- **Comando di release:**
  ```bash
  bundle exec rake test
  bundle exec rubocop
  bundle exec rake test:storage_contract   # solo se il repo espone quel task; S0 deve comunque eseguire la suite storage
  bundle exec rake yard                    # genera doc, fallisce su warning su API pubbliche
  bundle exec rake build
  git tag -s v0.X.0 -m "Release 0.X.0 — fase <id>"
  git push --tags
  gem push pkg/<name>-0.X.0.gem            # solo per release pubbliche
  ```
- **Pre-release:** `0.X.0.rc1` su rubygems con flag `--pre`, per fasi che ne hanno bisogno.
- **Dependency security:** Dependabot/Renovate attivo solo su dev dependencies di `ruby-dag` (deve restare zero-dep runtime). Su `delphic` attivo su runtime e dev dependencies.

---

### Appendice K — Glossario

| Termine | Significato | Confine |
|---|---|---|
| **Workflow** | Un'istanza eseguibile di un DAG, con ID, stato e revisione corrente. | kernel |
| **Definition** | La forma del grafo + mapping `node_id -> step_type_ref`. Immutabile, identificata da una `revision`. | kernel |
| **Revision** | Numero progressivo della Definition di un workflow. Cambia solo per `MutationService#apply`. | kernel |
| **Node state** | Stato di un nodo *per revisione*: `pending / running / committed / waiting / failed / invalidated`. | kernel |
| **Attempt** | Tentativo di esecuzione di un nodo in una revisione. Più attempt sono ammessi per nodo; uno solo `committed`. | kernel |
| **CAS storage** | Compare-And-Swap: ogni transizione di stato è atomica e fallisce se lo stato corrente non è quello atteso. | kernel |
| **Artifact CAS** | Content-Addressed Storage: blob storage con SHA come ID. Mai usare "CAS" da solo. | delphic |
| **Step** | Funzione `StepInput -> Success | Waiting | Failure`. Frozen, idempotente per il proprio input. | kernel |
| **Mutation** | Cambiamento strutturale del DAG: `replace_subtree` o `invalidate`. Applicata solo da `MutationService`. | kernel |
| **ProposedMutation** | Mutation proposta dallo step (via `Success.proposed_mutations`), non ancora applicata. | kernel |
| **ReplacementGraph** | Sotto-DAG con entry/exit espliciti, usato in `replace_subtree`. | kernel |
| **ExecutionContext** | Dizionario CoW deep-frozen che fluisce tra nodi. JSON-safe per workflow durable. | kernel |
| **RuntimeProfile** | Config del workflow: durability, max retry per nodo, max retry workflow, event bus kind. | kernel |
| **Port** | Interface astratta per I/O: `Storage`, `EventBus`, `Fingerprint`, `Clock`, `IdGenerator`, `Serializer`. | kernel |
| **Adapter** | Implementazione concreta di un port. Memory adapter = single-process; SQLite adapter = process-safe via transazioni. | kernel |
| **Storage Contract Suite** | Set di test riusabili che ogni adapter `Storage` deve passare. | kernel + delphic S0 |
| **Skill** | Template di workflow agentico in `delphic`, mappato a una `Definition`. | delphic |
| **Tool** | Primitiva esterna (filesystem, HTTP, shell) registrata in `ToolRegistry` con `effect`. | delphic |
| **Effect** | Tassonomia dei side effect di un tool: `:pure / :idempotent_write / :destructive / :external_effect`. | delphic |
| **Ledger** | Tabella applicativa in DB delphic che traccia chiamate LLM/tool/budget per evitare doppia esecuzione su resume. | delphic |
| **Coordinator** | Super-loop applicativo che chiama `Runner`, legge eventi, applica policy, decide next action. | delphic |
| **PolicyEngine** | Decide se una mutation/tool richiede approval umana. | delphic |
| **ArtifactStore** | Storage content-addressed degli output applicativi finali. | delphic |
| **FineStreamBus** | Bus volatile per token streaming UI. Mai persistito. | delphic |
| **Side effect token** | Stringa deterministica derivata dall'input di un tool destructive, usata per dedup su resume. | delphic |

---

## 11. Prompt operativo per delegare una fase

Usare questo prompt per ogni fase assegnata a un implementatore o coding agent.

```text
Implementa solo la fase <R0/R1/R2/R3/S0/D0/D1/D2/D3> del playbook.

Regole:
- Non implementare fasi successive.
- Non cambiare decisioni architetturali senza segnalarlo.
- Ogni punto della checklist deve avere almeno un test o una motivazione esplicita se non testabile.
- Tutti i file in "Output file obbligatori" della fase devono esistere a fine fase, anche solo come stub motivati.
- Prima di terminare, esegui:
  - bundle exec rake test
  - bundle exec rubocop
  - bundle exec rake test:storage_contract       # solo se disponibile; S0 deve comunque eseguire la suite storage
  - bundle exec rake yard                        # solo prima del tag v1.0
- Aggiorna README/CONTRACT/CHANGELOG solo per la fase corrente.
- Produci un riepilogo con:
  - file creati/modificati (mapping con la lista "Output file obbligatori")
  - test aggiunti
  - comandi eseguiti
  - punti non completati o rischi residui
  - eventuali decisioni di micro-design prese in autonomia, da validare

Criterio di stop:
- Se un DoD della fase non passa, non procedere alla fase successiva.
- Se un file in "Output file obbligatori" è mancante senza motivazione esplicita, non chiudere la fase.
```

---

## 12. Gate aggiornati per `delphic`

### 12.1 Prima di aprire S0 nel repo `delphic`

Non aprire S0 finché non sono veri tutti questi punti:

```text
ruby-dag R0 green
ruby-dag R1 green
ruby-dag R2 green
ruby-dag R3 green
ruby-dag v1.0 taggata
CONTRACT.md aggiornato e stabile
README con hello world e resume example
```

Solo dopo questi punti `delphic` puo' dipendere da `ruby-dag ~> 1.0` senza inseguire contratti instabili.

### 12.2 Prima di aprire D1 agentico

Non aprire D1 finché non sono veri tutti questi punti:

```text
delphic S0 green
Delphic::Adapters::Sqlite::Storage implementa DAG::Ports::Storage
storage contract suite condivisa green su Memory e Delphic SQLite
test process-level S0 green su SQLite
delphic D0 green
DB workflow kernel (~/.delphic/workflows.sqlite3) separato dal DB applicativo (~/.delphic/state.sqlite3)
```

D0 puo' essere iniziata nello stesso repo creato da S0, ma non deve bypassare l'adapter durable locale e non deve reintrodurre una dipendenza `ruby-dag-sqlite`.

---

## Nota di revisione rispetto al documento v3.2

La v3.4 recepisce la decisione architetturale di rimuovere completamente Ractor e di usare solo processi o fiber per la concorrenza.

Cambiamenti principali v3.2 → v3.4:

- **Ractor rimossi ovunque**: nessun `Ractor.new`, nessun actor Ractor per Memory adapter, nessun test Ractor.
- **Kernel sequenziale**: `ruby-dag` resta puro e deterministico; non crea concorrenza e non genera processi.
- **Memory adapter single-process**: `Memory::Storage` e `Memory::EventBus` sono adapter stateful per test/REPL, non backend process-safe.
- **Concorrenza reale in S0**: i test process-level usano `Delphic::Adapters::Sqlite::Storage`; ogni processo apre una propria connessione SQLite e il CAS è garantito dalle transazioni.
- **Fiber in `delphic`**: orchestration, streaming e I/O concorrente usano `async`; niente Thread e niente Ractor nel layer agentico.
- **Processi come boundary esplicito**: ammessi per test process-level, worker o tool esterni, ma vietati nel runtime `lib/dag/**`.
- **Cop aggiornati**: `NoOSConcurrency` diventa `NoThreadOrRactor`, con regole separate per runtime kernel, test SQLite e boundary processuali di `delphic`.
- **Appendici aggiornate**: rimossi `storage_actor.rb` / `event_bus_actor.rb`; aggiunti esempi Memory single-process e test SQLite con `Process.fork`.

Le decisioni v3.2 che restano valide:

- ordine esecutivo R0 → R1 → R2 → R3 → `ruby-dag` v1.0 → S0 nel repo `delphic` → D0 → D1 → D2 → D3 → D4 post-v1.0;
- adapter SQLite S0 obbligatorio prima di D1, ma implementato dentro `delphic`, non come gemma obbligatoria separata;
- storage applicativo `delphic` separato dallo storage kernel;
- retry a due livelli: `max_attempts_per_node` + `max_workflow_retries`;
- `Data.define` + `deep_freeze`/`deep_dup`/`json_safe!`;
- `MutationService` come unico punto con side effect strutturali;
- ledger/cache anche per chiamate LLM, non solo per tool;
- `replace_subtree` formalizzato per DAG con `ReplacementGraph` esplicito.
