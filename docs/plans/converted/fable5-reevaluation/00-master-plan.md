# Fable 5 Full-Codebase Re-Evaluation — Master Plan

## Context

The project switched to Claude Fable 5 (a new Mythos-class model tier above Opus). This effort re-evaluates the entire AnxietyWatch codebase bottom-to-top with the new model's capabilities: deeper bug/accuracy/efficiency detection, best-practices modernization (including the Claude/Copilot instruction files and tooling), a full UI/UX review, a sensor-data-reliability push, and runtime testing on the simulator that pure code analysis can't cover — including timing/performance measurement.

**Scale being audited (as of Phase 0):** ~45k lines of Swift (271 files: 46 services, 21 models, 12 iOS view areas, watch app, widgets, 87 test files) + ~15k lines of Python server (Flask app, admin UI, 3 external sync clients — ResMed/Walgreens/CapRx, crypto, EDF parsing, analysis) + the `.claude/` tooling layer (5 agents, 7 hooks, Semgrep rules, 5 instruction files).

**Decisions (recorded at planning time):**
1. **Findings-register-first** — audit phases produce a triaged register; fixes happen in prioritized batches as separate PRs.
2. **Full server parity** — the Python server gets the same audit depth as iOS (it handles medical data and credentials).
3. **Land in-flight work first** — the uncommitted `tooling/claude-code-recommendations` work is finished/merged in Phase 0 so audits run against a clean baseline.
4. **Full multi-agent orchestration authorized** — Workflow fan-outs with adversarial verification for the audit phases.

## Deliverable structure

```
docs/plans/fable5-reevaluation/
├── 00-master-plan.md            # this file
├── 01-codebase-atlas.md         # sub-plan: exploration & reference doc
├── 02-deep-audit.md             # sub-plan: bugs / accuracy / efficiency
├── 03-fix-passes.md             # sub-plan: prioritized fix batches
├── 04-modernization.md          # sub-plan: best practices + instructions refresh
├── 05-ui-ux-modernization.md    # sub-plan: UI/UX best-practices review, polish → overhaul
├── 06-sensor-reliability.md     # sub-plan: maximizing reliable data consumption
├── 07-runtime-validation.md     # sub-plan: simulator testing + performance timing
├── 08-wrapup.md                 # sub-plan: consolidation
├── CODEBASE_ATLAS.md            # output of Phase 1
├── UI_UX_PROPOSALS.md           # output of Phase 5
└── FINDINGS.md                  # living findings register (Phases 2, 6, 7 append)
```

Each phase runs in its own dedicated session(s). Each sub-plan doc gets an `## Implementation notes (post-merge)` section updated as it ships, per the CLAUDE.md plan-doc mandate.

## Ground rules (apply to every phase)

- **Never commit to main.** Branch naming: `fable5/phase-N-<slug>`, one PR per phase deliverable or fix batch.
- **Findings register format** (`FINDINGS.md`): each entry gets `ID | subsystem | severity (P0–P3) | confidence (confirmed/plausible) | effort (S/M/L) | summary | failure scenario | file:symbol`. Only adversarially-verified findings enter as "confirmed."
- **Every confirmed bug fix ships with a regression test** (Swift Testing / pytest per side).
- **Pre-PR review policy holds:** `swift-pre-pr-reviewer` before any substantive Swift push, plus the specialized agents per their dispatch table.
- **Public-repo PII rules hold everywhere** — audit outputs must not quote real health data values from the prod DB; findings describe shapes and counts, not values.
- **Fable 5 phrasing discipline:** Fable 5 has per-turn safety classifiers (offensive-cyber, biology) that reroute flagged turns to Opus — defeating the point of this effort. All audit prompts (main session and sub-agents) use defensive-QA framing: "verify auth coverage," "confirm queries are parameterized," "check credentials never reach logs" — not attack-framed vocabulary ("exploit," "injection attack," "adversary"). Recommended: `/config` → disable "switch models when a message is flagged" so flagged turns ask instead of silently switching, letting you rephrase and retry on Fable 5.

## Baseline metrics (Phase 0 — recorded 2026-07-08)

Captured against `tooling/claude-code-recommendations` after landing the in-flight restore-from-server work and its two bundled bug fixes.

