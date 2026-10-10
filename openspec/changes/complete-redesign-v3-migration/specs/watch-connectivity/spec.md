# Watch Connectivity Delta

## ADDED Requirements

### Requirement: Delegate ownership migrates atomically
Each target SHALL migrate all required legacy `WCSessionDelegate` callbacks behind the replacement coordinator before startup assigns that coordinator as the sole delegate.

#### Scenario: Replacement coordinator activates
- **WHEN** the replacement transport starts on iPhone or watch
- **THEN** no later startup step overwrites its delegate and all legacy message classes remain handled

### Requirement: Binary negotiation and fallback
Peers SHALL negotiate binary version support before sending binary historical batches and SHALL fall back to legacy JSON when either peer, flag, or decoder cannot support the negotiated version.

#### Scenario: Older peer is paired
- **WHEN** one peer does not advertise compatible binary support
- **THEN** both use the legacy payload without dropping or duplicating the batch

### Requirement: Durable transfer acknowledgment
Historical transfer source files and cursors SHALL remain pending until receiver ingestion is durably committed and acknowledged with a stable transfer identity.

#### Scenario: Receiver crashes after file delivery
- **WHEN** the peer receives a file but terminates before durable ingest acknowledgment
- **THEN** the sender retains or retries the transfer and does not advance its cursor

### Requirement: Critical alert deduplication
The immediate-message and queued-user-info paths SHALL share a stable alert identity so fallback cannot create duplicate user-facing alerts.

#### Scenario: Immediate delivery succeeds but reply is lost
- **WHEN** the sender also queues fallback for the same alert identity
- **THEN** the receiver presents the alert once
