## MODIFIED Requirements

### Requirement: Active iPhone sensor pipeline
The iPhone application SHALL route configured Polar, EMAY, HealthKit, and explicitly trusted respiratory-source observations through actor-isolated adapters and a shared sensor router before deterministic package CNS processing. Respiratory observations lacking the clinical respiratory safety contract MUST NOT enter a production-authoritative risk path. **Implementation status: Polar, EMAY, and HealthKit path active; additional respiratory-source activation not implemented.**

#### Scenario: Supported live observation arrives
- **WHEN** a configured Polar, EMAY, HealthKit, or trusted respiratory source emits a valid supported observation
- **THEN** the router delivers it to the package pipeline without requiring a SwiftUI view read to await hardware work

#### Scenario: Respiratory source is not approved
- **WHEN** a respiratory observation arrives from a source without an active trust and quality contract
- **THEN** the router excludes it from the production-authoritative CNS risk path
