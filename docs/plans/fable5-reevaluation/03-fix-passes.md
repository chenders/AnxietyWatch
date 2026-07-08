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

_Pending._
