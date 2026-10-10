# Final Redesign v3 Work Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the remaining AnxietyWatch redesign v3 work through independently testable storage, connectivity, sync, diagnostics, rollout, and retirement phases. The recovered documentation and compiler-repair branches have already merged; the unrelated AnxietyWatch2 branch remains quarantined and must never be merged into this project.

**Architecture:** OpenSpec is the behavioral source of truth. This file is the operational entry point: it records the current branches/worktrees, safe merge order, future branch boundaries, concrete files, verification gates, and definition of done. Each implementation phase starts from an updated `main`, ships as its own PR, and leaves legacy behavior available until the replacement phase has parity and rollback evidence.

**Tech Stack:** Swift 6.x, SwiftUI, SwiftData, GRDB/system SQLite, HealthKit, CoreBluetooth, WatchConnectivity, WidgetKit, MetricKit, Flask, PostgreSQL, Alembic, pytest, OpenSpec 1.14.1.

**Spec:** `openspec/changes/complete-redesign-v3-migration/design.md`, its seven delta specs, and the canonical specs under `openspec/specs/`.

## Global Constraints

- Never commit or push directly to `main`; every implementation phase uses a fresh feature branch from updated `main`.
- Stage files by explicit path. Never use `git add .` or `git add -A`.
- Use `git pull --rebase`, not a merge pull. Never use `git reset --hard` or discard an uncommitted worktree.
- HealthKit remains the source of truth for HealthKit-owned physiology. The self-hosted server is a mirror, not the only copy.
- Every table that syncs up must have server persistence and a tested restore/down path before production enablement.
- A compiled type, passing unit tests, app wiring, and production authority are four distinct statuses.
- Exactly one effective `WCSession.default.delegate` may exist in each process.
- The app-level `Services/CNSRisk` engine remains authoritative for clinical alert decisions. The package pipeline may supply monitoring/presentation state but must not duplicate notifications, haptics, or watch messages.
- Invalid and indeterminate physiological data contributes nothing and is never treated as safe.
- Fresh-install, restore, authorization, migration, and corruption flows require tests that begin from a genuinely empty installation/store.
- No new third-party remote-config dependency is introduced. Phase controls use bundled safe defaults plus an injectable local provider; TestFlight/build cohorts gate rollout until a separately specified self-hosted control is justified.
- All new or changed code lands with focused tests, zero compiler warnings, and updated OpenSpec implementation notes.
- Before pushing substantive Swift work, run `swift-pre-pr-reviewer`. Add `medical-data-accuracy-reviewer` for HealthKit, Polar, EMAY, SpO2, ingestion, arbitration, restore, or CNS data-path changes. Add `swiftui-render-pitfall-detector` for SwiftUI/SwiftData render changes.
- The repository is public: use fictional test data and do not commit personal paths, credentials, health records, screenshots, captures, or tool/session artifacts.

## Review Focus

- **First launch writes before restore selection:** an incidental row must not make an empty replacement device look non-empty; Task 7 adds a fresh-install decision test.
- **Two WatchConnectivity owners:** activation order must not silently replace the package delegate; Tasks 4 and 10 add single-owner startup tests on both targets.
- **Interrupted backfill or rollback:** termination at every batch boundary must neither skip nor duplicate data; Tasks 6 and 7 add resume and reverse-copy tests.
- **Upload without restoration:** every new payload table must restore stable IDs and avoid re-upload; Tasks 5 and 11 add a generated inventory gate and fresh-store round trip.
- **ACK lost after remote commit:** retries must deduplicate while local cursors remain unchanged; Tasks 10 and 11 add lost-ACK transport and server tests.

---

## 1. Authority and Current Snapshot

Read these in order before doing any redesign work:

1. `openspec/PORTFOLIO.md` — priority, scope, origin, benefits, dependencies, and resume context for every active plan.
2. `openspec/changes/complete-redesign-v3-migration/RUNBOOK.md` — redesign-specific branch/worktree and execution runbook.
3. `openspec/README.md` — OpenSpec workflow.
4. `openspec/changes/complete-redesign-v3-migration/proposal.md` — why the remaining change exists.
5. `openspec/changes/complete-redesign-v3-migration/design.md` — architecture, reconciled T01–T40 ledger, historical decisions, and traceability.
6. `openspec/changes/complete-redesign-v3-migration/specs/` — required behavior changes.
7. `openspec/specs/` — current behavior and implementation-status boundaries.

`docs/plans/converted/redesign/redesign_plan.md` and `docs/plans/converted/redesign/redesign_status.md` are historical inputs only. Their stale checkboxes do not override OpenSpec or this runbook. The deleted `docs/redesign_spec.md` remains available through Git history.

### Current branch/worktree state at plan creation

Base commit for `main`, `origin/main`, the documentation branch, and the compiler-repair branch: `7e7bf67`.

| Checkout/worktree | Branch | State | Required action |
|---|---|---|---|
| Primary checkout | `fix/anxietywatch-build-repair` | Uncommitted Swift, tests, watch app, and scheme repairs | Preserve, review, test, commit, push, and merge after the documentation PR |
| `.worktrees/openspec-redesign-v3` | `docs/openspec-redesign-v3` | OpenSpec conversion and this runbook are uncommitted | Validate, commit, push, and merge first |
| Separate T3 checkout | `fix/t3-bound-trends` | Separate work, not part of redesign v3 | Do not modify or remove here |
| Separate T6 checkout | `fix/t6-metrickit` | Separate MetricKit work, potentially relevant later | Do not modify; reconcile only when Task 12 begins |
| Separate trends checkout | `fix/trends-query-bounds` | Separate work | Do not modify or remove here |
| Tool-managed feature worktrees | `feat/ezshare-round-and-tz`, `feat/oura-cloud-scheduled-ingest` | Separate work | Do not modify or remove here |
| Quarantine branch only | `quarantine/anxietywatch2-pi5-vitals-core` | Preserves the unrelated AnxietyWatch2 history | Never merge into AnxietyWatch; retain until manually deemed unnecessary |

