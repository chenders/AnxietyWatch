# Tasks

Detailed file ownership, branch/worktree commands, interfaces, test cases, rollout gates, and the definition of done are in `docs/FINAL_REDESIGN_v3_WORK`. This checklist is the OpenSpec progress tracker; update it and implementation notes with every merged PR.

## 1. Documentation and Clean Baseline

- [x] 1.1 Bootstrap OpenSpec 1.14.1 with project context/rules and verify `openspec doctor` succeeds
- [x] 1.2 Create seven canonical capability specs and seven remaining-work deltas and verify `openspec validate --all --strict` reports zero failures
- [x] 1.3 Reconcile T01–T40 plus T06a–T06d against source/tests and map all 23 legacy-spec sections in `design.md`
- [x] 1.4 Remove `docs/redesign_spec.md`, mark the old plan/status historical, and verify all material requirements remain traceable through OpenSpec and Git history
- [x] 1.5 Create `docs/FINAL_REDESIGN_v3_WORK` with public-safe branch/worktree state, PR order, concrete files, tests, reviewers, rollout gates, and definition of done
- [ ] 1.6 Commit, push, review, and merge `docs/openspec-redesign-v3`; verify the documentation worktree is clean before removing only that worktree
- [ ] 1.7 Review, test, commit, rebase, push, and merge `fix/anxietywatch-build-repair`; verify package and XcodeBuildMCP suites pass with zero warnings, Debug builds/install/launch on the connected test iPhone after Xcode signing is configured, and required reviewers have no blocking findings
  - 2026-10-09: removed all elevated notification capabilities and runtime requests from both the app and redundant server APNs channel in favor of standard alert/sound notifications; notification readiness now fails closed for disabled alerts/sounds or scheduled delivery, and channel history reports APNs acceptance without claiming device presentation. 1,548 app tests and 534 server tests pass, with clean server lint. Automatic signing now builds successfully, and the app installs and launches on the connected test iPhone.
  - Xcode 27 still emits its own `appintentsmetadataprocessor` warning for the app target because the app intentionally does not link AppIntents. Xcode's warning-filter and disable switches were verified but still emit a warning; do not add a fake AppIntents dependency solely to silence this toolchain diagnostic. App source/compiler diagnostics remain clean.
- [ ] 1.8 Return the primary checkout to updated `main` and verify `git status --short` is empty and `openspec validate --all --strict` passes

## 2. Ownership, Recovery, and Controls

- [ ] 2.1 Add `WCSessionDelegateRouter` plus startup ownership tests and verify all service activation leaves one effective delegate per target without changing production ownership yet
- [ ] 2.2 Add `RestoreManifest` and a completeness test that fails with exact names whenever an uploaded table lacks server persistence or a restore importer
- [ ] 2.3 Implement `CorruptionRecoveryCoordinator` and verify DB/sidecar replacement, stable node identity, schema recreation, full restore, recovery UI state, and the three-events-in-24-hours circuit breaker
- [ ] 2.4 Replace static redesign flag access with an injectable provider and verify bundled defaults keep SQLite reads and delta sync disabled while both flag values are tested at each production reader
- [ ] 2.5 Make app-level `Services/CNSRisk` the explicit clinical side-effect owner and verify package monitoring cannot duplicate notifications, haptics, or watch messages
- [ ] 2.6 Run package/app tests, OpenSpec validation, `swift-pre-pr-reviewer`, and `medical-data-accuracy-reviewer`; merge `codex/redesign-v3-prerequisites` only with no blocking findings

## 3. Phase 2A Storage

- [ ] 3.1 Implement bounded transactional `SwiftDataBackfiller` batches and verify termination/restart at every transaction boundary produces no duplicates or omissions
- [ ] 3.2 Implement `SQLiteRollbackExporter` and verify SQLite-only high-frequency rows return to the legacy store before a Phase 2A rollback can disable SQLite
- [ ] 3.3 Add parity counts and deterministic sample hashes, then verify `storage.sqliteReadsEnabled` cannot route reads until backfill and parity both pass
- [ ] 3.4 Implement `CompactionCoordinator` and verify ordinary retention→downsample→checkpoint ordering and panic downsample→transactional tombstone/eviction ordering under concurrent triggers
- [ ] 3.5 Add genuinely fresh-install restore/backfill tests and verify incidental startup writes cannot make an empty store bypass restore
- [ ] 3.6 Merge `codex/redesign-v3-storage` with the production flag still false after package/app/server tests and required Swift/medical reviews pass

## 4. Watch Runtime and Binary Transport

