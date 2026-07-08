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

**Executed 2026-07-08 as a single background Workflow** (`fable5-phase2-deep-audit`, run `wf_52e8cfd2-4d5`): 7 finder dimensions running concurrently, loop-until-dry (2 consecutive empty rounds per dimension, cap 6), with every fresh finding sent through a 3-lens skeptical verifier (correctness / manifestation / severity; ≥2 of 3 → `confirmed`). The `medical-data-accuracy-reviewer` and `swiftui-render-pitfall-detector` sub-agents were dispatched as the finders for their dimensions per the dispatch table. All prompts used defensive-QA phrasing per the master-plan ground rules.

**Rounds reached per dimension before the run stopped:** medical-accuracy 4, all others 3.

**Interruption + recovery.** The run hit the Claude subscription **session limit at 5:30am Pacific** mid-flight: 266 of 353 agents completed, 87 errored on the limit (the round-2/3/4 discovery sweeps for several dimensions, a batch of verify lenses, and the final `synthesize-register` step). An accidental client quit then changed the session identity, making the workflow's same-session `resumeFromRunId` cache unusable. Rather than re-run 353 agents (re-spending ~16.6M tokens and risking another limit hit), the register was **reconstructed from the 266 completed agents' verified findings**, which were intact in the run journal / task-output on disk. The lost work was the cross-dimension synthesis (done by hand here) and marginal extra discovery rounds — so a small number of additional findings may remain unfound; a future top-up pass can resume the loop.

**Synthesis.** 105 verified findings → **88 register entries** after collapsing 15 same-root-defect merge groups (e.g. the ResMed `log_sync` unconditional-cursor bug was independently reported by 4 dimensions; the EMAY DST fall-back, the `lastNightSection` stale-AHI pairing, the compound-`#Predicate` glucose hang, and several unbounded-`@Query` pitfalls each surfaced twice). Headline severity is the **median of the 3 severity-lens votes** for confirmed findings (per the ground-rules synthesis instruction), which pulled every finder-`P0` down to `P1`; each entry's finder severity + raw lens votes are preserved in the Detailed findings section so a maintainer can re-elevate. Final tally: **12 P1, 38 P2, 38 P3; 65 confirmed, 23 plausible** (the `plausible` set includes findings whose verify lenses were cut off by the limit, not only genuinely-uncertain ones).

**Status: audit run complete and the register is PR'd on `fable5/phase-2-audit` with every entry `open`.** Of the "Done when" criteria above, the loop-dry and register-PR'd criteria are met; the final criterion — the maintainer's triage pass (approve/defer/reject per finding), recorded directly in `FINDINGS.md` — is still outstanding, so the phase is not yet fully done.
