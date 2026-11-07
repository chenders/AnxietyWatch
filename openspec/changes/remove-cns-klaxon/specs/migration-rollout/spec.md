# Spec Delta

## MODIFIED Requirements

### Requirement: Phase 1 compute rollout
Actor-isolated sensor ingestion SHALL remain deployable without changing persistent data ownership for non-alert capture. Package compute MUST NOT be described as coexisting with an app-level CNSRisk clinical engine after retirement. Gap events MUST NOT drive CNS tier transitions in this application. **Implementation status: update during removal; sensor adapters may remain while CNS consumers are deleted.**

#### Scenario: Phase 1 rolls back
- **WHEN** the package compute path is disabled or removed from startup
- **THEN** no database migration or irreversible data-format change is required

#### Scenario: CNS path is removed after retirement
- **WHEN** package CNS compute is deleted as part of klaxon retirement
- **THEN** journaling and HealthKit paths continue without requiring dual app/package clinical engines

#### Scenario: Post-retirement status language
- **WHEN** rollout docs describe Phase 1 compute
- **THEN** they do not claim dual app/package CNS clinical ownership as an active invariant
