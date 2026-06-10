# ruby-dag v1.1: Manifesto Architetturale e Redesign dello Storage

> *L'architettura non è come vendi il codice nei README, è come il codice fallisce in produzione alle tre di notte.*

Incrociando l'analisi statica e leggendo i byte, emerge una verità innegabile: le fondamenta di `ruby-dag` sono ottime. Aver isolato lo stato mutabile e aver garantito il determinismo bit-a-bit con test di fuzzing dimostra che il kernel è stato pensato per sopravvivere ai crash. 

Tuttavia, per scalare verso veri database relazionali (fase S0 - SQLite/PostgreSQL), il progetto deve affrontare due problemi strutturali:
1. **Un lessico interno fuorviante:** nomi (Monadi, CoW) usati in modo impreciso che confondono il modello mentale.
2. **Un design dello Storage Port "difensivo" e imperativo:** il kernel fa da babysitter allo storage, rendendo l'interfaccia immensa (26 metodi) e costringendo l'orchestratore a gestire i conflitti di concorrenza tramite eccezioni procedurali e micromanagement.

La roadmap per la v1.1 risolve questi problemi rovesciando l'architettura: **il Kernel non si difenderà più preventivamente, ma assumerà le garanzie transazionali dal DB e reagirà ai fallimenti in modo puramente funzionale.**

---

## FASE 1: Operazione Verità e Fix Operativi

Gli ingegneri di sistemi si fidano del codice che non mente. Riconciliamo la documentazione con la realtà e chiudiamo le falle logiche.

### 1. Igiene e Lessico
*   **Non è "Copy-on-Write" (CoW):** State facendo una copia difensiva completa dell'hash con `deep_dup` + `deep_freeze`. È robusto, ma alloca memoria. **Azione:** Cambiare la nomenclatura nella documentazione in *"Frozen Value Semantics"* o *"Immutable-by-copy"*.
*   **Ridimensionare le "Monadi":** `DAG::Result` (`Success`/`Failure`) è una mini-monade eccellente. Ma `Effects::Await` non ha `bind` né `pure`. **Azione:** Correggere il commento in `await.rb:5` da *"Monad-like"* a *"Effect snapshot dispatcher"*.
*   **Uccidere le Micro-ottimizzazioni:** Le 19 righe di loop C-style in `canonical_committed_attempt` (`runner.rb:393`) rendono il codice illeggibile per risparmiare l'allocazione temporanea di un array. **Azione:** Sostituire con `attempts.select(&:committed?).max_by { |a| [a.attempt_number, a.attempt_id] }`.
*   **Eliminare i Fantasmi:** Rimuovere `REVIEW.md` obsoleto dalla root (parla di Thread e file write inesistenti).

