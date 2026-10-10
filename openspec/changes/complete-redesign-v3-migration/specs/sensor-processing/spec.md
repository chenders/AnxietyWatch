# Sensor Processing Delta

## ADDED Requirements

### Requirement: CNS ownership is explicit
The application SHALL document and enforce whether the package pipeline replaces, feeds, or operates independently from the app-level CNSRisk engine. A sample MUST NOT create duplicate clinical side effects through both engines.

#### Scenario: Both engines are present at startup
- **WHEN** the app constructs both CNS implementations
- **THEN** one documented coordinator owns each notification, haptic, and watch-message side effect

### Requirement: Authoritative gaps enable gap processing
The application SHALL enable package gap processing only after the active storage path emits transactional tombstones and the pipeline consumes their ranges without fabricating clinical danger.

#### Scenario: Phase 2A gap validation passes
- **WHEN** an evicted range produces a persisted, synced, and replayed tombstone in integration tests
- **THEN** the gap-events flag may be enabled for the validated rollout cohort
