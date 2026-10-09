# Causal Sync Delta

## ADDED Requirements

### Requirement: Low-frequency changes materialize
The delta coordinator SHALL resolve and apply low-frequency upserts and deletes to their registered local models while preserving incoming remote HLC values and LWW ordering.

#### Scenario: Remote CRUD row wins
- **WHEN** an incoming registered row has the winning HLC
- **THEN** its decoder updates or deletes the local row and the local HLC service observes the stamp without rewriting its causal history

### Requirement: Periodic and lifecycle scheduling
The application SHALL schedule pull, push, retry, foreground, background, and connectivity-restored synchronization through one coordinator without overlapping mutation of cursors.

#### Scenario: Foreground and timer triggers coincide
- **WHEN** multiple sync triggers arrive while one attempt is active
- **THEN** they coalesce or serialize and no cursor is committed twice or out of order

### Requirement: Restore inventory is complete
Before delta rollout, every uploaded table SHALL appear in the server query contract and a tested restore importer that preserves server identity and marks restored rows synchronized.

#### Scenario: Upload inventory contains an unmatched table
- **WHEN** release validation finds no server query or importer for an uploaded table
- **THEN** delta enablement fails

### Requirement: Shadow comparison is measured
The server SHALL dual-serve legacy and delta results for at least two weeks and compare semantic rows and per-node cursors for 30 divergence-free days before production enablement.

#### Scenario: Shadow result diverges
- **WHEN** any row set or cursor differs beyond an explicitly approved representation-only normalization
- **THEN** the divergence count increases, rollout remains disabled, and diagnostic evidence identifies the table and node

### Requirement: Tombstones affect reports honestly
Server aggregate and reporting endpoints SHALL preserve or explicitly disclose known tombstoned ranges and MUST NOT silently interpolate them as observed data.

#### Scenario: Report spans a known gap
- **WHEN** a report covers a propagated tombstone interval
- **THEN** the output identifies incomplete coverage rather than presenting a continuous measured series