### 2. Sicurezza Pubblica
*   **[CRITICO] Il Deadlock dell'Idempotenza:** Se uno step genera un effetto con la stessa chiave ma payload diverso, lo storage lancia `IdempotencyConflictError`. Il `Runner` non lo cattura e il nodo va in loop infinito. **Azione:** Convertire temporaneamente l'errore in `Failure` terminale irreversibile (questo sarà poi risolto strutturalmente nella Fase 2).
*   **Blindare le API:** Aggiungere controlli rigidi in `RunResult` (validare l'enum `state`), in `StepInput` (validare `ExecutionContext`), e in `Event/RuntimeProfile` (timestamp >= 0).
*   **Isolare i Metadati:** Rimuovere `payload_fingerprint`, `external_ref` e `not_before_ms` dallo snapshot degli effetti. Lo step utente non deve vedere i lock infrastrutturali.

---

## FASE 2: Il Redesign dello Storage (Il Cuore della v1.1)

Attualmente il `Runner` implementa la logica di business e la gestione della concorrenza (read-before-write) per poi istruire lo storage su cosa salvare passo-passo. Il port è esploso a 26 metodi procedurali.

Nella v1.1, **invertiamo la gravità.** Il Kernel assume che lo Storage sottostante garantisca l'integrità nativamente e si limita a reagire alle violazioni sfruttando il potere dei tipi monadici.

### 2.1 Le Assunzioni Delegate al Database
Per implementare l'adapter durevole S0 (SQLite/PostgreSQL) pretenderemo 3 garanzie incrollabili dal sistema di storage:
1. **CAS (Compare-And-Swap) Nativo:** Nessun check preventivo in memoria. Il kernel invia l'update, e il DB applica i vincoli di concorrenza (`UPDATE ... WHERE revision = X`).
2. **Idempotenza via Unique Constraints:** Nessuna query per sapere se un effetto esiste già. Sarà l'indice nativo `UNIQUE(workflow_id, step_key, payload_fingerprint)` a far fallire l'inserimento del duplicato.
3. **Unit of Work (ACID):** Transazioni esplicite. Commit di attempts, effetti ed eventi avvengono tutti in una singola transazione database. Tutto o niente.

### 2.2 Le Violazioni come Valori Monadici (Il DB restituisce lo stato del mondo)
Basta lanciare eccezioni (`raise StaleStateError`). Le eccezioni sono `GOTO` mascherati che rompono il design funzionale. 

Il driver dell'adapter intercetterà gli errori nativi SQL (es. `SQLite3::ConstraintException`) e restituirà la nostra monade `Failure` modellando la violazione in modo semantico e **allegando lo stato effettivo del mondo in quel momento**.

```ruby
module DAG::Ports::Storage::Violations
  # Il DB segnala: "Optimistic lock fallito. Un altro worker ci ha battuto sul tempo.
  # Lo stato attuale a terra adesso è actual_state."
  StaleState = Data.define(:entity, :expected_rev, :actual_rev, :actual_state)
  
  # Il DB segnala: "Violazione di constraint UNIQUE. L'effetto esiste già."
  IdempotencyConflict = Data.define(:key, :existing_fingerprint)
end
```

Il `Runner` elimina i blocchi `begin/rescue` ed evolve in una purissima macchina a stati che fa pattern-matching sulla realtà restituita dal database:

```ruby
# Il Kernel ordina l'operazione ciecamente, delegando il lock al DB
result = @storage.apply_commit(intent)

result.recover do |violation|
  case violation
  when DAG::Ports::Storage::Violations::IdempotencyConflict
    # Il DB ci ha avvertiti dell'idempotenza violata. Transizione a terminal failure.
    transition_to_terminal_failure!(diagnostic: :idempotency_breach, details: violation)
    
  when DAG::Ports::Storage::Violations::StaleState
    # Ci adattiamo alla verità del DB SENZA fare ulteriori query di lettura
    if violation.actual_state == :paused
      reconcile_and_suspend(violation)
    else
      yield_execution_to_other_worker
    end
  end
end
```

### 2.3 Contrarsi verso gli "Storage Intents"
Invece di avere 10 metodi di lifecycle frammentati nel port (`transition_node_state`, `append_event`, `mark_effect`), il Kernel assemblerà un "Intento Transazionale" in memoria e lo consegnerà allo storage.

```ruby
CommitIntent = Data.define(:node_id, :precondition, :mutations)

intent = DAG::Storage::CommitIntent.new(
  node_id: node.id,
  precondition: { node_state: :running },
  mutations: {
    node_state: :committed,
    append_events: [node_committed_event],
    upsert_effects: [new_effect]
  }
)

# Il Kernel chiama UNA sola primitiva. L'adapter SQL farà BEGIN ... COMMIT.
@storage.apply_commit(intent) # Ritorna: Success | Failure(Violation)
```

### 2.4 Deframmentare il Memory Adapter (Pre-SQL)
Prima di scrivere una sola riga di SQL, il file `Memory::StorageState` (oggi 760 righe monolitiche) andrà preparato:
*   Spezzare logicamente il modulo interno in file separati: `workflows.rb`, `attempts.rb`, `events.rb`, `effects.rb`. 
*   Questi file saranno la **blueprint mentale esatta 1:1** per la creazione del DDL (schema tabelle e foreign keys) del futuro adapter SQLite.
*   Modificare l'adapter in memoria affinché **restituisca le Monadi di Violazione invece di lanciare eccezioni**. Questo permetterà di validare e testare il nuovo `Runner` funzionale immediatamente senza spaccare il comportamento legacy in questa fase.

---

## Il Mandato

Questa è l'ingegneria che trasforma un bel prototipo in un motore da produzione. 

Eseguite questa roadmap nell'ordine esatto: pulite il codice e le API (Fase 1), poi aggredite il port dello Storage (Fase 2). Una volta che il Runner comincerà a consumare "Violazioni monadiche" invece di gestire "Eccezioni procedurali di lock", avrete un Kernel antiproiettile. 

A quel punto, scrivere l'adapter SQL sarà un banale esercizio di mappatura transazionale. Sarete pronti per il mondo reale.