The compiler-repair checkout currently owns changes to:

- `AnxietyWatch Watch App/AnxietyWatchApp.swift`
- `AnxietyWatch.xcodeproj/project.pbxproj`
- `AnxietyWatch.xcodeproj/xcshareddata/xcschemes/AnxietyWatch Watch App.xcscheme`
- `AnxietyWatch.xcodeproj/xcshareddata/xcschemes/AnxietyWatchWidgetsExtension.xcscheme`
- `AnxietyWatch/AnxietyWatch.entitlements`
- `AnxietyWatch/Info.plist`
- `AnxietyWatch/Services/CNSMonitoringCoordinator.swift`
- `AnxietyWatch/Services/CNSRisk/CNSAlarmChannelPolicy.swift`
- `AnxietyWatch/Services/CNSRisk/CNSAlarmPresenter.swift`
- `AnxietyWatch/Services/CNSRisk/CNSCriticalAlertPermission.swift` (renamed)
- `AnxietyWatch/Services/CNSRisk/CNSMonitoringConstants.swift`
- `AnxietyWatch/Services/CNSRisk/CNSNotificationPermission.swift` (new name)
- `AnxietyWatch/Services/HRVRecordingActivityAttributes.swift`
- `AnxietyWatch/Services/HealthKitDataSource.swift`
- `AnxietyWatch/Services/LiveActivityCoordinator.swift`
- `AnxietyWatch/Views/Dashboard/HRVSessionCardView.swift`
- `AnxietyWatch/Views/Settings/CNSMonitoringView.swift`
- `AnxietyWatch/Views/Settings/CNSMonitoringViewHelpers.swift`
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Diagnostics/ExportLogs.swift`
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Sync/SyncCoordinator.swift`
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Transport/SyncEngine.swift`
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Transport/WCSessionCoordinator.swift`
- `AnxietyWatchKit/Tests/AnxietyWatchKitTests/CorruptionBroadcasterTests.swift`
- `AnxietyWatchKit/Tests/AnxietyWatchKitTests/DependencyContainerTests.swift`
- `AnxietyWatchKit/Tests/AnxietyWatchKitTests/SamplesStoreTests.swift`
- `AnxietyWatchKit/Tests/AnxietyWatchKitTests/SyncCoordinatorTests.swift`
- `AnxietyWatchKit/Tests/AnxietyWatchKitTests/WCSessionCoordinatorTests.swift`
- `AnxietyWatchTests/CNSAlarmChannelPolicyTests.swift`
- `AnxietyWatchTests/CNSAlarmPresenterTests.swift`
- `AnxietyWatchTests/CNSCriticalAlertPermissionTests.swift` (renamed)
- `AnxietyWatchTests/CNSNotificationPermissionTests.swift` (new name)
- `AnxietyWatchTests/CNSMonitoringViewHelpersTests.swift`

Do not switch the primary checkout to `main` until those files are safely committed or otherwise explicitly preserved.

### Baseline integration update — 2026-10-09

The order below is preserved as the plan created before integration. Execution uncovered one dependency: documentation PR #51 triggered iOS CI, but the old `main` branch did not compile. Repair PR #52 therefore had to merge first. This was a sequencing correction, not a scope merge; the repair and documentation changes remain separate PRs.

- PR #52, `fix/anxietywatch-build-repair`, merged first as `d295cae` after all GitHub checks passed. Local evidence remains 1,548 app tests, 359 package tests, and 534 server tests with clean flake8; the signed device build/install/launch and required specialist reviews also passed.
- CI fixes discovered during integration explicitly select the installed psycopg2 driver for Alembic and migration-parity tests and isolate self-hosted iOS-runner DerivedData by run/attempt. The runner's installation directory is host-local operational context and is not a repository dependency.
- The primary checkout is now clean on repaired `main`. Documentation PR #51 remains the only baseline PR to merge before redesign implementation begins.
- At the project maintainer's request, the repository ruleset no longer requires Copilot code review. Deletion protection, non-fast-forward protection, required signatures, and the existing pull-request policy remain active. The already-used public signing key was registered with GitHub so the repair commits validate without history rewriting; the private key never left the machine.
- After PR #51 merges, remove only `.worktrees/openspec-redesign-v3`, update tasks 1.6 and 1.8 in a small status-only PR, validate OpenSpec strictly, and return the primary checkout to clean updated `main`.
- PR #51 subsequently merged as `fae7eb5`; the clean documentation worktree and its merged local branch were removed, the primary checkout was updated to clean `main`, and `openspec validate --all --strict` passed all 8 items. The status-only baseline-finalization PR records these completed gates.

## 2. Branch and PR Sequence

Use this order. Do not combine the documentation conversion, compiler repairs, and redesign implementation into one PR.

| Order | Branch | Purpose |
|---|---|---|
| PR 1 | `docs/openspec-redesign-v3` | OpenSpec baseline, removal of the stale spec, historical reconciliation, and this runbook |
| PR 2 | `fix/anxietywatch-build-repair` | Existing Swift 6.x/compiler and scheme repairs already present in the primary checkout |
| PR 3 | `codex/redesign-v3-prerequisites` | Single-owner connectivity tests, corruption recovery, restore inventory, and feature-control foundation |
| PR 4 | `codex/redesign-v3-storage` | Phase 2A backfill, rollback exporter, production storage routing, and compaction lifecycle |
| PR 5 | `codex/redesign-v3-watch-transport` | Complication reader, background continuation, single WC owner, binary negotiation and ACKs |
| PR 6 | `codex/redesign-v3-delta-sync` | CRUD materialization, restore symmetry, server shadow compare, tombstone-report honesty |
| PR 7 | `codex/redesign-v3-diagnostics` | Settings diagnostics/export, MetricKit/signposts, memory and operational evidence |
| PR 8 | `codex/redesign-v3-retirement` | Gate-driven legacy removal and OpenSpec archive after rollout evidence exists |

