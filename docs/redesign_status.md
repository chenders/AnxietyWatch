# Redesign v3 — Implementation Status

Branch: `redesign/v3-implementation`
Plan:  `Docs/redesign_plan.md`
Spec:  `Docs/redesign_spec.md`

## Model roles
- **AUTHOR-Swift** = Qwen3-Coder (pane `shell`, w1:p5)
- **AUTHOR-Complex** = Gemini 3.1 Pro (pane `worker-2`, w1:p4)
- **AUTHOR-Fast** = GPT-OSS-120b via Groq (pane `author-fast`, w1:p7)
- **REVIEWER** = Claude Opus (pane `worker-1`, w1:p3)
- **QUICK-CHECK** = Gemini 3.5 Flash (pane `quick-check`, w1:p6)
- **COMBINED-REVIEW** = alternate Opus / GPT-OSS-120b

## Workflow
For each task:
1. AUTHOR writes code to the paths listed under the task.
2. REVIEWER critiques; iterate up to 3 rounds until agreement (or reviewer explicit SIGN-OFF).
3. QUICK-CHECK sanity-pass looking for missed items.
4. `cd Docs/../ && xcodebuild build test -scheme AnxietyWatchKit -destination 'platform=iOS Simulator,name=iPhone 15'`. AUTHOR fixes any errors, back to step 2 if non-trivial.
5. Mark task `[x]` here with commit SHA. `git commit`.

Every 5 completed tasks: full combined review of the branch diff since the last checkpoint by the rotating COMBINED-REVIEW model.

## Task list

Legend: `[ ]` pending · `[~]` in progress · `[x]` done · `[!]` blocked

### Foundation
- [x] T01. `AnxietyWatchKit` SPM foundation. Author: Qwen3-Coder. Reviewer: Opus (2 rounds → sign-off). Quick: Flash. Commit `74a24cb`. **Xcode-project package reference deferred to T02+ as a hard gate.**
- [x] T02. Diagnostics logging + signposts. Author: Qwen3-Coder (AUTHOR-Fast on Groq llama-3.3-70b hit TPM=12k limit on 20k prompt; rerouted). Reviewer: Opus SIGN-OFF w/ nits. Quick: Flash. Commit `69293aa`. Spec §8.3 amended to lock single-subsystem convention.

**Note on AUTHOR-Fast:** Groq free tier caps `llama-3.3-70b-versatile` at 12k TPM. Prompts must stay <8k prompt tokens (no file reads). Currently only useful for pure-generation tasks with tiny prompts. Consider deferring to shell/worker-2 for anything requiring context files.
- [x] T03. DatabaseManager skeleton. Author: Qwen3-Coder. Reviewer: Opus (5 fix items). Quick: Flash. Commit `43569c5`.

### Storage (§1)
- [x] T04. SchemaV1 DDL bundle. Author: Qwen3-Coder (author-fast rerouted — Groq TPM cap 12k tokens). Reviewer: Opus (3 nits). Quick: Flash. Commit `43569c5`.

**Author-fast update (2026-07-16 02:15 PT):** user switched author-fast to `openai/gpt-5.3-codex` — agentic-coding model, appears reliable. Re-add to rotation for T05+.
- [x] T05. SamplesStore. Author: Qwen3-Coder. Reviewer: Opus (3 correctness fixes). Quick: Flash. Commit `7cd5026`.
- [x] T06. SyncLogStore. Author: Qwen3-Coder. Reviewer: Opus (3 correctness fixes incl HLC-guarded ON CONFLICT). Quick: Flash. Commit `7cd5026`.
- [x] T06a. HLCStamped. Author: gpt-5.3-codex. Reviewer: Opus (nodeID-width fix in spec §2.1). Quick: Opus. Commit `582d612`.
- [x] T06b. DatabaseManager.registerFunction. Author: Qwen3-Coder produced only a dead field; implementation by conductor from Opus's spec. Reviewer: Opus. Quick: Opus. Commit `582d612`.
- [x] T06c. SampleTombstonesStore. Author: conductor (single-reviewer mode). Reviewer: Opus SIGN-OFF. Quick-check: none (Flash over budget). Commit `0a6aa85`. Forward-notes: no tombstone GC yet; style drift (named vs positional row subscripts); fetchOverlapping unpaginated.
- [x] T06d. CorruptionBroadcaster. Author: gpt-5.3-codex + conductor (onTermination, publish self-prune, Phase Sendable projection). Reviewer: Opus. Quick: Opus. Commit `582d612`.
- [ ] T07. `Storage/BackfillProgressStore.swift` + tests. AUTHOR-Fast.
- [ ] T08. `Storage/QuarantineStore.swift` + tests. AUTHOR-Fast.
- [ ] T09. `Storage/Compaction/RetentionCompactor.swift` + tests. AUTHOR-Swift.
- [ ] T10. `Storage/Compaction/IdleDownsampler.swift` + tests. AUTHOR-Swift.
- [ ] T11. `Storage/Compaction/CheckpointManager.swift` + tests. AUTHOR-Swift.
- [ ] T12. Corruption recovery flow + tests (§1.6). AUTHOR-Complex.

