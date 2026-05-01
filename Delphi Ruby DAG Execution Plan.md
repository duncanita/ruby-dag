# DELPHI & RUBY-DAG — Master Execution Plan v2.1 Final

**Versione:** `2.1-final`
**Architettura:** Option B+ / Effect-Aware Kernel / Durable Execution Model
**Repository Core:** `ruby-dag` — kernel astratto, protocollo effetti, contratti di storage
**Repository Host:** `nexus` — nome logico progetto: `Delphi`, branch operativo: `delphi-v1`
**Obiettivo:** costruire un Agent Workflow System robusto, modulare, idempotente e replay-safe, usando DAG, monadi, architettura esagonale, strutture dati immutabili e un bilanciamento pragmatico tra OOP e FP.

---

## 0. Direttiva primaria per agenti AI

Questo documento è la direttiva operativa autoritativa per ogni agente AI che lavora su `ruby-dag` o `nexus/Delphi`.

Ogni agente deve rispettare queste regole:

1. **Non generare codice legacy.** Vietati `require "dag"`, vecchie API `DAG::Workflow::*` non più compatibili, nomi `Delphic/delphic`, registry legacy o wrapper inventati intorno all’API reale.
2. **Non introdurre dipendenze runtime in `ruby-dag`.** Il core resta zero-dependency.
3. **Non eseguire I/O dentro gli step.** Uno step non chiama API esterne, non scrive file, non invia email, non chiama LLM, non fa HTTP, non interroga DB applicativi.
4. **Ogni side-effect deve essere descritto come intent astratto.** Lo step produce `DAG::Effects::Intent`; il kernel lo registra in modo atomico; Delphi lo esegue fisicamente tramite handler.
5. **La semantica pubblica non è “exactly-once external execution”.** La promessa corretta è:

   ```text
   exactly-once durable effect intent reservation
   + at-most-once successful effect recording per (type, key)
   + lease-protected dispatch
   + effectively-once external side effects through host handlers
   ```

6. **Ogni modifica deve essere verificabile con test.** Gli agenti devono accompagnare ogni PR con contract test, unit test e, dove serve, test di crash/race simulati.

---

## 1. Principio architetturale: Option B+

Option B+ rende `ruby-dag` **effect-aware**, ma non **adapter-aware**.

Il kernel conosce il protocollo astratto degli effetti. Non conosce i sistemi esterni.

| Dominio | Responsabilità |
|---|---|
| `ruby-dag` | Topologia DAG, workflow state machine, attempt lifecycle, durable effect intents, idempotency key, payload fingerprint, effect ledger, lease astratti, CAS, eventi, retry/replay deterministico. |
| Delphi / `nexus` | Handler concreti, chiamate fisiche, LLM, HTTP, GitHub, email, auth, budget, rate-limit, reconciliation, worker loop, observability applicativa. |
| Adapter storage | Persistenza concreta del contratto kernel: Memory per test upstream; SQLite in Delphi S0; eventuali adapter futuri. |

### Regola d’oro

Uno step DAG è una funzione replay-safe:

```text
StepInput -> DAG::Success | DAG::Waiting | DAG::Failure
```

Se lo step ha bisogno del mondo esterno, non esegue il lavoro. Restituisce un intent:

```ruby
DAG::Waiting[
  reason: :effect_pending,
  proposed_effects: [intent]
]
```

Quando l’effetto è risolto, lo step viene rieseguito con uno snapshot deterministico in `input.metadata[:effects]`. Non è una coroutine; è una riesecuzione pura guidata dallo stato durabile.

---

## 2. Semantica di idempotenza e side-effect safety

### 2.1 Cosa garantisce il kernel

`ruby-dag` deve garantire:

1. **Intent durabile registrato una volta sola** per `(type, key)`.
2. **Payload fingerprint stabile.** Stesso `(type, key)` con payload diverso genera `DAG::Effects::IdempotencyConflictError`.
3. **Commit atomico.** `commit_attempt` salva insieme attempt result, node state, durable event, effect records e link attempt-effect.
4. **Lease atomico.** Un solo dispatcher può possedere un effetto in `dispatching` alla volta.
5. **Terminalità.** `succeeded` e `failed_terminal` sono stati terminali.
6. **Retry sicuro.** Il retry del workflow non duplica intent già registrati e non duplica effetti già riusciti.
7. **Replay deterministico.** Lo stesso workflow state produce lo stesso `StepInput`, incluso lo snapshot effetti.
8. **Release deterministica dei nodi waiting.** Un nodo waiting torna `pending` solo quando tutti i suoi blocking effects sono terminali: `succeeded` o `failed_terminal`.