Only PRs 1 and 2 are needed to return the repository to a clean, documented baseline. PRs 3–8 complete the redesign.

## 3. PR 1 — Merge the Documentation/OpenSpec Branch

> Historical baseline section: PR #51 is already merged. Preserve this for incident history; do not rerun these commands as current work.

**Files:**

- Create: `openspec/changes/complete-redesign-v3-migration/RUNBOOK.md` (originally created at `docs/FINAL_REDESIGN_v3_WORK` before plan consolidation)
- Create/update: `openspec/**`
- Modify: `README.md`; historical plan/status inputs now live under `docs/plans/converted/redesign/`
- Remove: `docs/redesign_spec.md`
- Generated integrations: `.agents/skills/openspec-*`, `.github/prompts/opsx-*`, `.github/skills/openspec-*`

- [ ] **Step 3.1: Confirm this worktree owns only documentation and generated OpenSpec integration files**

Run from `.worktrees/openspec-redesign-v3`:

```bash
git status --short --branch
git diff --check
openspec validate --all --strict
```

Expected: branch is `docs/openspec-redesign-v3`; validation reports all specs/change artifacts passing; no Swift source file is modified in this worktree.

- [ ] **Step 3.2: Review the deletion and source-of-truth pointers**

```bash
test ! -e docs/redesign_spec.md
rg -n "Historical input only|complete-redesign-v3-migration|FINAL_REDESIGN_v3_WORK" README.md docs openspec
```

Expected: the old spec is absent; the README, historical docs, OpenSpec design, and this runbook provide navigable pointers.

- [ ] **Step 3.3: Stage only the documentation/OpenSpec files**

```bash
git add README.md openspec .agents/skills .github/prompts .github/skills
git status --short
```

Expected: no Swift, Xcode project, server, screenshot, capture, or unrelated worktree artifact is staged.

- [ ] **Step 3.4: Commit and push the documentation branch**

```bash
git commit -m "docs: make OpenSpec the redesign v3 source of truth"
git push -u origin docs/openspec-redesign-v3
```

Open a PR to `main`. This is documentation/tooling only, so the substantive-Swift pre-PR reviewer is not required.

- [ ] **Step 3.5: Merge PR 1 and remove only its clean worktree**

After GitHub reports the PR merged, run from the primary checkout only after confirming the documentation worktree is clean:

```bash
git -C .worktrees/openspec-redesign-v3 status --short
git worktree remove .worktrees/openspec-redesign-v3
git branch -d docs/openspec-redesign-v3
```

Expected: the docs worktree is removed; all unrelated worktrees remain listed by `git worktree list`.

## 4. PR 2 — Preserve and Merge the Existing Compiler Repairs

**Files:** the compiler-repair paths listed in Section 1.

**Interfaces:**

- Consumes: current Swift 6.x compiler behavior and the already-merged redesign package.
- Produces: a warning-free iOS/watchOS/package baseline from which PR 3 can branch.

- [ ] **Step 4.1: Reconfirm the repair diff before changing it**

```bash
git status --short --branch
git diff -- "AnxietyWatch Watch App/AnxietyWatchApp.swift" AnxietyWatch AnxietyWatchKit AnxietyWatch.xcodeproj
```

Expected: branch is `fix/anxietywatch-build-repair`; the diff contains compatibility/build repairs rather than a new redesign rollout.

- [ ] **Step 4.2: Run focused package tests**

```bash
swift test --package-path AnxietyWatchKit
```

Expected: all XCTest, macro, and Swift Testing cases pass with zero warnings.

- [ ] **Step 4.3: Run Apple-platform tests using XcodeBuildMCP**

Use the `xcodebuildmcp` skill, then call `session_show_defaults` once and `test_sim` with the persisted AnxietyWatch scheme/simulator defaults.

Expected: the iOS/watch-linked suite passes with zero failures and zero warnings.

The Apple developer account and a private-key-backed Apple Development certificate are now available. Debug and Release both use `AnxietyWatch/AnxietyWatch.entitlements` with automatic signing. The repair removes the restricted Critical Alerts entitlement, elevated interruption levels/sounds, and runtime authorization request from the app, and removes elevated interruption levels and Critical Alert payload support from the redundant server APNs channel. Both now use only ordinary alert/sound notifications. Notification readiness fails closed when alerts or sounds are disabled or Scheduled Delivery is enabled, and channel history reports APNs provider acceptance without claiming that the device presented the notification. On 2026-10-09 the app target passed 1,548 tests, the server passed 534 tests with clean flake8, the signed device build succeeded, and the app installed and launched on the connected test iPhone. Physical-device signing/install is no longer a blocker.

Xcode 27 still emits its own `appintentsmetadataprocessor` warning for the app target because the app intentionally does not link AppIntents. Xcode's warning-filter and disable switches were both verified and still emit a warning. Do not add a fake AppIntents dependency solely to hide this toolchain diagnostic; app source/compiler diagnostics remain clean, and the zero-warning gate should continue to reject actionable project diagnostics.

- [ ] **Step 4.4: Run mandatory review agents before push**

Run `swift-pre-pr-reviewer` on the complete unpushed diff. Also run `medical-data-accuracy-reviewer` because the diff touches `HealthKitDataSource`, sync, and physiological-data paths. Resolve every Will Block finding and either resolve or explicitly record every Should Address finding.

- [ ] **Step 4.5: Commit explicit repair files**

