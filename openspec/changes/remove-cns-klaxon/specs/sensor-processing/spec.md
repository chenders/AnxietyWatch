# Spec Delta

## MODIFIED Requirements

### Requirement: Active iPhone sensor pipeline
The iPhone application SHALL route configured Polar, EMAY, and HealthKit observations through actor-isolated adapters and a shared sensor router for persistence, trends, and presentation. The pipeline MUST NOT feed a CNS-depression detection or klaxon decision engine in this application. **Implementation status: partial until CNS consumers are removed; sensor adapters remain active.**

#### Scenario: Supported live observation arrives
- **WHEN** a configured Polar, EMAY, or HealthKit source emits a valid supported observation
- **THEN** the router delivers it to non-alert consumers (storage, aggregation, UI snapshots) without requiring a SwiftUI view read to await hardware work

#### Scenario: Observation is not used for CNS tiers
- **WHEN** a valid SpO2 or heart-rate observation is routed
- **THEN** no package or app component in this application derives a CNS alert tier or klaxon command from it

### Requirement: Side-effect boundary
Notification, haptic, connectivity, and other side effects SHALL be executed outside pure processing functions. Invalid physiological data MUST contribute nothing to clinical or trend safety claims. This application MUST NOT execute CNS-klaxon side effects (clinical escalation notifications, klaxon audio, or watch klaxon haptics). **Implementation status: target after retirement; non-clinical reminders remain separate.**

#### Scenario: Invalid observation is received
- **WHEN** an observation fails its source or quality validation
- **THEN** it does not create a safety claim and produces no CNS alarm side effect

#### Scenario: Valid overnight stream without clinical product
- **WHEN** continuous sensor data flows after CNS retirement
- **THEN** coordinators may update presentation state but MUST NOT fire klaxon audio, clinical escalation notifications, or `cnsKlaxonHaptic` messages

### Requirement: Bounded UI observation
SwiftUI SHALL consume throttled main-actor view state derived from background processing, with no asynchronous hardware read in a view property access. **Implementation status: active.**

#### Scenario: High-rate stream is active
- **WHEN** a sensor produces observations faster than the presentation rate
- **THEN** the UI receives bounded approximately 10 Hz snapshots without blocking sensor ingestion

## REMOVED Requirements

### Requirement: Deterministic CNS transition
**Reason**: On-device CNS-depression tier processing is retired from this application; AnxietyWatch2 owns superseding detection/alarm design.
**Migration**: Delete package and app CNS transition engines and tests. Sensor samples continue through non-alert routing only. Do not replace with a second in-app detector.

### Requirement: Explicit gap activation
**Reason**: Storage-originating data-gap events existed to drive CNS processing; without a CNS engine they have no consumer in this app.
**Migration**: Stop delivering storage gap events into any alert-tier machine. Retain gap recording for diagnostics/storage integrity only if redesign storage still requires it, without CNS tier transitions.