### 2.2 Cosa non può garantire il kernel

Il kernel non può garantire che un sistema esterno esegua fisicamente una richiesta una sola volta.

Scenario impossibile da risolvere solo localmente:

```text
1. Dispatcher chiama sistema esterno.
2. Il sistema esterno esegue il side-effect.
3. Il processo crasha prima di salvare mark_effect_succeeded.
4. Il lease scade.
5. Un altro dispatcher reclama l’effetto.
```

Per questo Delphi deve implementare handler con:

- remote idempotency key quando supportata;
- external reference lookup;
- reconciliation;
- retry/backoff;
- distinzione tra errori retriable e terminali.

La promessa finale è **effectively-once**, non exactly-once assoluto verso l’esterno.

---

## 3. Protocollo effetti in `ruby-dag`

### 3.1 Namespace

Aggiungere:

```text
lib/dag/effects.rb
lib/dag/effects/intent.rb
lib/dag/effects/prepared_intent.rb
lib/dag/effects/record.rb
lib/dag/effects/await.rb
lib/dag/effects/dispatcher.rb
lib/dag/effects/handler_result.rb
lib/dag/errors/effects.rb
```

Aggiornare `lib/ruby-dag.rb` affinché carichi il nuovo namespace senza introdurre dipendenze esterne.

---

### 3.2 `DAG::Effects::Intent`

Un intent è la descrizione pura di un effetto esterno.

```ruby
module DAG
  module Effects
    Intent = Data.define(:type, :key, :payload, :metadata) do
      class << self
        remove_method :[]

        def [](type:, key:, payload: {}, metadata: {})
          new(type: type, key: key, payload: payload, metadata: metadata)
        end
      end

      def initialize(type:, key:, payload: {}, metadata: {})
        raise ArgumentError, "type must be String" unless type.is_a?(String)
        raise ArgumentError, "key must be String" unless key.is_a?(String)
        DAG.json_safe!(payload, "$root.payload")
        DAG.json_safe!(metadata, "$root.metadata")

        super(
          type: type.freeze,
          key: key.freeze,
          payload: DAG.deep_freeze(DAG.deep_dup(payload)),
          metadata: DAG.deep_freeze(DAG.deep_dup(metadata))
        )
      end

      def ref
        "#{type}:#{key}"
      end
    end
  end
end
```

#### Regole

```text
(type, key) = identity semantica dell’effetto
payload_fingerprint = guardia contro collisioni o nondeterminismo
metadata = opaca, JSON-safe, non usata per identity
```

La `key` non deve includere `attempt_number`, salvo casi espliciti in cui si vuole un effetto diverso per ogni tentativo.

Per effetti semantici normali, usare:

```text
namespace
workflow_id
revision
node_id
semantic_effect_name
semantic_input_fingerprint
```

Esempio:

```text
delphi:v1:wf:<workflow_id>:rev:<revision>:node:<node_id>:planner:<prompt_fingerprint>
```

---

### 3.3 `DAG::Effects::PreparedIntent`

`PreparedIntent` è la forma kernel-enriched dell’intent prima del commit.

Campi:

```text
ref
workflow_id
revision
node_id
attempt_id
type
key
payload
payload_fingerprint
blocking
created_at_ms
metadata
```

Regole:

- `blocking: true` per effetti proposti da `DAG::Waiting`.
- `blocking: false` per effetti detached proposti da `DAG::Success`.
- Il fingerprint viene calcolato dal port `fingerprint` del runner, non dallo step.
- Il record deve essere JSON-safe e deep-frozen.

---

### 3.4 `DAG::Effects::Record`

`Record` rappresenta lo stato durabile dell’effetto nel ledger kernel.

Campi minimi:

```text
id
ref
workflow_id
revision
node_id
attempt_id
type
key
payload
payload_fingerprint
blocking
status
result
error
external_ref
not_before_ms
lease_owner
lease_until_ms
created_at_ms
updated_at_ms
metadata
```

Stati:

```ruby
EFFECT_STATES = %i[
  reserved
  dispatching
  succeeded
  failed_retriable
  failed_terminal
].freeze
```

Semantica:

| Stato | Significato | Terminale |
|---|---|---|
| `reserved` | Intent durabilmente registrato, non ancora reclamato. | No |
| `dispatching` | Un dispatcher ha acquisito lease e sta eseguendo l’effetto. | No |
| `succeeded` | Effetto completato con risultato durabile. | Sì |
| `failed_retriable` | Errore temporaneo; reclamabile dopo `not_before_ms`. | No |
| `failed_terminal` | Errore definitivo; lo step verrà rieseguito e mapperà a `Failure`. | Sì |

