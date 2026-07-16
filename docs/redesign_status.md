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
- [ ] T06c. `Storage/SampleTombstonesStore.swift`. Mirror of SamplesStore. AUTHOR-Swift.
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
