## Purpose

Defines how respiratory-rate and apnea evidence may participate in safety decisions without treating missing, stale, low-fidelity, or disconnected data as reassurance.

## ADDED Requirements

### Requirement: Trusted respiratory sources
Respiratory-rate and apnea observations SHALL affect clinical risk only when their source, measurement semantics, timestamp, unit, and quality state are explicitly supported. **Implementation status: not implemented for an independent RR/apnea path.**

#### Scenario: Unknown source reports respiratory data
- **WHEN** an observation arrives from an unrecognized source or without required quality metadata
- **THEN** it contributes neither escalation nor clearing evidence and a non-identifying diagnostic reason is recorded

### Requirement: Independent respiratory escalation
A sustained qualifying RR or apnea signal SHALL be able to escalate through a dedicated path without requiring a simultaneous SpO2 threshold crossing, while preserving configured persistence and anti-flapping rules. **Implementation status: not implemented.**

#### Scenario: Qualifying respiratory evidence persists
- **WHEN** trusted primary respiratory evidence crosses its configured threshold for the required persistence window
- **THEN** the respiratory path produces the specified escalation input even when SpO2 is unavailable or not below threshold

### Requirement: Missing data is indeterminate
Stale, disconnected, faulted, or absent respiratory evidence MUST be represented as indeterminate and MUST NOT clear or suppress an existing warning. **Implementation status: partial in the broader CNS engine; not implemented for the proposed path.**

#### Scenario: Source disconnects during an active warning
- **WHEN** a trusted respiratory source stops delivering current observations
- **THEN** the warning is not cleared on the basis of missing data and the source state is shown as unavailable

### Requirement: Fault suppression
Known sensor faults and physiologically impossible observations SHALL contribute no clinical evidence and SHALL produce a bounded, privacy-safe fault signal. **Implementation status: partial.**

#### Scenario: Observation is outside validated source limits
- **WHEN** a respiratory observation violates the source-specific validity contract
- **THEN** it is rejected before scoring and cannot escalate or clear risk

### Requirement: Clinically reviewed activation
Production activation of new respiratory thresholds, interaction rules, or classifiers MUST have recorded medical-data review, test evidence, and an independently reversible control. **Implementation status: not implemented.**

#### Scenario: Clinical review is incomplete
- **WHEN** code exists for a new respiratory rule but its medical-data review or validation evidence is missing
- **THEN** the production control remains disabled and existing behavior stays authoritative

### Requirement: Fresh-install and restore continuity
Fresh installation and server restoration SHALL preserve or recover every app-only event required to resume CNS monitoring without fabricating historical evidence or re-uploading restored rows. **Implementation status: requires re-verification.**

#### Scenario: Monitoring resumes after server restore
- **WHEN** an empty installation restores its server-backed app-only dose and monitoring records
- **THEN** stable identities are preserved, restored rows are marked synced, and the risk path resumes from the restored facts without duplicate upload

### Requirement: Physical lifecycle evidence
An AirSense-derived respiratory source SHALL NOT be declared production validated until physical connect, disconnect, reconnect, stale-socket callback, app background, and network-loss scenarios pass on supported hardware. **Implementation status: context-feed foundation active; complete lifecycle evidence not found.**

#### Scenario: Old socket callback arrives after reconnect
- **WHEN** a callback from a retired connection arrives after a replacement connection is active
- **THEN** the stale callback cannot overwrite the current connection or clinical source state