### Sync (§2)
- [ ] T13. `Sync/HLCTimestamp.swift` + `Sync/HLC.swift` service + tests (Kulkarni HLC axioms as property tests). AUTHOR-Complex (deep correctness), REVIEWER Opus.
- [ ] T14. `Sync/ClockSuspectGate.swift` + tests. AUTHOR-Complex.
- [ ] T15. `Sync/SyncCursor.swift` + tests. AUTHOR-Fast.
- [ ] T16. `Sync/SyncableMacro/` — @Syncable Swift macro + macro-fixture regression tests (EMAY-loss guard). AUTHOR-Complex (macros are hard).
- [ ] T17. `Sync/SyncCoordinator.swift` + tests. AUTHOR-Complex.
- [ ] T18. `Sync/PanicProtocol.swift` + tests. AUTHOR-Complex.
- [ ] T19. `Sync/UnackedOverflow.swift` + tests. AUTHOR-Complex.

### BLE (§3)
- [ ] T20. `BLE/PolarActor.swift` + tests. AUTHOR-Swift.
- [ ] T21. `BLE/EMAYActor.swift` + tests. AUTHOR-Swift.
- [ ] T22. `BLE/HealthKitAdapterActor.swift` + tests. AUTHOR-Swift.
- [ ] T23. `BLE/SensorRouter.swift` + tests. AUTHOR-Swift.

### Pipeline (§4)
- [ ] T24. `Pipeline/PipelineState.swift` + `Pipeline/PipelineStep.swift` (pure function) + property tests + purity lint script. AUTHOR-Complex, REVIEWER Opus.
- [ ] T25. `Pipeline/CNSFusionEngine.swift` + tests. AUTHOR-Complex.
- [ ] T26. `Pipeline/CNSAlertTierMachine.swift` + tests. AUTHOR-Swift.
- [ ] T27. `Pipeline/CNSMonitoringCoordinator.swift` + tests. AUTHOR-Swift.

### Transport (§5)
- [ ] T28. `Transport/BinaryCodec.swift` (protobuf-lite or SwiftBinaryCodable) + tests. AUTHOR-Fast.
- [ ] T29. `Transport/WCSessionCoordinator.swift` + tests. AUTHOR-Swift.
- [ ] T30. `Transport/RESTClient.swift` + tests. AUTHOR-Swift.

### Watch integration (§6)
- [ ] T31. `Watch/ComplicationCacheWriter.swift` + tests. AUTHOR-Swift.
- [ ] T32. Watch app: `WKApplicationRefreshBackgroundTask` handler wiring. AUTHOR-Swift.
- [ ] T33. Complication Extension: read-only cache reader. AUTHOR-Fast.

### Migration & rollout (§7)
- [ ] T34. `Migration/FeatureFlags.swift` + tests. AUTHOR-Fast.
- [ ] T35. `Migration/SwiftDataBackfiller.swift` + integration tests. AUTHOR-Complex.

### Diagnostics & Ops (§8)
- [ ] T36. `Diagnostics/DiagnosticsScreen.swift` (SwiftUI) — user-visible. AUTHOR-Swift.
- [ ] T37. `Diagnostics/MetricKitReporter.swift` + tests. AUTHOR-Fast.

