## ADDED Requirements

### Requirement: Release evidence matrix
Every production-affecting change SHALL record which static, unit, simulator, fresh-install, restore, physical-device, server-integration, accessibility, and performance checks apply and the result of each required check. **Implementation status: not implemented as a unified matrix.**

#### Scenario: Hardware-dependent change lacks device evidence
- **WHEN** a release candidate changes BLE or watch lifecycle behavior but has no physical-device result
- **THEN** the evidence matrix labels that path unvalidated and release status cannot claim hardware completion

### Requirement: Evidence distinguishes execution environments
Validation records MUST identify the target, environment, configuration, and authoritative path exercised. **Implementation status: partial.**

#### Scenario: Simulator test uses a mock provider
- **WHEN** a simulator test passes against a mock sensor
- **THEN** the evidence records mock coverage and does not imply that physical transport was tested
