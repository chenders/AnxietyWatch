# Phase 3 Handoff — Fable 5 Re-Evaluation (session restart)

**Written 2026-07-08.** This is a session-continuation handoff (local-only, git-excluded — do not commit). The prior session ran out of access to the Fable 5 model and is being restarted. Pick up Phase 3 (fix passes) from here.

## First: model + framing
- **Switch the session model back to Fable 5** (`/model`). If Fable isn't listed, that's the reason for this restart — retry until it's available. All the heavy fix/review work should run on Fable.
- Fable 5 has per-turn safety classifiers that silently reroute flagged turns to Opus. Use **defensive-QA phrasing** in any audit/review prompts ("verify auth coverage", "confirm queries are parameterized"), never attack-framed vocabulary. See `00-master-plan.md` ground rules and memory `reference_fable5_safety_fallback`.
- There was a subscription **session limit** hit earlier (resets ~5:30am Pacific daily). If heavy multi-agent work dies with "session limit", pause and resume after reset.

## What is DONE (merged to `main`)
- Phase 0 (baseline/scaffold), Phase 1 (Codebase Atlas) — merged (#154).
- **Phase 2 deep audit** — findings register merged (#155); **triage accepted** and dispositions applied (#156). 88 findings: 84 approved, 4 deferred, 0 rejected. Register + accepted triage + fix-batch plan live in `docs/plans/fable5-reevaluation/FINDINGS.md`.
- **Phase 3 Batch A** (render crash pitfalls, NavigationLink+@Query family) — merged (#157). Closed F-001–F-005, F-032, F-073 + a bonus `ExportView` instance the audit missed.

## What is IN FLIGHT — resume here
### Batch B — sync integrity (branch pushed, NOT yet PR'd)
- Branch: **`fable5/phase-3-sync-integrity`** (commit `e410ccf`), already pushed to origin.
- Fixes **F-013** (finalize/finalizeOrphan reset `syncedToServer=false`), **F-014** (uploadPendingRRArchives gated on `endTime != nil`), **F-016 / P1** (`@MainActor` on `SongService.fetchCatalog` + `SyncService.fetchPrescriptions` to close a SwiftData ModelContext data race).
- **F-015 and F-012 were SPLIT to a Batch B-2** (deeper RR-retry decoupling + a `SyncService.sync()` test seam). F-013+F-014 already close the common case of F-015.
- Build + 76 sync/recorder tests are green; 2 existing `SyncServiceTests` fixtures were updated to finalized sessions (they exercised the pre-F-014 behavior).
- **Pre-PR review:** `medical-data-accuracy-reviewer` completed and returned a **BLOCKING finding (below)**. `swift-pre-pr-reviewer` was still running when the session died — **re-run it** on `git diff main`. Then address the blocking finding, open the PR, run the Copilot loop (`/respond-to-copilot <PR#>`), and squash-merge + delete branch.

- **⛔ BLOCKING pre-merge item for Batch B (must fix before PR/merge):** the F-013 re-dirty is correct and *shrinks* the original bug, but it exposes a residual race. `SyncService.markSamplesSynced` → `flagSyncedInChunks` (`SyncService.swift:~823-839`) unconditionally sets `SensorSession.syncedToServer = true` for uploaded IDs with **no staleness check against the payload-build-time snapshot** — unlike `flagSnapshotsSynced` (`SyncService.swift:~792-806`), which guards with `pendingSyncVersion` ("leave it dirty so the new changes still sync"). `sync()` extracts `uploadedIDs` (`~161-167`) BEFORE the network `await` (`~176`), a real `@MainActor` suspension point. If a `stopSession()`/`finalizeOrphan()` finalize for that same session interleaves at that `await` (e.g. autosync timer fires as the user taps Stop), the finalize's `endTime`/`summaryJSON`/`interruptionCount` are NOT in the in-flight payload, yet the flag is flipped to synced → **never retried → server permanently holds an unfinished session** (`end_time` NULL, stale summary), and `RestoreFromServer.swift:392` amplifies it onto any new device. **Fix:** extend the `pendingSyncVersion`-style staleness guard to `SensorSession` (and ideally `HRVReading`) in `markSamplesSynced`/`flagSyncedInChunks`, mirroring `flagSnapshotsSynced`; add a regression test that interleaves `finalize()` with an in-flight `sync()` for the same session. (Server upserts already `COALESCE` `end_time`/`summary_json`, so no null-out there — BUT `interruption_count = EXCLUDED.interruption_count` at `server.py:~688` is an unconditional overwrite; consider COALESCE-guarding it too.) This is the CLAUDE.md "conditional-skip breaking an invariant the unconditional version preserved" family — take it seriously.
- **Also worth a test (non-blocking, from the same review):** nothing enforces "every finalize path resets `syncedToServer=false`." Today there are exactly two (`HRVSessionRecorder.finalize`, `PolarHRMService.finalizeOrphan`) and both do; a future third that sets `endTime` without resetting the flag would silently strand its RR archive (F-014 gate). Consider an invariant-style test.

## Then continue the batch queue (from the accepted plan in FINDINGS.md "Proposed fix batches")
Order by impact; one branch/PR per batch, `fable5/phase-3-<slug>`. Each fix ships a regression test.
1. **Batch B** (in flight — finish it): F-012–F-016. (F-015/F-012 → Batch B-2.)
2. **Batch F — medical-accuracy display/report** (14): F-007, F-008, F-009, F-010, F-011, F-023, F-024, F-026, F-027, F-029, F-036, F-045, F-046, F-067
3. **Batch G — import robustness & data-loss** (6): F-006, F-025, F-028, F-040, F-041, F-047
4. **Batch C — server ingest/sync-client** (5): F-038, F-039, F-054, F-068, F-069
5. **Batch E — server security & credential-log hygiene** (8): F-033, F-034, F-035, F-076, F-077, F-078, F-079, F-080
6. **Batch D — server job dispatcher** (3): F-019, F-051, F-053
7. **Batch K — silent-failure / UX honesty** (10): F-017, F-018, F-037, F-042, F-043, F-044, F-081, F-082, F-083, F-086
8. **Batch H — iOS @Query efficiency bounds** (16): F-020, F-021, F-022, F-031, F-055, F-056, F-057, F-062, F-063, F-064, F-065, F-070, F-071, F-072, F-074, F-084
9. **Batch I — server efficiency** (4): F-058, F-059, F-060, F-061
10. **Batch J — test discipline & coverage** (5): F-048, F-049 (real palette collision: glucose vs polarRMSSD both Color.purple — fix token too), F-050, F-087, F-088
11. **Batch A leftover — F-030** (dormant compound-`#Predicate` in GlucoseDetailView) — small follow-up; needs an efficiency-aware predicate restructure (keep `#Predicate` single-clause on metricType, filter date in-memory; see CLAUDE.md render-pitfall + the HRVSessionCardView fix).
- **Deferred (do NOT fix; Phase 8 backlog):** F-052, F-066, F-075, F-085.

## PENDING BOOKKEEPING (not yet done)
The register `FINDINGS.md` dispositions were set to `approved` but NOT yet updated to `fixed`. Update it (a small commit, foldable into a batch PR or a periodic register-sync PR):
- Mark **F-001, F-002, F-003, F-004, F-005, F-032, F-073 → `fixed (#157)`**.
- Add a NEW finding for the `ExportView` NavigationLink+@Query instance found during Batch A review → `fixed (#157)` (F-089 or next id).
- After Batch B merges, mark **F-013, F-014, F-016 → `fixed (#<Batch B PR>)`**; keep F-015, F-012 as `approved` (moved to Batch B-2).
Per Phase 3 method (`03-fix-passes.md`): "register entry updated with PR link and outcome."

## Process + conventions (per-batch)
- **Never commit to `main`.** Branch from main: `git checkout -b fable5/phase-3-<slug> main`. Stage files by name (no `git add -A`).
- **Build/test via XcodeBuildMCP** (session defaults already set: project AnxietyWatch, scheme `AnxietyWatch`, sim `iPhone 17 Pro`). Call `session_show_defaults` once, then `test_sim` with `-only-testing:AnxietyWatchTests/<Suite>` to build the whole app + run scoped tests. Zero warnings required (CI is warnings-as-errors + SwiftLint --strict).
- **Pre-PR review is mandatory** before push: `swift-pre-pr-reviewer` always; add `swiftui-render-pitfall-detector` for view/@Query changes; `medical-data-accuracy-reviewer` for Services touching physiological data; `chart-ux-auditor` for `Views/Trends/`.
- **Commit trailers** (end every commit body):
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` / `Claude-Session: https://claude.ai/code/session_01MckNAKUeYAjHtnnfbuk5gL` (update the session URL to the new session's).
- **PR bodies with backticks/`→` MUST use `--body-file`** (a heredoc with `$(...)` triggers shell substitution on backticks — this bit us).
- **Copilot loop:** the repo has a `respond-to-copilot` skill. Copilot doesn't always auto-review — explicitly request it (`gh api .../requested_reviewers -X POST -f 'reviewers[]=copilot-pull-request-reviewer[bot]'`), capture baseline review count BEFORE re-requesting, poll every 15s. Check BOTH comment endpoints (PR-level `/comments` and per-review `/reviews/{id}/comments`). Reply to each, resolve implemented threads (PRRT ids), re-request, loop until a review has 0 new comments.
- **Merge:** `gh pr merge <#> --squash --delete-branch`, then `git checkout main && git pull --rebase`.

## Useful facts / gotchas
- **Equatable/@Query render template:** destinations pushed via closure `NavigationLink` that hold `@Query` need `Equatable` (identity props only; trivial `== { true }` if no input props; `persistentModelID` for @Model inputs) + `.equatable()` at the call site. Canonical examples: `PolarSessionHRDetailView`, `LFHFSessionDetailView`, `LabResultsView`.
- **Tests:** use `TestHelpers.makeFullContainer()` for SwiftData containers (models have relationships; partial schemas are fragile). `AnxietyEntry(timestamp:severity:)`, `SensorSession(startTime:batteryAtStart:)`. `SWIFT_VERSION = 5.0` so strict-concurrency errors are NOT enforced (F-016-style races compile silently).
- **`megadude`** (deployment host) is ALREADY public across CLAUDE.md/AGENTS.md/query-prod.md/SERVER_SETUP.md — it's not a new leak; don't re-scrub existing occurrences, but don't ADD it to new audit docs (use `<server-host>`).
- **No PII in the public repo** (findings describe shapes, not values). Prefer role-based wording ("the maintainer") over names in docs.
- Server tests need a Docker Postgres (see `00-master-plan.md` for the disposable `:5434` container command); iOS-only batches don't need it.

## Plan docs
- Master plan + ground rules: `docs/plans/fable5-reevaluation/00-master-plan.md`
- Phase 3 method: `docs/plans/fable5-reevaluation/03-fix-passes.md`
- Register + accepted triage + batch plan: `docs/plans/fable5-reevaluation/FINDINGS.md`
- Phases 4–8 sub-plans: `04`…`08` in the same dir.