- [ ] 4.1 Add `AnxietyWatchWidgets/ComplicationCacheReader.swift` and verify missing, malformed, stale, and concurrently replaced cache files return safe states without opening SQLite
- [ ] 4.2 Add watch background-session continuation and verify enqueue, expiration, later ACK, invalid ACK, and missing ACK never advance cursors early
- [ ] 4.3 Inventory and migrate all legacy WCSession callbacks behind the router and verify phone/watch startup each retain one delegate owner
- [ ] 4.4 Add binary version negotiation and legacy fallback and verify incompatible peers exchange legacy JSON without loss or duplication
- [ ] 4.5 Add stable alert/transfer IDs and durable ACK handling and verify lost ACKs and out-of-order files deduplicate while source files/cursors remain pending
- [ ] 4.6 Merge `codex/redesign-v3-watch-transport` with binary format defaulting off after package/app/watch tests and required reviews pass

## 5. Phase 2C Delta Sync

- [ ] 5.1 Implement registered low-frequency CRUD materialization and verify winning/losing LWW upserts, deletes, malformed/unknown rows, preserved remote HLC, and local clock observation
- [ ] 5.2 Serialize foreground, timer, path-restored, and background sync triggers and verify concurrent triggers coalesce and killed attempts leave ACK/GC state unchanged
- [ ] 5.3 Add a complete device-loss round trip for every registered table and verify stable IDs, source discriminators, `syncedToServer`, restore guards, paging, and no re-upload loop
- [ ] 5.4 Add server tombstone propagation/reporting tests and verify peer pulls preserve gaps while aggregate endpoints disclose incomplete coverage
- [ ] 5.5 Add privacy-safe semantic shadow comparison and verify any row/cursor divergence identifies only table/node metadata and keeps delta disabled
- [ ] 5.6 Verify cursor-version 409 fallback and server-commit/lost-response retry do not advance local cursors or duplicate server rows
- [ ] 5.7 Merge `codex/redesign-v3-delta-sync` with delta defaulting off after Swift, XcodeBuildMCP, pytest, flake8, OpenSpec, and required reviews pass

## 6. Diagnostics and Release Evidence

- [ ] 6.1 Reconcile any merged work from `fix/t6-metrickit` before editing and verify no reviewed MetricKit implementation is duplicated or overwritten
- [ ] 6.2 Wire Settings to actor-snapshot diagnostics and verify available and unavailable providers render without awaited actor access in SwiftUI body evaluation
- [ ] 6.3 Wire redacted bounded export/share and verify archives contain no tokens, emails, identifiers, or raw physiological rows and expired temporary files are removed
- [ ] 6.4 Register MetricKit reporting and verify only aggregate memory/runtime/energy dimensions are recorded
- [ ] 6.5 Complete matched signposts for BLE parse, SQLite batches, sync, file transfer, and watch refresh and verify start/end pairing
- [ ] 6.6 Add the ten-minute 200 Hz memory harness and verify pre-merge peak stays below baseline plus 15 MB; record field P95, battery, latency, overflow, corruption, and divergence evidence without personal data
- [ ] 6.7 Merge `codex/redesign-v3-diagnostics` after package/app/watch tests, Swift review, and SwiftUI render-pitfall review pass

## 7. Rollout and Retirement

- [ ] 7.1 Enable Phase 2A only for a controlled cohort and verify fresh install, parity, rollback, corruption, compaction, and monitored reads before declaring SQLite authoritative
- [ ] 7.2 Enable Phase 2B only for a controlled cohort and verify one delegate owner, negotiation, fallback, durable ACKs, and lost-ACK deduplication before declaring binary transport authoritative
- [ ] 7.3 Run Phase 2C shadow service for at least two weeks and verify 30 divergence-free days, P95 pull below two seconds, complete tombstone round trips, and restore inventory before enabling delta sync
- [ ] 7.4 Retain legacy REST until 99 percent flag-on adoption remains stable for 30 days and verify supported older clients still restore/sync before removal
- [ ] 7.5 Remove legacy SwiftData, JSON, and REST paths only subsystem-by-subsystem with replacement tests and rollback evidence

## 8. Finalization

- [ ] 8.1 Update OpenSpec implementation notes with every PR/commit, test evidence, rollout state, scope deviation, and deferred item and verify strict validation after each merge
- [ ] 8.2 Run final package, app, watch, server, fresh-install, device-loss, corruption, memory, and zero-warning gates plus all required reviewers
- [ ] 8.3 Merge `codex/redesign-v3-retirement`, archive `complete-redesign-v3-migration`, and verify canonical specs contain the accepted deltas with `openspec validate --all --strict`
- [ ] 8.4 Return the primary checkout to clean updated `main` and verify no required redesign work exists only in an uncommitted branch or worktree

## Workflow follow-up

- Retain `quarantine/anxietywatch2-pi5-vitals-core` until a separate manual review confirms its history is no longer needed; never merge it into AnxietyWatch.
- Leave unrelated T3, T6, trends, ez Share, and Oura worktrees under their owners; this change does not authorize their removal.
