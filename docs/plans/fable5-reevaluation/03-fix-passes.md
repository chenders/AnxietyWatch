# Phase 3 — Fix passes

**Goal:** burn down the approved `FINDINGS.md` entries in reviewable batches.

## Method

- **Batch by subsystem + severity:** P0/P1 confirmed first; each PR stays reviewable (~≤400 lines of diff as a guideline). One branch per batch: `fable5/phase-3-<subsystem>`.
- **Every fix:** regression test, doc-comment sync (re-read every `///` in the diff), pre-PR reviewer + the relevant specialized agent, register entry updated with PR link and outcome.
- **Invariant capture:** fixes that establish new invariants get an entry in the atlas invariants registry and — where deterministically checkable — a proposed hook/Semgrep rule (queued for Phase 4d, not built inline).
- **Plausible findings** are re-tested here only if a cheap experiment settles them; otherwise they carry to Phase 7 (runtime) or the deferred backlog.

## Done when

All approved P0–P2 entries closed with merged PRs; P3s explicitly deferred with reasons in the register.

## Implementation notes (post-merge)

Batch execution order was re-derived by impact at kickoff (see `FINDINGS.md` "Proposed fix batches"); the notes below record what actually shipped, in ship order.

- **Batch A — render crash pitfalls (#157, 2026-07-08):** F-001–F-005, F-030 deferred to a leftover follow-up, F-032, F-073, plus F-089 (an `ExportView` instance of the same family found by the pre-PR reviewer during implementation — registered post-audit). Eight `NavigationLink`+`@Query` destinations hardened with identity-only `Equatable` + `.equatable()` per the CLAUDE.md template; six regression tests. *Scope delta:* F-030 (GlucoseDetailView dormant compound predicate) split out — needs an efficiency-aware predicate restructure, queued as the Batch A leftover.
- **Batch B — sync integrity (#158, 2026-07-08):** F-013, F-014, F-016. *Scope delta:* the `medical-data-accuracy-reviewer` pre-PR pass surfaced a blocking residual race (the post-upload `syncedToServer` flip could clobber a finalize that interleaved with the sync's network await), fixed in the same PR by generalizing the `flagSnapshotsSynced` `pendingSyncVersion` staleness token to all four UUID-keyed bulk sync types, with every post-creation re-dirty site bumping the token; server `interruption_count` upsert hardened with `GREATEST`. F-012/F-015 split to Batch B-2 (joined there by F-090, the RR-archive detached-flush ordering gap the same review surfaced).
- **Batch F — medical accuracy (#159, 2026-07-08):** all 14 planned findings (F-007–F-011, F-023, F-024, F-026, F-027, F-029, F-036, F-045, F-046, F-067). *Scope deltas:* pre-PR reviews added a tick-vs-archive counting-basis reconciliation, one-sided PDF reference annotations, two shared-constant consolidations (`SnapshotAggregator.overnightOffsetHours`, RR physiological bounds), and a Last Night card night-window fix (the F-011 defect class in a sibling consumer). Three new findings registered from the review cycle instead of expanding the batch: F-091 (correlations.py UTC day-bucketing → Batch C), F-092 (SpO2 mixed-provenance disclosure), F-093 (LF/HF splice residual).
- **Batch G — import robustness (#160, 2026-07-08):** F-006, F-025, F-028, F-040, F-041, F-047. *Scope deltas:* the medical review surfaced two blocking residuals fixed pre-merge — the backfill day-walk missed the morning-after snapshot day for overnight imports (new `SnapshotAggregator.backfillDays`), and the DST fold heuristic gained a real transition-table cross-check so clock resyncs cannot be mis-corrected.
