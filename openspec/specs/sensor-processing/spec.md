# Sensor Processing Specification

## Purpose

Defines the production sensor-ingestion and deterministic CNS-processing boundaries shared by the iPhone and Apple Watch applications.

## Requirements

### Requirement: Active iPhone sensor pipeline
The iPhone application SHALL route configured Polar, EMAY, and HealthKit observations through actor-isolated adapters and a shared sensor router before deterministic package CNS processing. **Implementation status: active.**

#### Scenario: Supported live observation arrives
- **WHEN** a configured Polar, EMAY, or HealthKit source emits a valid supported observation
- **THEN** the router delivers it to the package pipeline without requiring a SwiftUI view read to await hardware work

### Requirement: Separate watch sensor pipeline
The watch application SHALL use its own HealthKit-only router for watch presentation and complication output. It MUST NOT be represented as a continuation of the iPhone view-model pipeline. **Implementation status: active.**

#### Scenario: Watch HealthKit observation arrives
- **WHEN** the watch receives a supported HealthKit observation
- **THEN** the watch-local router updates the watch presentation and complication-feed path

### Requirement: HealthKit ownership boundary
HealthKit SHALL remain authoritative for Apple-owned HR, HRV, SpO2, respiratory-rate, and other HealthKit-originating observations. Empty HealthKit query windows MUST be handled as staleness, not fabricated data-gap tombstones. **Implementation status: active.**

#### Scenario: HealthKit query returns no objects
- **WHEN** an anchored query window contains no new objects
- **THEN** the adapter emits no synthetic sample or data-gap event and downstream staleness rules determine availability

### Requirement: Deterministic CNS transition
The package CNS pipeline SHALL calculate state transitions as deterministic state-plus-event processing with injected time and SHALL return commands separately from side effects. **Implementation status: implemented and unit tested; production behavior coexists with the app-level CNSRisk engine.**

#### Scenario: Identical state and event are replayed
- **WHEN** the same prior state, sample event, and injected clock values are evaluated twice
- **THEN** both evaluations produce equivalent next state and commands

### Requirement: Side-effect boundary
Notification, haptic, connectivity, and other side effects SHALL be executed by a coordinator outside the pure processing functions. Invalid data MUST contribute nothing, and indeterminate data MUST NOT be treated as safe. **Implementation status: package foundation integrated for monitoring output.**

#### Scenario: Invalid observation is received
- **WHEN** an observation fails its source or quality validation
- **THEN** it does not increase or clear risk and produces no safety claim

### Requirement: Bounded UI observation
SwiftUI SHALL consume throttled main-actor view state derived from background processing, with no asynchronous hardware read in a view property access. **Implementation status: active.**

#### Scenario: High-rate stream is active
- **WHEN** a sensor produces observations faster than the presentation rate
- **THEN** the UI receives bounded approximately 10 Hz snapshots without blocking sensor ingestion

### Requirement: Explicit gap activation
Storage-originating data-gap events SHALL enter CNS processing only while the runtime gap-events feature is enabled. **Implementation status: logic implemented and tested; disabled by default pending storage cutover.**

#### Scenario: Gap flag is disabled
- **WHEN** a data-gap event is presented while the runtime flag is false
- **THEN** the package pipeline does not apply the gap transition