---

### 3.5 Estensione `DAG::Success`

Aggiungere `proposed_effects`:

```ruby
Success = Data.define(
  :value,
  :context_patch,
  :proposed_mutations,
  :proposed_effects,
  :metadata
)
```

Semantica:

```text
Success + proposed_effects = detached effects
```

Il nodo può essere `committed`; gli effetti vengono registrati e dispatchati, ma non bloccano il completamento del nodo.

Usare con cautela per:

- notifiche;
- audit asincroni;
- metriche;
- webhook non bloccanti.

Non usare per LLM/tool call necessarie a calcolare il risultato dello step.

---

### 3.6 Estensione `DAG::Waiting`

Aggiungere `proposed_effects`:

```ruby
Waiting = Data.define(
  :reason,
  :resume_token,
  :not_before_ms,
  :proposed_effects,
  :metadata
)
```

Semantica:

```text
Waiting + proposed_effects = blocking effects
```

Il nodo resta `waiting`. Il workflow può andare `waiting` se non ci sono altri nodi eleggibili.

Quando tutti i blocking effects del nodo sono terminali, il nodo torna `pending` e il runner può rieseguire lo step.

---

### 3.7 `DAG::Effects::Await`

Helper monadico per step puri.

Contratto:

```ruby
DAG::Effects::Await.call(input, intent, not_before_ms: nil) do |result|
  # pure continuation
end
```

Comportamento:

```text
if input.metadata[:effects][intent.ref].status == :succeeded
  yield(result)
elsif status == :failed_terminal
  DAG::Failure[error: record.error, retriable: false]
elsif status == :failed_retriable
  DAG::Waiting[reason: :effect_pending, proposed_effects: [intent], not_before_ms: record.not_before_ms]
else
  DAG::Waiting[reason: :effect_pending, proposed_effects: [intent], not_before_ms: not_before_ms]
end
```

Implementazione indicativa:

```ruby
module DAG
  module Effects
    module Await
      module_function

      def call(input, intent, not_before_ms: nil)
        effects = input.metadata.fetch(:effects, {})
        record = effects[intent.ref]

        case record && record[:status]&.to_sym
        when :succeeded
          yield(record.fetch(:result))
        when :failed_terminal
          DAG::Failure[
            error: record.fetch(:error),
            retriable: false,
            metadata: { effect_ref: intent.ref }
          ]
        when :failed_retriable
          DAG::Waiting[
            reason: :effect_pending,
            resume_token: { effects: [intent.ref] },
            not_before_ms: record[:not_before_ms] || not_before_ms,
            proposed_effects: [intent],
            metadata: { effect_ref: intent.ref }
          ]
        else
          DAG::Waiting[
            reason: :effect_pending,
            resume_token: { effects: [intent.ref] },
            not_before_ms: not_before_ms,
            proposed_effects: [intent],
            metadata: { effect_ref: intent.ref }
          ]
        end
      end
    end
  end
end
```

---

## 4. Upstream `ruby-dag`: sequenza PR obbligatoria

Gli agenti devono lavorare in PR piccole e verificabili. Non saltare direttamente a SQLite o Delphi prima di completare il protocollo upstream.

---

### PR 0 — Kernel safety pre-effect

Prima degli effetti, rafforzare il kernel esistente.

Task:

1. Rendere `Runner#retry_workflow` atomico rispetto a:
   - reset nodi failed;
   - abort attempt failed;
   - incremento retry count;
   - transizione workflow `failed -> pending`.
2. Introdurre un unico metodo storage, per esempio:

   ```ruby
   storage.prepare_workflow_retry_and_transition(id:, from:, to:, event: nil)
   ```

   oppure estendere `prepare_workflow_retry` affinché includa la transizione.

3. Rendere `effective_context` deterministico:
   - ordinare gli attempt per `attempt_number` o sequenza commit;
   - usare un criterio esplicito per scegliere il committed attempt corrente;
   - aggiungere test che randomizzano l’ordine ritornato da storage.

DoD:

```text
- Retry concorrenti non duplicano retry_count.
- Crash tra reset e transizione non può lasciare stato parziale.
- effective_context è identico anche se list_attempts ritorna ordine diverso.
- bundle exec rake passa.
```

---

### PR 1 — Contract, value objects, errors

Task:

1. Aggiornare `CONTRACT.md` con la nuova semantica effect-aware.
2. Aggiungere errori:

   ```ruby
   DAG::Effects::IdempotencyConflictError
   DAG::Effects::StaleLeaseError
   DAG::Effects::UnknownEffectError
   DAG::Effects::UnknownHandlerError
   ```

