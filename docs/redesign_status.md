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
- [~] T01. Create `AnxietyWatchKit` SPM-inside-Xcode framework target (iOS + watchOS). Wire it into the existing `AnxietyWatch.xcodeproj`. Initial folder skeleton per Spec §0. Add empty `AnxietyWatchKit.swift` public umbrella. AUTHOR-Swift, REVIEWER Opus. — pending
- [ ] T02. `Diagnostics/Logger.swift` + `Diagnostics/Signpost.swift` — OSLog subsystems for every module. AUTHOR-Fast.
- [ ] T03. `Storage/DatabaseManager.swift` skeleton — open/close, PRAGMAs, corruption circuit breaker interface (no schema yet). AUTHOR-Swift + REVIEWER Opus.

### Storage (§1)
- [ ] T04. `Storage/Schema/SchemaV1.swift` — full DDL for samples, sample_tombstones, samples_1min, _sync_log, _backfill_progress, _sync_quarantine. AUTHOR-Fast (schemas are its sweet spot).
- [ ] T05. `Storage/SamplesStore.swift` + tests. Includes HK-boundary trap. AUTHOR-Swift.
- [ ] T06. `Storage/SyncLogStore.swift` + tests. AUTHOR-Fast.
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
- [ ] After T05
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