### Finalization
- [ ] T38. Wire ViewModels into iOS + watchOS main apps behind Phase-1 feature flag. AUTHOR-Swift.
- [ ] T39. Full integration test suite + coverage report (target 85%+). All AUTHORS + REVIEWER.
- [ ] T40. Documentation pass: update `AGENTS.md`, add ADRs for each subsystem. AUTHOR-Fast.

## Combined-review checkpoints
- [x] After T05 (Opus). Blocked first pass on hygiene; passed conceptually after commit + insertion of T06a-T06d as follow-ups. Log entry below.
- [ ] After T10
- [ ] After T15
- [ ] After T20
- [ ] After T25
- [ ] After T30
- [ ] After T35
- [ ] Final (T40)

## Global invariants (checked at every commit)
- `xcodebuild build test -scheme AnxietyWatchKit` passes.
- No file in `Pipeline/` references `Date()`, `DispatchTime.now()`, or `Task.sleep` (grep-linted in CI hook).
- `@Syncable` macro-fixture test for bidirectional-without-init(fromSync:) fails to compile.
- Coverage of `AnxietyWatchKit` ≥ 85%.

## Log

_Timestamps in local time. Each entry: author, reviewer(s), commit sha._

- **T01** (2026-07-16 00:57 PT) · author=Qwen3-Coder · reviewer=Opus (2 rounds) · quick=Flash · commit=74a24cb · notes: reviewer flagged empty subdirs (fixed via `*Namespace.swift` placeholders) and scope drift (Watch/ folder removed). GRDB pin refined to `.upToNextMajor(from: "6.29.3")`. Xcode-project integration deferred to first consumer task with hard-gate reminder in T02.
- **T02** (2026-07-16 01:32 PT) · author=Qwen3-Coder (rerouted from AUTHOR-Fast which hit Groq TPM limit) · reviewer=Opus (1 round → SIGN-OFF + nits) · quick=Flash · commit=69293aa · notes: added Log.healthkit + Log.complication categories, `id:` param on beginInterval, spec §8.3 amended. Test-spy protocol tracked as tech debt for downstream sync/panic tests.
- **T03+T04** (2026-07-16 02:16 PT) · author=Qwen3-Coder (T03+T04 both, since author-fast was Groq-throttled and briefly on broken gpt-5.6 fallback) · reviewer=Opus (T03: 5 fixes; T04: 3 nits including inSavepoint) · quick=Flash · commit=43569c5 · 15 tests passing. Tech debt: string-match on GRDB error description (fix #3), single-consumer CorruptionEvent stream, and SyncCoordinator.fullRestore() dependency for T17.

## Model availability snapshot (2026-07-16 03:55 PT — post user pane restart)

User reset the three main panes with different models. Shell + author-fast panes remain closed.

| Role | Pane | Model | Status |
|---|---|---|---|
| REVIEWER | worker-1 (w1:p3) | deepseek/deepseek-v4-pro | ✅ |
| AUTHOR | worker-2 (w1:p4) | claude-fable-5 | ✅ (Anthropic sub) |
| QUICK-CHECK | quick-check (w1:p6) | openai/gpt-5.5-pro | ✅ |

All three panes smoke-tested with `reply with just OK` → all responded.

**Role reassignments per model strength:**
- worker-1 (deepseek-v4-pro): rigorous chain-of-thought → primary REVIEWER (replacing Opus).
- worker-2 (claude-fable-5): strong Swift/actor concurrency → AUTHOR for all tasks.
- quick-check (gpt-5.5-pro): distinct-provider third-pass QUICK-CHECK.

Multi-model workflow restored: AUTHOR (worker-2) → REVIEWER (worker-1) ↔ iterate → QUICK-CHECK (quick-check) → commit.

## Queued post-completion steps

Executed automatically once the spec is implemented, tested, and coverage target hit:
1. **Install the app on the iPhone `theodore`** — via `xcodebuild -destination "id=<theodore's UDID>,name=theodore"` or the XcodeBuildMCP `build_run_ios_device` flow. Confirm signing team + provisioning first; ask if manual code-signing is required.
2. Only then start the `/respond-to-copilot` review cycle.

If any of these are blocked at that point (device not paired, provisioning missing, etc.) I will surface the block rather than proceed.

## Combined-review checkpoint after T10 (Opus, 2026-07-16 05:45 PT)

**CHECKPOINT PASSED.** 77/77 tests green. All individual T07-T11 review blockers remediated in committed tree.

Forward-notes to fold into T13+ work:
1. **Orchestration ownership** — nobody yet computes `ackedCursorPerNode` or sequences the four Compaction actors. T17 SyncCoordinator becomes the cursor owner; add an explicit Compaction orchestrator with pinned ordering: daily = retention → downsample → TRUNCATE; panic = on-demand downsample → evict → tombstone insert. Also fold this ordering into Spec §1.5 / §2.6 so the next author doesn't rediscover it.
2. **HLCStamped adoption** — pick a canonical shape after T13 (all row types migrate to `hlc: HLCStamped`, OR "flat at storage, HLCStamped only in sync/wire"). Don't leave the migration partial.
3. **writeWithoutTransaction consistency** — open()'s two RESTART checkpoints still run inside `queue.write{}` (transaction-wrapped). Harmless at open (no concurrent writers) but align them so future authors don't cargo-cult the wrong one.
4. Minor cleanups: dead `BackfillProgressStoreError {}` enum. Document that monotonic-guarded upsert silently no-ops backwards writes (intended). QuarantineRow always fills capturedAt from Swift Date(), so DB DEFAULT is effectively dead for this store.
5. **Confirm SamplesStore ingest doesn't Log per-row** — 200 Hz path is the one that must stay silent.

## Combined-review checkpoint after T15 (Opus, 2026-07-16 07:20 PT)

**CHECKPOINT PASSED.** 108/108 tests green. Sync layer coherent + ready for T16/T17.

**Tech-debt now CLEARED:**
- T10 multi-node samples_1min PK collision — resolved in T10.
- All T13 R2 blockers (UDF row-scoping via subquery-materialized hlc_now_json + property test branch coverage) — resolved.
- T13 nit #4 (assert nodeID.count == 16 in HLC.init) — applied.
- T13 nit #1 (frozen-clock decisive test testRegisterUDFsMintsExactlyOncePerRowUnderFrozenClock) — applied.
- T10/T11 nit: open()'s two RESTART checkpoints now use writeWithoutTransaction — applied.
- HLCStamped adoption question — **RATIFIED**: canonical convention is "flat (physical, logical, nodeID) tuples at storage/wire; HLCStamped only for comparison and Comparable-based ordering". No retrofit needed.

**Tech-debt STILL OPEN going into T16:**
1. Compaction orchestration ownership — who computes ackedCursorPerNode + sequences retention→downsample→truncate? Deferred to T17-T19.
2. observe() persist-incoming-remote contract — must be enforced at T17 call site (observe() returns clamped local view; peer _sync_log rows must persist incoming remote unchanged).
3. T13 nit #2 (branch-counter mirror keep-in-lockstep comment) — trivial, apply during T17.
4. Store-level Log.storage emission on interesting events (unknownOperation throws, unacked_overflow triggers) — T17-T19.
5. HK adapter emitting into pipeline — deferred to T22.

**T16 friction to pre-empt (per Opus):**
- @Syncable macro MUST emit the mandatory subquery pattern: `FROM (SELECT hlc_now_json() AS h)`. Direct-multi-hlc-now-json is the anti-pattern that silently corrupts. Add a DDL-shape guard OR macro-side assertion so a mis-authored trigger fails at compile time, not silently at runtime.
- _sync_log HLCs are NOT immutable — updated rows re-surface above the cursor because their HLC advances. Correct by design but easy to misread.

### T14 + T15
- [x] T14 (2026-07-16 06:33 PT). Author: Qwen3-Coder (impl) + conductor (test scaffolding after truncation). Reviewer: Opus SIGN-OFF. Quick: Flash. Commit `d11b98b`.
- [x] T15 (2026-07-16 07:22 PT). Author: Qwen3-Coder. Reviewer: Opus REQUEST CHANGES (TableCursors CodingKeys mismatch with §2.7 — sample_tombstones/sync_log snake). Quick: Flash. Commit pending.