3. Aggiungere:
   - `DAG::Effects::Intent`;
   - `DAG::Effects::PreparedIntent`;
   - `DAG::Effects::Record`;
   - `DAG::Effects::HandlerResult`;
   - `DAG::Effects::Await`.

4. Estendere:
   - `DAG::Success` con `proposed_effects`;
   - `DAG::Waiting` con `proposed_effects`;
   - `DAG::StepProtocol.valid_result?` se necessario.

DoD:

```text
- Tutti i value object sono deep-frozen.
- Tutti i payload sono JSON-safe.
- proposed_effects accetta solo DAG::Effects::Intent.
- Backward compatibility: Success[...] e Waiting[...] senza proposed_effects continuano a funzionare.
```

---

### PR 2 — Storage port e Memory adapter

Estendere il port storage.

Nuova firma:

```ruby
commit_attempt(
  attempt_id:,
  result:,
  node_state:,
  event:,
  effects: []
)
```

Aggiungere metodi effect-aware:

```ruby
list_effects_for_node(workflow_id:, revision:, node_id:)
list_effects_for_attempt(attempt_id:)
claim_ready_effects(limit:, owner_id:, lease_ms:, now_ms:)
mark_effect_succeeded(effect_id:, owner_id:, result:, external_ref:, now_ms:)
mark_effect_failed(effect_id:, owner_id:, error:, retriable:, not_before_ms:, now_ms:)
release_nodes_satisfied_by_effect(effect_id:, now_ms:)
```

Regole storage:

```text
- commit_attempt è one-shot.
- commit_attempt + effects è una singola transazione logica.
- reserve su (type, key) è idempotente.
- stesso (type, key) + payload_fingerprint diverso = IdempotencyConflictError.
- claim_ready_effects assegna lease in modo atomico.
- mark_* richiede lease_owner corretto.
- succeeded/failed_terminal sono terminali.
```

DoD:

```text
- Memory::Storage implementa tutto.
- Contract test comuni per Memory e futuri adapter.
- Due claim concorrenti non ottengono lo stesso effetto.
- Effetto già succeeded viene riusato da un nuovo attempt.
```

---

### PR 3 — Runner integration

Task:

1. `Runner#build_step_input` deve includere:

   ```ruby
   metadata: {
     workflow_id: run.workflow_id,
     revision: run.revision,
     effects: effects_snapshot_for(run, node_id)
   }
   ```

2. `Runner#commit_and_emit` deve:
   - estrarre `result.proposed_effects`;
   - trasformarli in `PreparedIntent`;
   - calcolare `payload_fingerprint` via port `fingerprint`;
   - passare `effects:` a `storage.commit_attempt`.

3. Event payload per `:node_waiting` deve includere:

   ```ruby
   {
     reason: result.reason,
     not_before_ms: result.not_before_ms,
     effect_refs: prepared_effects.map(&:ref),
     effect_count: prepared_effects.size
   }
   ```

4. Workflow waiting rimane determinato dal modello attuale:
   - se non ci sono nodi eleggibili;
   - e almeno un nodo è `waiting`;
   - allora workflow `running -> waiting`.

DoD:

```text
- Primo giro: step ritorna Waiting + proposed_effects; effect record viene creato atomicamente.
- Resume senza effetto terminale non riesegue indebitamente il nodo.
- Dopo succeeded, release node -> pending, resume riesegue step con metadata[:effects].
- Lo step non vede effetti di altri nodi non collegati.
```

---

### PR 4 — Dispatcher astratto e handler contract

Separare tre concetti:

| Oggetto | Dove vive | Responsabilità |
|---|---|---|
| `EffectStore` | Storage port | Persistenza, claim, lease, mark, release. |
| `DAG::Effects::Dispatcher` | `ruby-dag` | Orchestrazione astratta claim -> handler -> mark. |
| Handler concreti | Delphi | Chiamate fisiche e policy applicative. |

Handler contract:

```ruby
class SomeHandler
  def call(record)
    # returns DAG::Effects::HandlerResult
  end
end
```

`HandlerResult`:

```ruby
DAG::Effects::HandlerResult.succeeded(result:, external_ref: nil)
DAG::Effects::HandlerResult.failed(error:, retriable:, not_before_ms: nil)
```

Dispatcher indicativo:

```ruby
DAG::Effects::Dispatcher.new(
  store: storage,
  handlers: handler_registry,
  clock: clock,
  owner_id: owner_id,
  lease_ms: 30_000
).tick(limit: 10)
```

