# ruby-dag Roadmap

## Source-of-truth hierarchy

Two normative documents live in the repo root, with non-overlapping scopes:

1. **`Ruby DAG Project Roadmap v3.4.md`** — kernel architecture and phase
   plan. Authoritative for: the four pillars (§2), frozen decisions (§3),
   public contract (§7), per-phase Output file obbligatori and DoD
   (§5–§6), anti-patterns (§9), and appendices.
2. **`Delphi Ruby DAG Execution Plan.md` (v2.1-final)** — effects protocol
   and consumer integration. Authoritative for: effect-aware kernel
   contract (§2–§3), the upstream PR sequence PR 0–PR 5 (§4), the SQLite
   adapter shape (§5), the dispatcher / handler split (§6), and the
   pinning rule (§4 PR 5).

Where the two documents touch the same topic, the **execution plan v2.1
supersedes the v3.4 roadmap** because it is more recent and was written
after the effects-aware redesign. Concretely, the consumer host is
`Delphi` (project name) in the `nexus` repo, branch `delphi-v1`. The
older `delphic` / `Delphic::Adapters::Sqlite` naming used in the v3.4
roadmap §1 / §2.5 / §3 is retained there as historical context only;
new code, doc edits, and configuration must use the `Delphi` / `nexus`
naming per execution-plan §0 directive 1 ("Rimuovere nomenclatura
delphic/Delphic").

The v0.x feature roadmap that used to live in this file has been retired
together with the legacy runtime in the R1 cleanup.

Tracked phases:

| Phase | Issue  | Status     |
|-------|--------|------------|
| R0    | #70    | Done (#122) |
| R1    | #71    | Done (#123) |
| R2    | #72    | Done (#124) |
| R3    | #73    | Done (#125) |
| Effects PR1 (value layer)        | —    | Done (#151) |
| Effects PR2 (storage ledger)     | —    | Done (#152) |
| Effects PR3 (runner integration) | —    | Done (#153) |
| Effects PR4 (abstract dispatcher)| —    | Done (#154) |
| Effects PR5 (docs + release gate)| #149 | Done (#155) |
| V1.1 kernel hardening          | #157 | Done (#158-#164 via #166, #167, #168, #169, #170, #171, #172) |
| Release v1.1                   | #165 | Done |
| S0 (SQLite adapter, in Delphi)   | TBD  | Next |
| Release v1.0                     | #74  | Done (#126, #156) |

S0 is no longer a phase of `ruby-dag` itself: per execution-plan §5, the
first durable storage adapter lives in the `Delphi` consumer (in repo
`nexus`, branch `delphi-v1`) and implements the public
`DAG::Ports::Storage` port.

Roadmap board: <https://github.com/users/duncanita/projects/2>.

Per-phase plans land under `docs/plans/`.
