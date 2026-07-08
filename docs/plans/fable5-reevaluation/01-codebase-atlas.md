# Phase 1 — Codebase Atlas

**Goal:** a reference-grade `CODEBASE_ATLAS.md` that every later phase (and every future spawned agent) reads instead of re-exploring ~60k lines. This is the "general project exploration markdown" step.

## Method — Workflow fan-out (~12–15 parallel readers, one per subsystem cluster)

**iOS clusters:**
- HealthKit ingestion — `HealthKitManager`, `HealthDataCoordinator`, `SnapshotAggregator`, `BaselineCalculator`
- Polar / HRV pipeline — `PolarHRMService`, `HRVSessionRecorder`, `LFHFAggregator`, `HRVCalculator`
- CPAP + EMAY + SpO2 arbitration — `CPAPImporter`, `EMAYService`, `SpO2SourceArbiter`
- Sync — `SyncService`, `RestoreFromServer`, `PhoneConnectivityManager`
- Prescriptions / pharmacy / medications — supply calculator, label scanner, call service
- Dashboard + view models
- Trends charts (`Views/Trends/`) + `ChartPalette`
- Journal / labs / reports / export
- Watch app + WatchConnectivity + widgets + live activities
- Models layer — all 21 `@Model` classes + schema-history docstrings

**Server clusters:**
- `server.py` + `admin.py` + templates
- The 3 sync clients (ResMed/Walgreens/CapRx) + their cron jobs
- `crypto.py` + auth + `schema.sql` + Alembic migrations
- `edf_parser.py` + `analysis.py` + `correlations.py` + `conflict_analysis.py`

**Tooling cluster:** `.claude/` agents/hooks/commands, `.semgrep/`, CI workflows, the 5 instruction files.

## Reader output contract

Each reader produces a structured section:
- **Purpose** — what the subsystem is for
- **Key types/functions** — anchored by **symbol name, not line number** (line anchors go stale)
- **Data flow** — in / out
- **Invariants** it maintains
- **Oddities noticed** — seed material for Phase 2, framed as observations, NOT conclusions

## Synthesis + critic

1. **Synthesis agent** merges sections into `CODEBASE_ATLAS.md` with three cross-cutting data-flow narratives:
   - HealthKit → snapshot → dashboard
   - sensor session → aggregation → charts
   - app → SyncService → server → admin/restore
2. **Completeness-critic agent** asks "which files/flows are unmapped?" — any gap triggers one more reader round.

## Also fold in

- The CLAUDE.md **Common Pitfalls** list as a formal **invariants registry**: each pitfall → which code enforces it → which test covers it. (This becomes the backbone of the Phase 2 test-gap dimension.)
- **Known-issue seeds** from memory, e.g. the sleep-lane physiologically-impossible-values issue queued for a separate `health.psv` investigation.

## Done when

Atlas covers every directory, the critic pass finds no unmapped flow, PR merged (`fable5/phase-1-atlas`).

## Implementation notes (post-merge)

- **Executed 2026-07-08** as a 22-agent workflow (16 cluster readers → synthesis → completeness critic → 3 gap-fill readers + integration), ~2.2M subagent tokens, ~23 min wall clock. Zero agent failures.
- **Output:** `CODEBASE_ATLAS.md` (719 lines): 3 data-flow narratives, 15 consolidated cluster sections, the 26-pitfall invariants registry with enforcement/test mapping, a 186-entry oddity index, and known-issue seeds.
- **Critic round:** found 3 real gaps (in-app recording status pill subsystem; `MetricSalience` — a tested service with no production callers; `NotificationDelegate` dose-follow-up hop), all integrated.
- **Notable registry finding:** ~a third of the 26 CLAUDE.md pitfalls have no machine enforcement (review-agent only), and the cross-check surfaced live counterexamples (unbounded `@Query`s in 5+ views, dictionary-ordered `ForEach` feed, non-Equatable `@Query` navigation destinations, ChartPalette token drift). These are Phase 2/4 inputs.
- **Scope delta:** none — plan executed as written. Chris chose to ship the oddity index unranked and let Phase 2 do all triage.