DoD:

```text
- Unknown handler -> failed_terminal o failed_retriable secondo policy configurabile.
- Handler exception -> failed_retriable di default, con error JSON-safe.
- mark_effect_succeeded richiede lease valido.
- release_nodes_satisfied_by_effect ritorna workflow_id/node_id rilasciati.
- Dispatcher non conosce HTTP, LLM, GitHub, email o auth.
```

---

### PR 5 — Documentazione, release gate e pinning

Task:

1. Aggiornare:
   - `README.md`;
   - `CONTRACT.md`;
   - `ROADMAP.md`;
   - eventuali doc in `docs/plans/**`.

2. Aggiungere esempi:
   - awaited LLM-like effect astratto;
   - detached notification effect;
   - failed retriable con backoff;
   - failed terminal.

3. Gate:

   ```bash
   bundle exec rake
   scripts/production_readiness.rb --fast
   ```

4. Dopo merge:
   - creare tag upstream se il gate è chiuso;
   - altrimenti usare commit pin esplicito in Delphi.

Regola di pinning:

```text
Durante sviluppo coordinato: path locale o branch feature esplicito.
Dopo merge upstream: commit SHA pin o tag.
Mai dipendere da main in modo non pinnato per esecuzione stabile.
```

---

## 5. Delphi S0: SQLite adapter effect-aware

Quando il protocollo upstream è implementato, passare a `nexus` branch `delphi-v1`.

S0 implementa uno storage SQLite unico per workflow, attempts, events ed effects.

---

### 5.1 Pulizia iniziale

Task:

```text
- Rimuovere nomenclatura delphic/Delphic.
- Rimuovere require "dag".
- Usare require "ruby-dag".
- Eliminare wrapper legacy intorno a Registry.
- Usare DAG::StepTypeRegistry.
- Aggiornare Gemfile con path/ref/tag esplicito a ruby-dag effect-aware.
- Aggiornare Gemfile.lock.
```

Grep gate:

```bash
! grep -R "require ['\"]dag['\"]" lib spec
! grep -R "Delphic\|delphic" lib spec
! grep -R "DAG::Workflow::Step\|DAG::Workflow::Registry" lib spec
```

---

### 5.2 Schema SQLite V1

Schema minimo richiesto.

```sql
CREATE TABLE dag_workflows (
  id TEXT PRIMARY KEY,
  state TEXT NOT NULL,
  current_revision INTEGER NOT NULL,
  workflow_retry_count INTEGER NOT NULL DEFAULT 0,
  runtime_profile_json TEXT NOT NULL,
  initial_context_json TEXT NOT NULL,
  waiting_not_before_ms INTEGER,
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL
);

CREATE INDEX idx_dag_workflows_state_waiting
  ON dag_workflows(state, waiting_not_before_ms);

CREATE TABLE dag_revisions (
  workflow_id TEXT NOT NULL,
  revision INTEGER NOT NULL,
  definition_json TEXT NOT NULL,
  created_at_ms INTEGER NOT NULL,
  PRIMARY KEY (workflow_id, revision),
  FOREIGN KEY (workflow_id) REFERENCES dag_workflows(id)
);

CREATE TABLE dag_node_states (
  workflow_id TEXT NOT NULL,
  revision INTEGER NOT NULL,
  node_id TEXT NOT NULL,
  state TEXT NOT NULL,
  updated_at_ms INTEGER NOT NULL,
  PRIMARY KEY (workflow_id, revision, node_id),
  FOREIGN KEY (workflow_id, revision) REFERENCES dag_revisions(workflow_id, revision)
);

CREATE INDEX idx_dag_node_states_workflow_state
  ON dag_node_states(workflow_id, revision, state);

CREATE TABLE dag_attempts (
  id TEXT PRIMARY KEY,
  workflow_id TEXT NOT NULL,
  revision INTEGER NOT NULL,
  node_id TEXT NOT NULL,
  attempt_number INTEGER NOT NULL,
  state TEXT NOT NULL,
  result_json TEXT,
  started_at_ms INTEGER NOT NULL,
  completed_at_ms INTEGER,
  UNIQUE(workflow_id, revision, node_id, attempt_number),
  FOREIGN KEY (workflow_id, revision) REFERENCES dag_revisions(workflow_id, revision)
);

CREATE INDEX idx_dag_attempts_node
  ON dag_attempts(workflow_id, revision, node_id, attempt_number);

CREATE TABLE dag_events (
  workflow_id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  type TEXT NOT NULL,
  revision INTEGER NOT NULL,
  node_id TEXT,
  attempt_id TEXT,
  at_ms INTEGER NOT NULL,
  payload_json TEXT NOT NULL,
  PRIMARY KEY (workflow_id, seq),
  FOREIGN KEY (workflow_id) REFERENCES dag_workflows(id)
);

CREATE TABLE dag_effects (
  id TEXT PRIMARY KEY,
  ref TEXT NOT NULL,
  workflow_id TEXT NOT NULL,
  revision INTEGER NOT NULL,
  node_id TEXT NOT NULL,
  attempt_id TEXT NOT NULL,
  type TEXT NOT NULL,
  key TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  payload_fingerprint TEXT NOT NULL,
  blocking INTEGER NOT NULL,
  status TEXT NOT NULL,
  result_json TEXT,
  error_json TEXT,
  external_ref TEXT,
  not_before_ms INTEGER,
  lease_owner TEXT,
  lease_until_ms INTEGER,
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL,
  metadata_json TEXT NOT NULL,
  UNIQUE(type, key),
  FOREIGN KEY (workflow_id, revision) REFERENCES dag_revisions(workflow_id, revision),
  FOREIGN KEY (attempt_id) REFERENCES dag_attempts(id)
);

CREATE INDEX idx_dag_effects_ready
  ON dag_effects(status, not_before_ms, lease_until_ms);

CREATE INDEX idx_dag_effects_node
  ON dag_effects(workflow_id, revision, node_id, blocking, status);

CREATE TABLE dag_attempt_effects (
  attempt_id TEXT NOT NULL,
  effect_id TEXT NOT NULL,
  blocking INTEGER NOT NULL,
  created_at_ms INTEGER NOT NULL,
  PRIMARY KEY (attempt_id, effect_id),
  FOREIGN KEY (attempt_id) REFERENCES dag_attempts(id),
  FOREIGN KEY (effect_id) REFERENCES dag_effects(id)
);
```

