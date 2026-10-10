# Proposal

## Why

Redesign v3 was intentionally implemented in stages, but its checklist stopped tracking the merged code and its monolithic specification did not distinguish package foundations from production-authoritative paths. The remaining migration must be completed from an evidence-based plan so dormant infrastructure is either safely activated or deliberately retired without risking physiological data, restore coverage, or watch connectivity.

## What Changes

- Make OpenSpec the sole authoritative source for redesign requirements, status, technical decisions, and remaining work.
- Preserve the complete historical design and implementation record while removing the superseded `docs/redesign_spec.md`.
- Reconcile every original T01-T40 task against source, tests, application wiring, rollout flags, and operational evidence.
- Complete SQLite backfill/read cutover, single-owner WatchConnectivity migration, delta-sync CRUD/restore and shadow rollout, and production diagnostics in independently reversible phases.
- Add explicit fresh-install, restore, corruption, memory, clock, device-loss, and rollback gates.
- Retain legacy SwiftData, WatchConnectivity, and REST paths until their replacement phase proves parity.
- **BREAKING** only at the eventual gated cutovers: the production storage reader, WCSession delegate owner, and sync protocol will change after their acceptance gates pass.

## Capabilities

### New Capabilities

None. The current capability baseline was bootstrapped from the already-merged redesign behavior before this change was opened.

### Modified Capabilities

- `sensor-processing`: finish coexistence decisions, gap activation, and target-specific integration evidence.
- `time-series-storage`: add the resumable backfill, app read cutover, lifecycle orchestration, and complete corruption recovery.
- `causal-sync`: complete low-frequency materialization, scheduling, round-trip restore, and shadow validation.
- `watch-connectivity`: establish one delegate owner and finish resilient package transport on both targets.
- `watch-runtime`: finish background URL-session sync continuation and retry escalation.
- `diagnostics-operations`: wire diagnostics/export, MetricKit and signpost coverage, and release baselines.
- `migration-rollout`: enforce phase status, real flag consumption, evidence gates, and independent rollback.

## Impact

Affected areas include `AnxietyWatchKit`, iOS/watchOS startup and services, the complication extension, server delta endpoints and restore logic, feature flags, diagnostics UI, tests, and release operations. The highest-risk surfaces are one-time migration, first-run restore, HealthKit ownership, single `WCSession.default.delegate` ownership, unacknowledged sample retention, and server tombstone propagation. No phase is authorized for production enablement merely by accepting this proposal.
