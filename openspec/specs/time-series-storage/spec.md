# Time-Series Storage Specification

## Purpose

Defines local high-frequency sample persistence, compaction, gap representation, recovery, and the boundary with HealthKit and legacy SwiftData.

## Requirements

### Requirement: Dedicated time-series database
BLE-native and app-derived high-frequency samples SHALL be stored in a dedicated SQLite database using a natural source/type/timestamp identity. HealthKit-owned observations MUST remain recoverable from HealthKit and MUST NOT become dependent on this database as their sole source. **Implementation status: package foundation implemented and tested; app reads are not enabled.**

#### Scenario: Duplicate sample is ingested
- **WHEN** the same source, type, and timestamp are written more than once
- **THEN** the database retains one logical sample

### Requirement: Protected local database
The database and sidecar files SHALL use complete-until-first-user-authentication protection, SHALL be excluded from backup, and SHALL operate in WAL mode with normal synchronous durability. **Implementation status: implemented in the package database manager.**

#### Scenario: Database is opened after first unlock
- **WHEN** the storage manager opens its app-group database
- **THEN** protection, backup exclusion, WAL, busy-timeout, foreign-key, and checkpoint settings are applied before use

### Requirement: Single-writer lifecycle
Writes SHALL be serialized through one database queue. watchOS background transitions SHALL close storage cleanly, and a later foreground or background operation SHALL reopen it through the same migration and integrity sequence. **Implementation status: package foundation implemented; full watch lifecycle validation remains pending.**

#### Scenario: Watch background budget expires
- **WHEN** watchOS requires the process to release storage
- **THEN** pending work stops safely and the SQLite handle is closed without advancing an unacknowledged cursor

### Requirement: Gap tombstones
Deletion or eviction that creates unavailable sample coverage SHALL create a tombstone containing source, type, time range, HLC, originating node, dropped-row count, and a defined reason. Ordinary HealthKit silence MUST NOT create tombstones. **Implementation status: schema and stores implemented and tested.**

#### Scenario: Memory-pressure eviction removes a range
- **WHEN** samples are intentionally discarded under a permitted panic policy
- **THEN** a corresponding tombstone is committed transactionally with the deletion

### Requirement: Resumable backfill state
Any migration from legacy high-frequency storage SHALL persist a per-source and per-type resume timestamp transactionally in the time-series database. **Implementation status: progress store implemented; SwiftData backfiller not implemented.**

#### Scenario: Backfill is interrupted
- **WHEN** the process terminates after a committed migration batch
- **THEN** the next run resumes after the last transactionally stored position without duplicating or skipping committed rows

### Requirement: Bounded retention and compaction
The watch database SHALL retain seven days of raw coverage under ordinary conditions, delete in bounded batches, downsample eligible raw samples into one-minute rollups, and preserve unacknowledged data except under the explicit overflow protocol. **Implementation status: compactor and downsampler implemented and tested; production orchestration is not enabled.**

#### Scenario: Daily compaction runs
- **WHEN** the scheduled compaction window begins
- **THEN** acknowledged retention runs before downsampling and checkpoint work using bounded transactions

### Requirement: Checkpoint safety
Active ingestion SHALL use passive checkpoints. Truncating checkpoints SHALL run only while BLE ingestion is idle in an allowed background window, and an interrupted checkpoint SHALL trigger restart and integrity checks at the next open. **Implementation status: checkpoint manager implemented and tested; production scheduling is incomplete.**

#### Scenario: Checkpoint was interrupted
- **WHEN** the database opens after an incomplete truncating checkpoint
- **THEN** storage performs a restart checkpoint and integrity validation before normal use

### Requirement: Corruption recovery
Confirmed SQLite corruption SHALL trip a circuit breaker, close and replace the database and sidecars, preserve the Keychain node identity, surface recovery state, and request a complete authoritative backfill. **Implementation status: detection and broadcaster foundations exist; end-to-end app recovery and full backfill are incomplete.**

#### Scenario: Query reports SQLite corruption
- **WHEN** an open or query operation reports a confirmed corruption code
- **THEN** the app stops ordinary database use and begins the recover-and-refill flow without regenerating the node identity