---

### 5.3 Transazioni obbligatorie

Ogni operazione CAS o multi-row deve usare transazione SQLite.

Per `commit_attempt`:

```sql
BEGIN IMMEDIATE;
-- verify attempt state = running
-- update attempt to committed/waiting/failed
-- update node state
-- reserve or link effects
-- append event with next seq
COMMIT;
```

Se `(type, key)` esiste:

```text
same payload_fingerprint -> riusa/linka record esistente
payload_fingerprint diverso -> IdempotencyConflictError + rollback
```

Per `claim_ready_effects`:

```sql
BEGIN IMMEDIATE;
-- select reserved/failed_retriable/expired-dispatching records eligible by not_before_ms
-- update lease_owner, lease_until_ms, status = dispatching
COMMIT;
```

Per `mark_effect_succeeded`:

```text
CAS: effect_id + status dispatching + lease_owner valido + lease_until_ms >= now_ms
then status = succeeded, result_json, external_ref, clear lease
```

Per `mark_effect_failed`:

```text
if retriable:
  status = failed_retriable, error_json, not_before_ms, clear lease
else:
  status = failed_terminal, error_json, clear lease
```

---

## 6. Delphi D1.5: dispatcher e handler concreti

Delphi non crea un ledger applicativo separato. Usa `DAG::Effects`.

### 6.1 Dispatcher worker loop

Responsabilità Delphi:

```text
- creare owner_id stabile per processo;
- chiamare dispatcher.tick(limit: N);
- gestire sleep/backoff del worker;
- chiamare Runner#resume sui workflow rilasciati;
- esportare metriche/log/tracing;
- arrestarsi in modo pulito su signal.
```

Flusso:

```text
claim_ready_effects
↓
lookup handler by effect.type
↓
handler.call(record)
↓
mark_effect_succeeded / mark_effect_failed
↓
release_nodes_satisfied_by_effect
↓
Runner#resume(workflow_id) per workflow rilasciati
```

Nota: `release_nodes_satisfied_by_effect` non deve completare lo step. Deve solo rendere il nodo di nuovo `pending`. Sarà il runner a rieseguire lo step; `DAG::Effects::Await` mapperà lo snapshot a `Success` o `Failure`.

---

### 6.2 Handler concreti Delphi

Directory:

```text
lib/delphi/effects/handlers/llm_chat_completion.rb
lib/delphi/effects/handlers/http_request.rb
lib/delphi/effects/handlers/github_create_issue.rb
lib/delphi/effects/handlers/email_delivery.rb
lib/delphi/effects/handlers/human_approval.rb
lib/delphi/effects/policies/budget_policy.rb
lib/delphi/effects/policies/rate_limit_policy.rb
lib/delphi/effects/reconciliation/*.rb
```

