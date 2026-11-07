# Spec Delta

## MODIFIED Requirements

### Requirement: Operational release metrics
Release evaluation SHALL measure privacy-safe operational health for remaining product paths (storage, sync, optional BLE capture used for trends). Release criteria MUST NOT require continuous BLE CNS-monitoring battery budgets or P95 urgent CNS-klaxon alert sync latency as product acceptance gates for this application. **Implementation status: targets restated by this change; prior CNS-specific baselines are historical.**

#### Scenario: Candidate lacks a required baseline
- **WHEN** a rollout phase has no current memory, battery, or latency baseline relevant to its non-alert path
- **THEN** the phase is not declared production validated

#### Scenario: CNS-specific latency gate is proposed
- **WHEN** a checklist still lists urgent-alert klaxon sync latency as a release gate for this app
- **THEN** that gate is removed or marked superseded rather than blocking unrelated shipping work
