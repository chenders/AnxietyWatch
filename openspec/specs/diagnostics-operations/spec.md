# Diagnostics and Operations Specification

## Purpose

Defines privacy-safe diagnostics, operational observability, performance budgets, log export, and release evidence for the redesigned data paths.

## Requirements

### Requirement: Unified privacy-safe logging
Subsystems SHALL use one application logging subsystem with stable categories for storage, sync, BLE, HealthKit, pipeline, transport, and complications. Logs MUST NOT contain credentials or personal identifiers. **Implementation status: implemented and used by package foundations.**

#### Scenario: Sync failure is logged
- **WHEN** a synchronization attempt fails
- **THEN** the log records non-identifying operation metadata and error classification without tokens, account values, or physiological payloads

### Requirement: Performance signposts
The system SHALL signpost BLE parse latency, storage transactions, sync attempts, transfer-file operations, and watch background-budget consumption. **Implementation status: signpost utility exists; call-site coverage is partial.**

#### Scenario: BLE frame is parsed
- **WHEN** a supported frame enters and exits parsing
- **THEN** a matched interval is available for latency analysis without including the raw frame as public metadata

### Requirement: Diagnostics snapshot
The app SHALL expose current database size, last sync result, per-table cursor state, quarantine and corruption events, gap counts, clock-suspect state, transfer state, and overflow warnings. **Implementation status: diagnostics model and view exist; production navigation and all live data providers are incomplete.**

#### Scenario: Unacknowledged overflow has fired
- **WHEN** diagnostics is opened after an overflow event
- **THEN** it immediately states that the backend was unreachable and coarse data was retained

### Requirement: Redacted diagnostic export
Users SHALL be able to export a bounded diagnostic bundle containing redacted logs, status snapshots, and schema metadata without credentials or personal health rows. **Implementation status: export component and tests exist; no confirmed production call site.**

#### Scenario: User requests support bundle
- **WHEN** export is invoked
- **THEN** the generated bundle is size bounded, redacted, and contains enough non-identifying state to diagnose storage and sync failures

### Requirement: Watch memory budget
Automated watch testing SHALL replay ten simulated minutes of 200 Hz input and keep peak memory below 15 MB over baseline. TestFlight release evidence SHALL keep P95 peak memory below 50 MB. **Implementation status: target retained; complete automated and field evidence not found.**

#### Scenario: Pre-release performance suite runs
- **WHEN** the sustained high-rate fixture completes
- **THEN** the measured peak over baseline is below 15 MB or release is blocked

### Requirement: Operational release metrics
Release evaluation SHALL measure watch battery drain below five percent per hour of continuous BLE monitoring and P95 urgent-alert sync latency below two seconds. **Implementation status: targets defined; current baselines and production evidence are incomplete.**

#### Scenario: Candidate lacks a required baseline
- **WHEN** a rollout phase has no current memory, battery, or latency baseline relevant to its path
- **THEN** the phase is not declared production validated

### Requirement: Incident signals
Clock quarantine, corruption circuit-breaker trips, data gaps, unacknowledged overflow, repeated chunk bursts, and cursor divergence SHALL produce stable metrics and fault logs suitable for operational alerting. **Implementation status: several local events exist; fleet reporting and dashboards are incomplete.**

#### Scenario: Repeated overflow chunks occur
- **WHEN** at least two chunked overflow evictions occur in a rolling four-hour window
- **THEN** the system emits a distinct burst fault and metric suitable for P1 investigation