```bash
git add "AnxietyWatch Watch App/AnxietyWatchApp.swift" \
  AnxietyWatch.xcodeproj/project.pbxproj \
  "AnxietyWatch.xcodeproj/xcshareddata/xcschemes/AnxietyWatch Watch App.xcscheme" \
  AnxietyWatch.xcodeproj/xcshareddata/xcschemes/AnxietyWatchWidgetsExtension.xcscheme \
  AnxietyWatch/AnxietyWatch.entitlements \
  AnxietyWatch/Info.plist \
  AnxietyWatch/Services/CNSMonitoringCoordinator.swift \
  AnxietyWatch/Services/CNSRisk/CNSAlarmChannelPolicy.swift \
  AnxietyWatch/Services/CNSRisk/CNSAlarmPresenter.swift \
  AnxietyWatch/Services/CNSRisk/CNSCriticalAlertPermission.swift \
  AnxietyWatch/Services/CNSRisk/CNSMonitoringConstants.swift \
  AnxietyWatch/Services/CNSRisk/CNSNotificationPermission.swift \
  AnxietyWatch/Services/HRVRecordingActivityAttributes.swift \
  AnxietyWatch/Services/HealthKitDataSource.swift \
  AnxietyWatch/Services/LiveActivityCoordinator.swift \
  AnxietyWatch/Views/Dashboard/HRVSessionCardView.swift \
  AnxietyWatch/Views/Settings/CNSMonitoringView.swift \
  AnxietyWatch/Views/Settings/CNSMonitoringViewHelpers.swift \
  AnxietyWatchKit/Sources/AnxietyWatchKit/Diagnostics/ExportLogs.swift \
  AnxietyWatchKit/Sources/AnxietyWatchKit/Sync/SyncCoordinator.swift \
  AnxietyWatchKit/Sources/AnxietyWatchKit/Transport/SyncEngine.swift \
  AnxietyWatchKit/Sources/AnxietyWatchKit/Transport/WCSessionCoordinator.swift \
  AnxietyWatchKit/Tests/AnxietyWatchKitTests/CorruptionBroadcasterTests.swift \
  AnxietyWatchKit/Tests/AnxietyWatchKitTests/DependencyContainerTests.swift \
  AnxietyWatchKit/Tests/AnxietyWatchKitTests/SamplesStoreTests.swift \
  AnxietyWatchKit/Tests/AnxietyWatchKitTests/SyncCoordinatorTests.swift \
  AnxietyWatchKit/Tests/AnxietyWatchKitTests/WCSessionCoordinatorTests.swift \
  AnxietyWatchTests/CNSAlarmChannelPolicyTests.swift \
  AnxietyWatchTests/CNSAlarmPresenterTests.swift \
  AnxietyWatchTests/CNSCriticalAlertPermissionTests.swift \
  AnxietyWatchTests/CNSNotificationPermissionTests.swift \
  AnxietyWatchTests/CNSMonitoringViewHelpersTests.swift
git commit -m "fix: restore Swift compiler compatibility"
```

- [ ] **Step 4.6: Rebase on the documentation merge, reverify, and push**

```bash
git pull --rebase origin main
swift test --package-path AnxietyWatchKit
git diff --check origin/main...HEAD
git push -u origin fix/anxietywatch-build-repair
```

Run XcodeBuildMCP `test_sim` again after the rebase. Open and merge PR 2 only after both package and app tests pass.

- [ ] **Step 4.7: Return the primary checkout to clean main**

After PR 2 is merged:

```bash
git status --short
git checkout main
git pull --rebase
git status --short --branch
openspec validate --all --strict
```

Expected: `main` tracks `origin/main`, the worktree is clean, OpenSpec validates, and no redesign implementation branch is active.

## 5. Standard Worktree Pattern for PRs 3–8

Create one redesign worktree at a time from clean, updated `main`. Example for PR 3:

```bash
git checkout main
git pull --rebase
git worktree add .worktrees/redesign-v3-prerequisites -b codex/redesign-v3-prerequisites main
```

Before every push:

```bash
openspec validate --all --strict
git diff --check
git status --short
```

After a PR is merged and its worktree is clean:

```bash
git worktree remove .worktrees/redesign-v3-prerequisites
git branch -d codex/redesign-v3-prerequisites
git checkout main
git pull --rebase
```

Change the branch and worktree names for each later PR. Never remove the unrelated T3, T6, trends, ez Share, or Oura worktrees as part of this plan.

## 6. PR 3 — Ownership, Recovery, Restore Inventory, and Feature Controls

**Branch/worktree:** `codex/redesign-v3-prerequisites` / `.worktrees/redesign-v3-prerequisites`

**Files:**

- Create: `AnxietyWatchKit/Sources/AnxietyWatchKit/Transport/WCSessionDelegateRouter.swift`
- Create: `AnxietyWatchKit/Tests/AnxietyWatchKitTests/WCSessionDelegateRouterTests.swift`
- Create: `AnxietyWatchKit/Sources/AnxietyWatchKit/Storage/CorruptionRecoveryCoordinator.swift`
- Create: `AnxietyWatchKit/Tests/AnxietyWatchKitTests/CorruptionRecoveryCoordinatorTests.swift`
- Create: `AnxietyWatchKit/Sources/AnxietyWatchKit/Sync/RestoreManifest.swift`
- Create: `AnxietyWatchKit/Tests/AnxietyWatchKitTests/RestoreManifestTests.swift`
- Create: `AnxietyWatchKit/Sources/AnxietyWatchKit/Migration/FeatureFlagProvider.swift`
- Create: `AnxietyWatchKit/Tests/AnxietyWatchKitTests/FeatureFlagProviderTests.swift`
- Modify: `AnxietyWatchKit/Sources/AnxietyWatchKit/Diagnostics/DependencyContainer.swift`
- Modify: `AnxietyWatchKit/Sources/AnxietyWatchKit/Feature.swift`
- Modify: `AnxietyWatch/Services/RestoreFromServer.swift`
- Modify: `AnxietyWatch/Services/SyncService.swift`
- Modify: `AnxietyWatch/App/AnxietyWatchApp.swift`
- Modify: `AnxietyWatch Watch App/AnxietyWatchApp.swift`
- Modify: `openspec/changes/complete-redesign-v3-migration/tasks.md`