Regole:

1. Handler riceve `DAG::Effects::Record`.
2. Handler non modifica direttamente workflow, node state o attempt state.
3. Handler passa `record.key` come idempotency key remota quando il provider la supporta.
4. Handler salva `external_ref` quando disponibile.
5. Handler ritorna solo `DAG::Effects::HandlerResult`.
6. Handler distingue errori retriable e terminali.
7. Handler non deve generare nuovi effect intent; se servono effetti composti, il workflow deve modellarlo con nodi DAG separati.

---

### 6.3 Failure taxonomy

| Caso | HandlerResult | Note |
|---|---|---|
| Timeout rete | `failed(retriable: true, not_before_ms:)` | Backoff host policy. |
| Rate limit | `failed(retriable: true, not_before_ms:)` | Usare reset time se disponibile. |
| Auth mancante | `failed(retriable: false)` | Terminale fino a nuova configurazione. |
| Payload invalido | `failed(retriable: false)` | Bug o input non valido. |
| Provider ha già eseguito effetto | `succeeded(result:, external_ref:)` | Via reconciliation. |
| Crash dopo chiamata esterna | Lease scade; nuovo handler deve riconciliare | Non duplicare se possibile. |

---

## 7. Pattern obbligatorio per step Delphi

Gli step Delphi devono essere puri, replay-safe e privi di I/O.

Esempio corretto:

```ruby
class Delphi::Steps::PlannerStep < DAG::Step::Base
  def call(input)
    prompt = build_prompt(input)
    prompt_fingerprint = Delphi::PureFingerprint.call(prompt)

    intent = DAG::Effects::Intent[
      type: "delphi.llm.chat_completion",
      key: [
        "delphi:v1",
        "wf:#{input.metadata.fetch(:workflow_id)}",
        "rev:#{input.metadata.fetch(:revision)}",
        "node:#{input.node_id}",
        "planner",
        "prompt:#{prompt_fingerprint}"
      ].join(":"),
      payload: {
        model: config.fetch(:model),
        messages: prompt,
        temperature: config.fetch(:temperature, 0.2)
      },
      metadata: {
        semantic_name: "planner",
        prompt_fingerprint: prompt_fingerprint
      }
    ]

    DAG::Effects::Await.call(input, intent) do |result|
      DAG::Success[
        value: result,
        context_patch: {
          "last_plan" => result.fetch("content")
        },
        proposed_mutations: parse_mutations(result)
      ]
    end
  end

  private

  def build_prompt(input)
    # Pure function only. No network, no files, no DB.
  end

  def parse_mutations(result)
    # Pure parser returning DAG::ProposedMutation objects.
  end
end
```

Vietato:

```ruby
client.chat(...)
Net::HTTP.get(...)
File.write(...)
DB.insert(...)
Mailer.deliver(...)
```

Consentito:

```ruby
DAG::Effects::Intent[...]
DAG::Effects::Await.call(...)
DAG::Success[...]
DAG::Waiting[...]
DAG::Failure[...]
```

---

## 8. Test obbligatori

### 8.1 Upstream `ruby-dag`

```text
- Intent è deep-frozen e JSON-safe.
- Intent#ref è deterministico.
- Success e Waiting sono backward compatible.
- proposed_effects accetta solo Intent.
- Await ritorna Waiting quando lo snapshot effetto è assente.
- Await yielda quando effetto è succeeded.
- Await ritorna Failure quando effetto è failed_terminal.
- commit_attempt salva attempt, node state, event ed effects atomicamente.
- Stesso (type, key) + stesso fingerprint è idempotente.
- Stesso (type, key) + fingerprint diverso solleva IdempotencyConflictError.
- Due dispatcher concorrenti non reclamano lo stesso effetto.
- Lease scaduto rende effetto reclamabile.
- mark_effect_succeeded con lease sbagliato fallisce.
- succeeded è terminale.
- failed_terminal è terminale.
- release_nodes_satisfied_by_effect non rilascia nodo con altri blocking effects pendenti.
- Retry workflow non duplica effetti già succeeded.
- Resume dopo crash non riesegue nodi committed.
```

### 8.2 Delphi SQLite

```text
- Migrazione schema V1 crea tutte le tabelle e indici.
- BEGIN IMMEDIATE protegge commit_attempt.
- Event seq è monotono per workflow.
- UNIQUE(type, key) è rispettato.
- payload_fingerprint conflict fa rollback.
- claim_ready_effects è atomico tra processi simulati.
- mark_effect_failed retriable rispetta not_before_ms.
- release node waiting -> pending solo quando tutti gli effects sono terminali.
- Runner#resume completa lo step dopo effet succeeded.
```