| Metric | Value |
|--------|-------|
| iOS unit tests (`AnxietyWatchTests`) | **966 passed, 0 failed, 0 skipped** (27.5s) |
| iOS overall coverage (report scope) | **49.8%** (24,221 / 48,645 executable lines) |
| — `AnxietyWatch.app` target | 30.7% (10,091 / 32,873) |
| — `AnxietyWatch Watch App` target | 28.7% (391 / 1,362) |
| — `AnxietyWatchWidgetsExtension` | 0% (251 lines) |
| — `AnxietyWatchLiveActivitiesExtension` | 0% (330 lines) |
| — `AnxietyWatchTests` (self) | 99.3% |
| Server tests (`pytest`) | **338 passed** (~41s, Docker Postgres 16) |
| Server lint (`flake8 --max-line-length=120`) | **clean** |
| Build warnings | 0 (CI enforces `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`) |

**Coverage-target notes** (from CLAUDE.md): overall target ≥25% (met at 49.8%); Services/ target ≥80%; long-term overall ≥40% (met). The two app-extension targets at 0% and the 30.7% main-app figure (dominated by untested SwiftUI view bodies) are the obvious coverage-ratchet opportunities for Phase 4c.

**Test-infrastructure note:** server tests need a Postgres. The system Homebrew Postgres on `:5432` is NOT to be used — spin a disposable Docker Postgres 16 instead:
```bash
docker run -d --name anxietywatch-test-db -p 127.0.0.1:5434:5432 \
  -e POSTGRES_USER=anxietywatch -e POSTGRES_PASSWORD=anxietywatch \
  -e POSTGRES_DB=anxietywatch_test postgres:16-alpine
TEST_DATABASE_URL="postgresql://anxietywatch:anxietywatch@localhost:5434/anxietywatch_test" \
  uv run --with-requirements requirements.txt python3 -m pytest tests/ -q
```
(Port 5434 chosen because 5433 is occupied by an unrelated project's DB and 5439 is the prod-compose mapping.)

## Phase summaries

Full detail lives in each sub-plan doc. One-line intents:

- **Phase 0 — Baseline & scaffolding** (this doc): land in-flight work, record green baseline, scaffold the plan docs. *In progress.*
- **Phase 1 — Codebase Atlas** (`01`): reference-grade `CODEBASE_ATLAS.md` via ~12–15 parallel subsystem readers + synthesis + completeness critic.
- **Phase 2 — Deep audit** (`02`): 7 finder dimensions × 3-lens adversarial verification, loop-until-dry → `FINDINGS.md`.
- **Phase 3 — Fix passes** (`03`): burn down approved register entries in reviewable batches, each with a regression test.
- **Phase 4 — Modernization** (`04`): Swift 6 readiness, dependency/API currency, CI, and the Claude/Copilot instruction + tooling refresh (recalibrated for Fable 5).
- **Phase 5 — UI/UX modernization** (`05`): five-lens evaluation of every screen → `UI_UX_PROPOSALS.md` → prototyped, triaged, batched.
- **Phase 6 — Sensor reliability** (`06`): quantify data loss from Watch/EMAY/Polar first, then reliability engineering + device test protocol.
- **Phase 7 — Runtime validation & performance** (`07`): simulator functional matrix, signpost timing, server runtime pass.
- **Phase 8 — Consolidation** (`08`): final report, doc post-merge notes, memory updates.

## Verification (overall)

- **Per phase:** each sub-plan's "done when" criteria; every PR passes CI (iOS tests + SwiftLint strict + warnings-as-errors; server flake8 + pytest).
- **End-to-end:** Phase 7's full simulator matrix + server smoke pass green on the final state; coverage ≥ this baseline; zero warnings; timing table shows no regression vs. baseline on instrumented paths.
- **Register integrity:** every FINDINGS.md entry has a terminal disposition (fixed+PR / deferred+reason / rejected+reason).

## Implementation notes (post-merge)

_Phase 0 in progress. Notes appended as phases ship._

- **Phase 0:** Moved personal medical file (`Reply_to_Geistwhite_…html`) out of the repo working tree to `~/Documents/AnxietyWatch-private/`. Landed the in-flight restore-from-server feature (`RestoreFromServer.swift`) plus two bundled production bug fixes (SleepEfficiencyCalculator denominator floor; DashboardViewModel efficiencyBaseline clamp) with regression tests. Fixed two time-bomb test failures in `DashboardViewModelTests` (unpinned `loadSamples(now:)`). Added server tests for the 5 new `/api/data` export entities and the BYTEA-drop path.