**Interfaces:**

```swift
public protocol FeatureFlagProvider: Sendable {
    func isEnabled(_ flag: RedesignFeature) async -> Bool
}

public enum RedesignFeature: String, Sendable {
    case pipelineGapEvents
    case sqliteReads
    case wcBinaryFormat
    case deltaSync
}

public struct RestoreEntityDescriptor: Sendable, Equatable {
    public let table: String
    public let uploads: Bool
    public let serverQuery: String?
    public let importerID: String?
}
```

- [ ] **Step 6.1: Pin one-delegate startup behavior with failing tests**

Add tests that construct package and legacy connectivity startup sequences and assert one delegate router remains installed after all services activate.

```swift
@Test func startupKeepsOneEffectiveWCSessionDelegate() async {
    let session = WCSessionStub()
    let router = WCSessionDelegateRouter(session: session)
    await router.activate()
    #expect(session.delegateIdentity == router.delegateIdentity)
}
```

Run the focused test and confirm it fails before the router exists:

```bash
swift test --package-path AnxietyWatchKit --filter WCSessionDelegateRouterTests
```

- [ ] **Step 6.2: Implement the delegate router without changing production ownership yet**

The router must fan callbacks to registered handlers, reject duplicate handler IDs, serialize registration, and expose a test-only owner identity. Do not start it from both targets in this PR; the legacy managers remain authoritative until PR 5 migrates every callback.

- [ ] **Step 6.3: Add a generated restore manifest and failing completeness test**

The test compares every uploaded entity from `SyncService` and package registry with server query/importer descriptors. It must fail with the exact unmatched table names.

```swift
@Test func everyUploadedTableHasServerQueryAndImporter() {
    let missing = RestoreManifest.production.missingRoundTrips
    #expect(missing.isEmpty, "Missing restore paths: \(missing)")
}
```

Initially exempt time-series entities only when HealthKit is the documented rederivation source; app-only EMAY rows are never exempt.

- [ ] **Step 6.4: Implement end-to-end corruption recovery coordination**

Test database close, sidecar replacement, stable node identity, schema recreation, recovery-state publication, restore invocation, and the three-in-24-hours circuit breaker. Use temporary fictional stores only.

- [ ] **Step 6.5: Replace static flag reads with injectable controls**

`Feature` becomes a compatibility facade over `FeatureFlagProvider`. Bundled/default behavior remains false for SQLite reads and delta sync. Every flag read logs only the flag name and boolean value. Add enabled/disabled tests for every production decision point that exists.

- [ ] **Step 6.6: Declare CNS side-effect ownership in code and tests**

Document and test that the app-level `Services/CNSRisk` coordinator owns clinical notifications/haptics. The package pipeline may publish monitoring state but cannot independently fire the same user-facing effect.

- [ ] **Step 6.7: Verify and review PR 3**

Run package tests, XcodeBuildMCP `test_sim`, server tests if the manifest reads server fixtures, OpenSpec strict validation, `swift-pre-pr-reviewer`, and `medical-data-accuracy-reviewer`. Update OpenSpec task/status notes before pushing.

## 7. PR 4 — Phase 2A SQLite Migration and Production Routing

**Branch/worktree:** `codex/redesign-v3-storage` / `.worktrees/redesign-v3-storage`

**Files:**

- Create: `AnxietyWatchKit/Sources/AnxietyWatchKit/Migration/SwiftDataBackfiller.swift`
- Create: `AnxietyWatchKit/Sources/AnxietyWatchKit/Migration/SQLiteRollbackExporter.swift`
- Create: `AnxietyWatchKit/Sources/AnxietyWatchKit/Storage/Compaction/CompactionCoordinator.swift`
- Create: `AnxietyWatchKit/Tests/AnxietyWatchKitTests/SwiftDataBackfillerTests.swift`
- Create: `AnxietyWatchKit/Tests/AnxietyWatchKitTests/SQLiteRollbackExporterTests.swift`
- Create: `AnxietyWatchKit/Tests/AnxietyWatchKitTests/CompactionCoordinatorTests.swift`
- Create: `AnxietyWatch/Services/RedesignStorageMigrationService.swift`
- Create: `AnxietyWatchTests/RedesignStorageMigrationServiceTests.swift`
- Modify: `AnxietyWatch/App/AnxietyWatchApp.swift`
- Modify: `AnxietyWatch/Services/KitPipelineService.swift`
- Modify: `AnxietyWatchKit/Sources/AnxietyWatchKit/Storage/BackfillProgressStore.swift`
- Modify: `AnxietyWatchKit/Sources/AnxietyWatchKit/Storage/DatabaseManager.swift`
- Modify: `AnxietyWatchKit/Sources/AnxietyWatchKit/Storage/SamplesStore.swift`
- Modify: `openspec/changes/complete-redesign-v3-migration/tasks.md`

**Interfaces:**

```swift
public struct BackfillBatchResult: Sendable, Equatable {
    public let inserted: Int
    public let lastTimestamp: Double?
    public let finished: Bool
}

public protocol LegacySampleSource: Sendable {
    func fetchBatch(source: Int, type: Int, after: Double?, limit: Int) async throws -> [LegacySample]
}

public actor CompactionCoordinator {
    public func runOrdinary(now: Date) async throws
    public func runPanicIfNeeded() async throws
}
```

- [ ] **Step 7.1: Write crash-resume backfill tests**

For each transaction boundary—before insert, after insert before progress, after progress, and after commit—simulate termination and restart. Assert exact natural-key equality, no duplicate rows, and monotonic `_backfill_progress`.

- [ ] **Step 7.2: Implement bounded 5,000-row backfill**

