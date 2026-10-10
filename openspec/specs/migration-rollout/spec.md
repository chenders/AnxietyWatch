# Migration and Rollout Specification

## Purpose

Defines staged adoption, backfill, parity, feature controls, rollback, and evidence required to make redesigned foundations production-authoritative.

## Requirements

### Requirement: Four distinct completion states
Every redesign capability SHALL report whether it is implemented, tested, app-wired, and production-authoritative. Documentation MUST NOT substitute one state for another. **Implementation status: adopted by this OpenSpec migration.**

#### Scenario: Tested type has no production call site
- **WHEN** code and unit tests exist but the application does not invoke the path
- **THEN** status is foundation-only or partial rather than shipped

### Requirement: Phase 1 compute rollout
Actor-isolated sensor ingestion and deterministic package processing SHALL be deployed without changing persistent data ownership. Gap processing SHALL remain disabled until storage can emit authoritative tombstones. **Implementation status: iPhone compute path active; watch uses a separate HealthKit-only path; coexistence with app-level CNS processing remains.**

#### Scenario: Phase 1 rolls back
- **WHEN** the package compute path is disabled or removed from startup
- **THEN** no database migration or irreversible data-format change is required

### Requirement: Phase 2A local storage rollout
High-frequency storage SHALL cut over to SQLite only after an idempotent backfill, count and sample parity, fresh-install recovery, corruption recovery, and read-path rollback have passed. Legacy watch-phone JSON remains authoritative during this phase. **Implementation status: storage foundation exists; backfill and read cutover are not implemented.**

#### Scenario: Backfill parity fails
- **WHEN** migrated counts or sampled values diverge from the authoritative source
- **THEN** SQLite reads remain disabled and legacy reads continue

### Requirement: High-frequency migration policy
High-frequency rows SHALL use a one-time resumable migration rather than dual writes. Low-frequency rows MAY dual-write for one minor version while the UI reads the proven store and parity telemetry compares both stores. **Implementation status: policy retained; migration orchestration not implemented.**

#### Scenario: Process stops during high-frequency migration
- **WHEN** a batch has committed before termination
- **THEN** a later run resumes from the stored checkpoint without restarting the completed range

### Requirement: Phase 2B binary transport rollout
Binary WatchConnectivity SHALL remain behind an independently reversible flag until both targets support version negotiation, fallback, acknowledgment, and failure recovery. **Implementation status: codec and flag exist; watch delegate cutover is incomplete.**

#### Scenario: Binary decoder failure rate rises
- **WHEN** rollout telemetry crosses the agreed failure threshold
- **THEN** binary transport is disabled without rolling back SQLite storage or compute changes

### Requirement: Phase 2C delta sync rollout
Delta endpoints SHALL coexist with legacy REST and remain disabled by default until shadow comparison has zero cursor divergence, P95 is below two seconds, tombstones round-trip, and the service is stable for 30 days. **Implementation status: client/server foundations exist; shadow rollout and production enablement are incomplete.**

#### Scenario: Backend slips or diverges
- **WHEN** latency exceeds two seconds, cursor comparison diverges, or the backend schedule slips more than four weeks
- **THEN** delta sync stays or returns off while Phase 2A and 2B may remain independently deployed

### Requirement: Runtime flags are real controls
Each phase flag SHALL be consumed by the production decision point it claims to control, have a documented default, and have a tested fallback path. A defined but unread flag MUST NOT count as a rollback mechanism. **Implementation status: gap and binary flags are consumed; SQLite-read and delta flags are defined but not production decision points.**

#### Scenario: Rollout audit inspects a flag
- **WHEN** a phase is proposed for enablement
- **THEN** evidence identifies the exact production branch that reads the flag and a test proves both values

### Requirement: Data round-trip gate
Every table added to an upload payload SHALL have a server persistence contract and a tested restore/downloader path before production enablement. **Implementation status: delta sample/tombstone endpoints exist; broader CRUD materialization and restore completeness remain unfinished.**

#### Scenario: Device is replaced after upload
- **WHEN** the user starts from an empty local store on a new device
- **THEN** every server-backed app-only row can be restored with stable identity and without re-upload duplication

### Requirement: Independent rollback
Compute, local storage, wire format, and delta sync SHALL be independently reversible. A rollback MUST preserve user data and MUST NOT require deleting the user's authoritative HealthKit data. **Implementation status: target architecture; evidence incomplete for unfinished phases.**

#### Scenario: Delta sync is rolled back
- **WHEN** Phase 2C is disabled after partial rollout
- **THEN** legacy REST resumes without discarding locally unacknowledged changes or disabling already-validated local storage

### Requirement: Documentation is release evidence
The active OpenSpec change SHALL record implementation status, tests, rollout state, deviations, and deferred work in the same change that ships them. Superseded redesign documents MUST NOT remain competing sources of truth. **Implementation status: this migration establishes the requirement.**

#### Scenario: Redesign work is merged
- **WHEN** a task changes a phased capability or its rollout state
- **THEN** the associated OpenSpec status and post-implementation notes change with it
