# Phase 2 — Deep audit: bugs, data accuracy, efficiency

**Goal:** the core "what can Fable 5 find that previous models missed" phase. Static analysis only (runtime discovery is Phase 7). Output: entries in `FINDINGS.md`.

**Prompt-phrasing note:** frame all finder/verifier prompts as defensive QA (see master-plan ground rules) so audit turns stay on Fable 5.

## Method — Workflow: finder dimensions × adversarial verification, loop-until-dry

Each finder dimension is an independent agent armed with `CODEBASE_ATLAS.md`:

1. **Medical-data accuracy** — units, timezone/DST, source-discriminator completeness, nil-backfill gaps, baseline math, cross-source arbitration (HK vs Polar vs EMAY vs CPAP), day-boundary bucketing. Includes dispatching the existing `medical-data-accuracy-reviewer` agent per Services cluster.
2. **Concurrency & state** — actor isolation, sync-cursor invariants (the documented race family), WatchConnectivity ordering, drain-loop correctness, server job dispatcher.
3. **SwiftUI/SwiftData render pitfalls** — the four documented iOS-26 hang patterns swept across ALL views (existing tooling only checks diffs; this is the full-codebase sweep). Dispatch `swiftui-render-pitfall-detector` per view area. (Phase 0 already caught one live instance in `HRVSessionCardView` — expect more.)
4. **Silent failures & error handling** — swallowed catches, fallback dishonesty, empty-state gates, import pipelines that drop rows quietly.
5. **Server data-safety & credential hygiene** — verify auth coverage on every endpoint, confirm all queries are parameterized, check credentials/PII never reach logs, review `crypto.py` correctness and admin session handling.
6. **Efficiency (static)** — unbounded `@Query`s, per-render recomputation, O(n²) aggregations, server N+1 queries, index coverage vs. query patterns in `schema.sql`.
7. **Test-coverage gaps** — which invariants in the atlas registry have no test; float-equality and fixed-date discipline in existing tests (Phase 0 found two time-bombed tests — sweep for the same pattern: fixed fixture dates + unpinned `now`).

## Verification gate

Every finding goes through a **3-lens verify** (correctness lens, does-it-reproduce lens, severity lens) — ≥2 of 3 must confirm for **confirmed** status; otherwise logged as **plausible**. Loop until 2 consecutive finder rounds produce nothing new per dimension. Final dedup + severity-ranking synthesis writes the register.

## Seeds from Phase 0

- PII-in-fixtures hook false-positives on UUIDs (digit runs match its phone regex) — also a Phase 4d tuning item.
- "Should estimated sleep efficiency count toward the LastNight verdict?" (deferred from PR #152).
- Sleep-lane physiologically-impossible values (from memory; queued `health.psv` investigation).
- Per-entity sleep-event date shift in `RestoreFromServer` only aligns the newest night (documented tradeoff — check nothing production-facing shares the pattern).

## Done when

Loop dry, register PR'd (`fable5/phase-2-audit`), and Chris has done a triage pass (approve/defer/reject per finding) recorded directly in `FINDINGS.md`.

## Implementation notes (post-merge)

_Pending._