Migrate one source/type at a time. Insert rows and update progress in one GRDB transaction. Yield between batches. Never migrate HealthKit-owned data into a state where SQLite becomes its only authoritative copy.

- [ ] **Step 7.3: Write and implement reverse-copy rollback tests**

Create SQLite-only samples after the cutover marker, run the rollback exporter, and assert the legacy store contains the same natural keys and values before the SQLite flag can be disabled.

- [ ] **Step 7.4: Add parity evidence and production read routing**

`RedesignStorageMigrationService` computes counts and deterministic sample hashes by source/type. `storage.sqliteReadsEnabled` may route high-frequency reads only after backfill completion and parity success. A false flag always uses the legacy reader.

- [ ] **Step 7.5: Add the compaction coordinator**

Ordinary order is retention → eligible downsampling → safe checkpoint. Panic order is synchronous downsampling → transactional tombstone and eviction. Concurrent triggers coalesce behind the actor.

- [ ] **Step 7.6: Add fresh-install and first-write guards**

Start an empty app store with server and HealthKit history fixtures. Assert restore/backfill choice occurs before snapshots or other incidental writes can make the store appear populated.

- [ ] **Step 7.7: Keep Phase 2A disabled in production defaults**

Land the complete path and tests with `storage.sqliteReadsEnabled == false`. Record implementation complete, app wiring complete, rollout pending in OpenSpec.

- [ ] **Step 7.8: Verify and review PR 4**

Run package tests, fresh-install app tests via XcodeBuildMCP, server restore tests, `swift-pre-pr-reviewer`, `medical-data-accuracy-reviewer`, and the first-run input-shape tests required by project policy.

## 8. PR 5 — Watch Runtime, Complication Reader, and Binary Transport

**Branch/worktree:** `codex/redesign-v3-watch-transport` / `.worktrees/redesign-v3-watch-transport`

**Files:**

- Create: `AnxietyWatchWidgets/ComplicationCacheReader.swift`
- Create: `AnxietyWatchTests/ComplicationCacheReaderTests.swift`
- Create: `AnxietyWatch Watch App/BackgroundSyncCoordinator.swift`
- Create: `AnxietyWatchKit/Tests/AnxietyWatchKitTests/SyncEngineAcknowledgementTests.swift`
- Modify: `AnxietyWatchWidgets/AnxietyWatchWidgets.swift`
- Modify: `AnxietyWatch Watch App/AnxietyWatchApp.swift`
- Modify: `AnxietyWatch Watch App/WatchConnectivityManager.swift`
- Modify: `AnxietyWatch/Services/PhoneConnectivityManager.swift`
- Modify: `AnxietyWatch/App/AnxietyWatchApp.swift`
- Modify: `AnxietyWatchKit/Sources/AnxietyWatchKit/Transport/WCSessionDelegateRouter.swift`
- Modify: `AnxietyWatchKit/Sources/AnxietyWatchKit/Transport/WCSessionCoordinator.swift`
- Modify: `AnxietyWatchKit/Sources/AnxietyWatchKit/Transport/SyncEngine.swift`
- Modify: `AnxietyWatchKit/Sources/AnxietyWatchKit/Transport/SyncMessageCodec.swift`
- Modify: `openspec/changes/complete-redesign-v3-migration/tasks.md`

**Interfaces:**

```swift
public struct ComplicationCacheSnapshot: Sendable, Equatable {
    public let state: ComplicationState?
    public let freshness: Freshness
}

public struct TransferAcknowledgement: Codable, Sendable, Equatable {
    public let transferID: UUID
    public let committedCursor: TableCursors
}
```

- [ ] **Step 8.1: Add missing/malformed/stale complication cache tests**

The reader returns unavailable or stale state without crashing, opening SQLite, or querying live sensors. Test atomic replacement while a read occurs.

- [ ] **Step 8.2: Implement and wire the read-only cache reader**

Read only `complication.plist` from the shared app group. Decode a stable versioned envelope and expose freshness to the widget timeline.

- [ ] **Step 8.3: Add watch background continuation tests**

Simulate refresh enqueue, expiration, later background URL-session callback, valid ACK, invalid ACK, and no ACK. No cursor advances before a valid acknowledgment.

- [ ] **Step 8.4: Inventory and migrate every legacy WCSession callback**

Cover activation, application context, messages with and without replies, user info, files, reachability, watch state, inactive/deactivate, and error callbacks. Register legacy handlers behind `WCSessionDelegateRouter` before changing the sole delegate owner.

- [ ] **Step 8.5: Switch both targets to one delegate router**

Remove direct delegate assignment from legacy managers. Startup creates one router, registers handlers, then activates once. Tests assert later services cannot overwrite ownership.

- [ ] **Step 8.6: Add binary negotiation, fallback, and stable IDs**

Peers advertise supported versions. Incompatible peers use legacy JSON. Immediate-alert and queued fallback share an alert ID. Historical files retain a transfer ID and source file until durable ingest ACK.

- [ ] **Step 8.7: Test lost ACK and out-of-order files**

If the receiver commits then crashes before reply, retry deduplicates by natural keys and transfer ID. Out-of-order files converge to the same rows and cursors.

- [ ] **Step 8.8: Roll out with binary flag still false**

Merge single-owner routing and compatibility first. Enable binary only in a later reviewed TestFlight/build cohort after legacy fallback evidence is captured.

- [ ] **Step 8.9: Verify and review PR 5**

Run package and app/watch tests, both schemes through XcodeBuildMCP, `swift-pre-pr-reviewer`, and `medical-data-accuracy-reviewer` for physiological payload mapping.

## 9. PR 6 — Phase 2C Delta Sync, Restore Symmetry, and Server Shadowing

**Branch/worktree:** `codex/redesign-v3-delta-sync` / `.worktrees/redesign-v3-delta-sync`

**Files:**

