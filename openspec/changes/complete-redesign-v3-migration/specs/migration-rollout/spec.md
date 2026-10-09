# Migration and Rollout Delta

## ADDED Requirements

### Requirement: Rollout controls have production readers
SQLite-read and delta-sync controls SHALL be evaluated at their actual production decision points, default safely offline, log changes, appear in diagnostics, and have tests for enabled and disabled behavior.

#### Scenario: Device has no remote configuration
- **WHEN** the app launches offline or configuration polling fails
- **THEN** unfinished storage and delta paths remain disabled using bundled safe defaults

### Requirement: Phase evidence is recorded separately
Each phase SHALL record implementation, focused tests, app wiring, canary state, production authority, and rollback validation as separate fields in the active OpenSpec change.

#### Scenario: Code merges before rollout
- **WHEN** a phase's implementation lands while its flag remains off
- **THEN** documentation marks implementation complete and rollout pending

### Requirement: Legacy retirement is gate driven
Legacy storage, JSON transport, or REST code SHALL be removed only after its replacement meets the phase's parity, stability, adoption, and rollback gates.

#### Scenario: Calendar date arrives before stability gate
- **WHEN** a planned sunset date arrives but evidence is incomplete
- **THEN** the legacy path remains available and the reason is documented

### Requirement: Post-implementation notes stay current
Every merged redesign change SHALL update its OpenSpec implementation notes with shipped scope, test evidence, PR or commit reference, deviations, and deferred work.

#### Scenario: Scope changes during implementation
- **WHEN** a task is split, deferred, or replaced by another approach
- **THEN** the active change records the decision in the same merge or an immediate follow-up
