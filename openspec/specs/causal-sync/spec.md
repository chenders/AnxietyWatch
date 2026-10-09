# Causal Sync Specification

## Purpose

Defines causally ordered replication, bounded clock handling, loss disclosure, server round trips, and the current boundary between legacy and delta synchronization.

## Requirements

### Requirement: Stable per-install node identity
Each iPhone and Apple Watch installation SHALL use its own 16-byte node identity stored with after-first-unlock, this-device-only Keychain accessibility. Corruption recovery MUST NOT regenerate it. **Implementation status: package foundation implemented.**

#### Scenario: Database is rebuilt
- **WHEN** local SQLite files are replaced after corruption
- **THEN** newly created HLC stamps retain the installation's existing node identity

### Requirement: Hybrid logical ordering
Replicated rows SHALL use separate physical, logical, and node identity values. Local events and observed remote events SHALL preserve HLC monotonicity, and wire/storage tuples SHALL remain flat while comparison may use a value wrapper. **Implementation status: implemented and property tested.**

#### Scenario: Multiple events occur at the same physical time
- **WHEN** the physical clock does not advance between events
- **THEN** the logical component increases so each later event sorts after the prior event

### Requirement: Bounded future-clock handling
Incoming time more than 60 seconds ahead SHALL be accepted with a bounded local merge; time more than 24 hours ahead SHALL be quarantined and faulted. A sustained wall-versus-monotonic divergence SHALL pause uploads and cross-device fusion until recovery is stable for 15 minutes. **Implementation status: HLC, quarantine, and clock gate implemented; all production call sites are not wired.**

#### Scenario: Peer timestamp is more than 24 hours ahead
- **WHEN** a received stamp exceeds the quarantine threshold
- **THEN** its row is quarantined, an operational fault is emitted, and the row is not applied as ordinary data

### Requirement: Per-table per-node cursors
Delta pagination SHALL maintain independent cursors for samples, tombstones, and low-frequency change records, with a cursor for every contributing node. Rows SHALL be ordered by HLC without collapsing the map into a scalar. **Implementation status: cursor model and coordinator foundation implemented and tested; runtime flag is off.**

#### Scenario: Two nodes have different progress
- **WHEN** one node is fully acknowledged and another is behind
- **THEN** the next request starts each node after its own last acknowledged HLC

### Requirement: Time-series and tombstones travel together
Sample pushes and pulls SHALL include both sample rows and gap tombstones above their respective cursors so a peer cannot observe data without the known gaps in that coverage. **Implementation status: client/server endpoint foundations exist; production delta rollout is disabled.**

#### Scenario: Evicted range has a tombstone
- **WHEN** a peer pulls changes after the tombstone's HLC
- **THEN** the response includes the gap record and does not interpolate or conceal the missing range

### Requirement: Low-frequency sync completeness
Every low-frequency table declared bidirectional SHALL have both upload encoding and restore decoding. A declaration without a downloader MUST fail at compile time; upload-only behavior MUST be explicit. **Implementation status: macro and registry foundation implemented; CRUD materialization into production models is deferred.**

#### Scenario: Bidirectional model omits restore decoding
- **WHEN** a developer builds a sync declaration without a down-path initializer
- **THEN** the build fails rather than shipping an upload-only backup illusion

### Requirement: Acknowledgment safety
No local or peer cursor SHALL advance without the corresponding server or peer acknowledgment. Retry and garbage collection MUST leave unacknowledged rows available. **Implementation status: coordinator logic implemented and tested; periodic production scheduling is deferred.**

#### Scenario: Push times out
- **WHEN** a delta push receives no acknowledgment
- **THEN** cursors and change-log rows remain unchanged for a later retry

### Requirement: Storage panic disclosure
At 225 MB the system SHALL attempt a high-priority sync. At 250 MB, after permitted acknowledged-data eviction, the system MAY evict toward 200 MB only while emitting transactional gap records. Unacknowledged raw data requires downsampling and the stricter overflow protocol. **Implementation status: panic components implemented and tested; production orchestration is not enabled.**

#### Scenario: Database reaches yellow threshold
- **WHEN** database size reaches 225 MB
- **THEN** a bounded 30-second high-priority sync attempt begins before unacknowledged eviction is considered

### Requirement: Last-resort unacknowledged overflow
Unacknowledged eviction SHALL require all defined preconditions, retain one-minute rollups, cap each event at six hours, rate-limit per source/type to once per hour, mint fresh tombstones, and fault on repeated chunks. **Implementation status: component implemented and tested; fleet metrics and diagnostics activation are incomplete.**

#### Scenario: Overflow preconditions are not all satisfied
- **WHEN** any required sync-attempt, size, downsampling, or rate-limit condition is false
- **THEN** no unacknowledged raw sample is evicted

### Requirement: Versioned server contract
The server SHALL negotiate schema and cursor-format versions, persist and propagate tombstones, and retain legacy APIs until delta correctness and latency release gates pass. **Implementation status: endpoints and schema exist; shadow comparison and sunset evidence are not complete.**

#### Scenario: Client cursor version is unsupported
- **WHEN** a client requests delta sync with an incompatible cursor format
- **THEN** the server rejects or negotiates explicitly without advancing any cursor