- Create: `AnxietyWatchKit/Sources/AnxietyWatchKit/Sync/CRUDMaterializer.swift`
- Create: `AnxietyWatchKit/Tests/AnxietyWatchKitTests/CRUDMaterializerTests.swift`
- Create: `AnxietyWatchKit/Tests/AnxietyWatchKitTests/DeltaRoundTripTests.swift`
- Create: `server/tests/test_delta_sync.py`
- Modify: `AnxietyWatchKit/Sources/AnxietyWatchKit/Sync/SyncCoordinator.swift`
- Modify: `AnxietyWatchKit/Sources/AnxietyWatchKit/Sync/SyncRegistry.swift`
- Modify: `AnxietyWatchKit/Sources/AnxietyWatchKit/Sync/RESTClient.swift`
- Modify: `AnxietyWatch/Services/RestoreFromServer.swift`
- Modify: `AnxietyWatch/Services/SyncService.swift`
- Modify: `server/delta_oura_patch.py`
- Modify: `server/schema.sql`
- Add an Alembic migration only if the reconciled schema test demonstrates a schema change is required
- Modify: `openspec/changes/complete-redesign-v3-migration/tasks.md`

**Interfaces:**

```swift
public protocol SyncEntityMaterializer: Sendable {
    static var tableName: String { get }
    func apply(_ change: SyncChange, preserving stamp: HLCTimestamp) async throws
}

public struct ShadowComparison: Codable, Sendable, Equatable {
    public let table: String
    public let nodeID: Data
    public let rowsEqual: Bool
    public let cursorEqual: Bool
}
```

- [ ] **Step 9.1: Add LWW CRUD materialization tests**

Test winning remote upsert, losing remote upsert, delete, unknown table, malformed payload, preserved incoming stamp, and local HLC observation. A losing row must not clear or overwrite newer local state.

- [ ] **Step 9.2: Implement registered CRUD materialization**

Resolve each `_sync_log` row through `SyncRegistry`. Apply in bounded transactions. Preserve the incoming remote HLC on replicated data while allowing the local clock to observe it.

- [ ] **Step 9.3: Add complete device-loss round-trip tests**

Upload every registered entity to a temporary server database, create a fresh empty client store, restore, and compare stable IDs, values, source discriminators, `syncedToServer`, and next-upload emptiness.

- [ ] **Step 9.4: Finish scheduling and background retry**

Foreground, timer, path-restored, and background triggers serialize through one coordinator. Concurrent triggers coalesce. A killed attempt leaves cursors and GC unchanged.

- [ ] **Step 9.5: Add server tombstone propagation tests**

Push a tombstone, pull from another node, and assert identical range/reason/count/HLC. Aggregate/report endpoints must disclose incomplete coverage rather than interpolate the interval.

- [ ] **Step 9.6: Add semantic shadow comparison**

For each pull, compare normalized legacy and delta row sets plus per-node cursors. Record table/node and counts, never health payload values. Any divergence keeps delta disabled.

- [ ] **Step 9.7: Exercise cursor-version fallback**

An unsupported cursor version returns 409; the client keeps cursors unchanged and uses legacy REST. Test server commit followed by lost response and deduplicated retry.

- [ ] **Step 9.8: Keep `sync.deltaEnabled` false after merge**

Code completion is not production enablement. Start the two-week shadow period only after deployment, then require 30 divergence-free days, P95 below two seconds, and working tombstone round trips.

- [ ] **Step 9.9: Verify and review PR 6**

Run `swift test --package-path AnxietyWatchKit`, XcodeBuildMCP `test_sim`, `cd server && python -m pytest tests/`, server flake8, `swift-pre-pr-reviewer`, and `medical-data-accuracy-reviewer`.

## 10. PR 7 — Diagnostics, MetricKit, Signposts, and Release Evidence

**Branch/worktree:** `codex/redesign-v3-diagnostics` / `.worktrees/redesign-v3-diagnostics`

Before editing, inspect `fix/t6-metrickit` and its PR state. Reuse merged work or transplant reviewed commits; do not independently recreate or overwrite it.

**Files:**

- Create or reconcile: `AnxietyWatchKit/Sources/AnxietyWatchKit/Diagnostics/MetricKitReporter.swift`
- Create or reconcile: `AnxietyWatchKit/Tests/AnxietyWatchKitTests/MetricKitReporterTests.swift`
- Create: `AnxietyWatchTests/DiagnosticsNavigationTests.swift`
- Modify: `AnxietyWatchKit/Sources/AnxietyWatchKit/Diagnostics/DiagnosticsView.swift`
- Modify: `AnxietyWatchKit/Sources/AnxietyWatchKit/Diagnostics/ExportLogs.swift`
- Modify: `AnxietyWatchKit/Sources/AnxietyWatchKit/Diagnostics/Signpost.swift`
- Modify: `AnxietyWatch/Views/Settings/SettingsView.swift`
- Modify: `AnxietyWatch/Views/Settings/SyncSettingsView.swift`
- Modify: storage/sync/transport call sites missing required signposts
- Modify: `openspec/changes/complete-redesign-v3-migration/tasks.md`

- [ ] **Step 10.1: Add live diagnostics snapshot tests**

Provide actor-backed storage, sync, clock, transport, gap, and flag fixtures. Assert the view model creates one timestamped snapshot and labels unavailable providers instead of blocking a SwiftUI read.

- [ ] **Step 10.2: Wire Settings navigation and export**

Settings opens `DiagnosticsView`. Export creates a bounded redacted archive, invokes the share flow, and removes expired temporary bundles. Tests inspect archive entries for tokens, emails, identifiers, and raw physiological rows.

- [ ] **Step 10.3: Reconcile and register MetricKit reporting**

Use any already-reviewed T6 implementation as the starting point. Record aggregate memory/runtime/energy measures with non-identifying dimensions. Never log raw payload descriptions.

- [ ] **Step 10.4: Complete signpost coverage**

