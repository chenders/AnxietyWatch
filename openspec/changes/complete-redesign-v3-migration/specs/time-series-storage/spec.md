# Time-Series Storage Delta

## ADDED Requirements

### Requirement: Idempotent legacy backfill
The application SHALL migrate legacy high-frequency rows in bounded batches, store progress in the same transaction, verify count and sampled-value parity, and tolerate termination at every batch boundary.

#### Scenario: Process terminates after batch commit
- **WHEN** the migration restarts after an arbitrary committed batch
- **THEN** it resumes after the stored source/type timestamp with no duplicate or omitted committed row

### Requirement: Storage rollback preserves new rows
During the Phase 2A rollback window, the application SHALL export any SQLite-only high-frequency rows back to the legacy store before disabling the SQLite write path.

#### Scenario: Phase 2A rollback is requested
- **WHEN** new high-frequency rows exist only in SQLite
- **THEN** rollback copies and verifies them before legacy reads become authoritative

### Requirement: Production compaction orchestration
The application SHALL orchestrate ordinary compaction as retention, downsampling, and safe checkpoint work, while panic compaction SHALL downsample before transactional eviction and tombstone insertion.

#### Scenario: Ordinary and panic triggers overlap
- **WHEN** scheduled retention and a size panic occur concurrently
- **THEN** a single serialized policy preserves unacknowledged rows and produces deterministic ordering

### Requirement: Complete corruption restoration
Corruption recovery SHALL replace database sidecars, preserve node identity, restore all server-backed rows, rederive HealthKit-backed rows, show recovery state, and stop automatic retries after three events in 24 hours.

#### Scenario: Repeated corruption occurs
- **WHEN** a third confirmed corruption event occurs within 24 hours
- **THEN** automatic replacement stops and diagnostics require explicit user action

### Requirement: Fresh-install storage proof
Phase 2A SHALL NOT enable until a genuinely fresh install completes schema creation, restore/backfill selection, migration, and first read without blocking restore through an incidental early write.

#### Scenario: Empty replacement device starts
- **WHEN** the app launches with no local store but server and HealthKit history exist
- **THEN** restore and rederivation complete before any write can falsely classify the store as non-empty