### 8.3 Delphi handlers

```text
- Nessuno step chiama handler direttamente.
- Handler riceve solo Record.
- Handler ritorna solo HandlerResult.
- Handler passa idempotency key remota quando supportata.
- Handler salva external_ref quando disponibile.
- Crash dopo chiamata esterna e prima di mark succeeded è coperto da reconciliation test.
- Errori rate-limit diventano failed_retriable.
- Errori payload/auth diventano failed_terminal.
```

---

## 9. Gating e qualità

### 9.1 Comandi upstream

```bash
bundle install
bundle exec rake
scripts/production_readiness.rb --fast
```

### 9.2 Comandi Delphi

```bash
bundle install
bundle exec rake
```

Grep obbligatori:

```bash
! grep -R "require ['\"]dag['\"]" lib spec
! grep -R "Delphic\|delphic" lib spec
! grep -R "Net::HTTP\|Faraday\|HTTParty\|OpenAI\|Github\|Mail" lib/delphi/steps spec/delphi/steps
```

La presenza di client esterni è ammessa solo sotto:

```text
lib/delphi/effects/handlers/**
lib/delphi/adapters/**
```

---

## 10. Ordine operativo per oggi

Eseguire in questo ordine.

### Blocco A — Upstream kernel

```text
1. Creare branch ruby-dag: feature/effects-option-b.
2. Implementare PR 0: retry atomico + effective_context deterministico.
3. Implementare PR 1: Effects value objects + Success/Waiting extension + Await.
4. Implementare PR 2: Storage port + Memory adapter + contract tests.
5. Implementare PR 3: Runner integration.
6. Implementare PR 4: Dispatcher astratto.
7. Aggiornare CONTRACT/README/ROADMAP.
8. Eseguire bundle exec rake + production_readiness --fast.
```

### Blocco B — Delphi S0

```text
1. Creare branch nexus: delphi-v1.
2. Puntare Gemfile a ruby-dag effect-aware con path/ref/tag esplicito.
3. Pulire legacy Delphic/delphic e require legacy.
4. Implementare SQLite schema V1 effect-aware.
5. Implementare storage port completo.
6. Eseguire contract tests condivisi contro SQLite.
```

### Blocco C — Delphi D1.5

```text
1. Implementare dispatcher worker loop.
2. Implementare handler registry.
3. Implementare LlmChatCompletion come primo handler.
4. Implementare step PlannerStep con DAG::Effects::Await.
5. Testare flow end-to-end: pending -> waiting -> effect succeeded -> pending -> completed.
```

---

## 11. Anti-pattern espliciti

Non implementare:

```text
- Ledger separato tool_invocations per duplicare DAG::Effects.
- Chiamate LLM dentro Step#call.
- HTTP/email/GitHub dentro Step#call.
- Retry applicativi dentro lo step.
- Idempotency key basate su timestamp casuali.
- Idempotency key basate su attempt_number per effetti semantici.
- Dipendenza non pinnata da branch main in produzione.
- Adapter concreti OpenAI/GitHub/email dentro ruby-dag.
- Transizioni node/workflow fuori dal port storage.
- Dispatcher che completa direttamente lo step senza passare dal runner.
```

---

## 12. Definizione finale di successo

Il piano è completato quando:

```text
- ruby-dag espone un protocollo effetti astratto, zero-dependency e testato.
- commit_attempt è il boundary atomico per attempt + node + event + effects.
- Delphi SQLite implementa il port effect-aware con transazioni ACID.
- Gli step Delphi sono puri e privi di I/O.
- Gli handler Delphi sono gli unici punti dove avvengono chiamate esterne.
- Retry e resume non duplicano effetti già registrati o riusciti.
- Il sistema supporta crash recovery tra ogni boundary rilevante.
- La semantica pubblica è effectively-once, non exactly-once esterno assoluto.
```

---

## 13. Formula architetturale finale

```text
ruby-dag = deterministic DAG kernel
         + durable abstract effect protocol
         + atomic intent reservation
         + lease-protected dispatch contract

Delphi   = host application
         + concrete effect handlers
         + policy/reconciliation/budget/auth
         + agent workflow semantics
```

La forma corretta non è:

```text
Delphi possiede un ledger sopra ruby-dag.
```

La forma corretta è:

```text
ruby-dag possiede il protocollo astratto degli effetti;
Delphi specializza quel protocollo con handler, policy e reconciliation.
```