Add matched intervals around BLE parsing, SQLite batches, sync pull/push, file transfers, and watch refresh lifecycle. Tests or a checked Instruments trace must prove start/end pairing.

- [ ] **Step 10.5: Add sustained memory test harness**

Replay ten simulated minutes of 200 Hz observations and measure peak memory. The automated pre-merge gate is less than 15 MB over baseline; field rollout gate is P95 below 50 MB on supported watch generations.

- [ ] **Step 10.6: Capture release evidence without personal data**

Record battery drain, urgent-alert latency, overflow rate, corruption count, cursor divergence, and clock-suspect rate as aggregate results in OpenSpec implementation notes. Do not commit screenshots or device captures.

- [ ] **Step 10.7: Verify and review PR 7**

Run package and app tests, XcodeBuildMCP `test_sim`, targeted real-device memory testing when hardware is available, `swift-pre-pr-reviewer`, and `swiftui-render-pitfall-detector` for diagnostics views.

## 11. PR 8 — Gate-Driven Enablement, Legacy Retirement, and OpenSpec Archive

**Branch/worktree:** `codex/redesign-v3-retirement` / `.worktrees/redesign-v3-retirement`

This PR cannot begin merely because PRs 3–7 merged. It begins after rollout evidence satisfies each independent gate.

- [ ] **Step 11.1: Record Phase 2A rollout evidence**

Required: fresh-install restore, backfill parity, rollback reverse-copy, corruption recovery, compaction, and a monitored cohort with SQLite reads enabled. If any gate fails, keep legacy SwiftData reads.

- [ ] **Step 11.2: Record Phase 2B rollout evidence**

Required: one delegate owner on both targets, compatible-version negotiation, legacy fallback, durable ACKs, lost-ACK deduplication, and monitored binary cohort. If any gate fails, keep legacy JSON.

- [ ] **Step 11.3: Record Phase 2C rollout evidence**

Required: two weeks shadow service, 30 days zero cursor divergence, P95 pull below two seconds, tombstone round trip, complete restore inventory, and 30 days at 99% flag-on adoption before legacy REST removal.

- [ ] **Step 11.4: Remove only proven-obsolete paths**

Delete legacy code one subsystem at a time with tests proving replacement behavior. Do not remove HealthKit rederivation, rollback data, or REST endpoints needed by supported older clients.

- [ ] **Step 11.5: Update all final documentation in the same PR**

Mark every OpenSpec task, add PR/commit links and scope deviations, update architecture docs, and retain the original history in Git. The reconciled historical inputs remain under `docs/plans/converted/redesign/`; they do not override OpenSpec.

- [ ] **Step 11.6: Archive the OpenSpec change**

After strict validation and review:

```bash
openspec validate --all --strict
openspec status --change complete-redesign-v3-migration
```

Use the project-local OpenSpec archive workflow so accepted deltas update canonical specs. Validate again after archive.

- [ ] **Step 11.7: Run final whole-branch reviews and tests**

Run `swift-pre-pr-reviewer`, relevant specialized reviewers, full package/app/watch/server tests, fresh-install restore, device-loss round trip, corruption injection, memory budget, and zero-warning builds. Merge only with no Will Block findings.

## 12. Status Update Protocol

After every merged PR:

1. Update `openspec/changes/complete-redesign-v3-migration/tasks.md` checkboxes.
2. Add an `Implementation notes` entry with PR number, commit, shipped scope, tests, rollout state, deviations, and deferred work.
3. Update the affected canonical spec's implementation-status label only when the status actually changes.
4. Run `openspec validate --all --strict`.
5. Rebase the next phase from updated `main`; never stack long-lived redesign branches on stale bases.

Use this status vocabulary exactly:

- **Implemented:** source exists.
- **Tested:** focused automated evidence passes.
- **Wired:** an app/server production path invokes it.
- **Canary:** enabled only for a controlled build/cohort.
- **Authoritative:** production path owns behavior and rollback was validated.
- **Retired:** legacy path removed after stability/adoption gates.

## 13. Definition of Done

Redesign v3 is complete only when all statements below are true:

- [ ] Primary checkout is clean on updated `main`; no redesign or compiler-repair work exists only as an uncommitted worktree.
- [ ] OpenSpec proposal, specs, design, tasks, implementation notes, and archive state validate strictly.
- [ ] Package and app-level CNS responsibilities are explicit and do not duplicate clinical side effects.
- [ ] SQLite migration resumes after interruption, proves parity, supports rollback, and passes genuinely fresh-install recovery.
- [ ] Corruption recovery preserves node identity, restores all recoverable data, and stops retry thrash after three events in 24 hours.
- [ ] Every sync-up table has server persistence and a tested restore/down path with stable IDs and no re-upload loop.
- [ ] iPhone and watch each have one effective WCSession delegate owner.
- [ ] Binary transfer negotiates versions, falls back, survives lost ACKs, and does not advance cursors early.
- [ ] Delta sync completes its shadow and adoption gates with zero cursor divergence and propagated tombstones.
- [ ] Diagnostics and redacted export are reachable from Settings; MetricKit/signposts and release metrics are operational.
- [ ] Watch memory, battery, alert-latency, overflow, and corruption gates meet the thresholds in the canonical specs.
- [ ] Legacy SwiftData, JSON transport, and REST paths are retired only where replacement evidence permits.
- [ ] All Swift, server, and OpenSpec checks pass with zero warnings or failures, and required reviewers have no blocking findings.

## 14. Immediate Next Action

Merge the status-only baseline-finalization PR, return the primary checkout to clean updated `main`, and begin PR 3 from a new `codex/redesign-v3-prerequisites` worktree. PR 3 starts with tasks 2.1–2.6: delegate ownership tests, restore-manifest completeness, corruption recovery, injectable feature controls, and explicit CNS side-effect ownership. Do not combine later storage, transport, sync, or diagnostics phases into that prerequisites PR.
