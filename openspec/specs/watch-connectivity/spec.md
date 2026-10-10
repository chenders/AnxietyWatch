# Watch Connectivity Specification

## Purpose

Defines the single-owner WatchConnectivity boundary, message routing, binary payload compatibility, and resilient phone-watch transfer behavior.

## Requirements

### Requirement: One effective session delegate
Each process SHALL have one effective `WCSession` delegate owner. A replacement transport MUST NOT start until all legacy delegate responsibilities for that target have migrated. **Implementation status: legacy phone and watch managers remain authoritative; iPhone also starts a package coordinator that is subsequently displaced by the legacy delegate.**

#### Scenario: Application startup completes
- **WHEN** all phone startup services have activated
- **THEN** exactly one documented owner receives session callbacks and no active subsystem assumes ownership it does not have

### Requirement: Legacy compatibility during migration
The production phone-watch path SHALL continue to support legacy payloads until both targets can decode, acknowledge, retry, and restore all replacement message classes. **Implementation status: active.**

#### Scenario: Replacement flag is disabled
- **WHEN** a watch and phone communicate during staged rollout
- **THEN** the legacy format and handlers remain available without data loss

### Requirement: Binary sample encoding
Replacement historical sample batches SHALL use a versioned compact binary representation preserving source, type, timestamp, value, unit, quality, and HLC identity. **Implementation status: codec implemented and tested behind a runtime flag.**

#### Scenario: Binary payload version is unknown
- **WHEN** a peer receives a payload with an unsupported version
- **THEN** it rejects or requests fallback without silently interpreting the bytes as another schema

### Requirement: Transport mapping
Latest metadata and settings SHALL use application context; urgent alerts SHALL attempt immediate message delivery and fall back to queued user info; historical batches SHALL use disk-backed file transfer. **Implementation status: package routing foundation implemented; watch target cutover incomplete.**

#### Scenario: Peer is unreachable during an urgent alert
- **WHEN** immediate message delivery cannot reach the peer
- **THEN** the alert is queued using eventual-delivery user info with a stable deduplication identity

### Requirement: File-transfer resilience
Historical transfers SHALL tolerate out-of-order delivery, use bounded chunks, retain source files until acknowledged, retry with exponential jittered backoff, and gate active attempts on path availability. **Implementation status: partial package foundation; production transfer scheduling and acknowledgment lifecycle need completion.**

#### Scenario: Connectivity disappears during file transfer
- **WHEN** network or peer availability is lost
- **THEN** the transfer remains retryable and its acknowledged cursor does not advance

### Requirement: Platform compression only
Compressed watch payloads SHALL use Apple-provided compression facilities and MUST NOT use a custom compression algorithm. **Implementation status: design constraint retained; end-to-end rollout not completed.**

#### Scenario: Historical batch is compressed
- **WHEN** a batch exceeds the configured compression threshold
- **THEN** both targets use a versioned Apple-platform compression format and can reject unsupported algorithms
