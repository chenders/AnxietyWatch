# Sensor Processing Delta

## ADDED Requirements

### Requirement: Sensor processing remains non-alerting
AnxietyWatch SHALL expose only ordinary sensor routing and `normal`/`idle` presentation state. CNS detection, risk fusion, alert tiers, and klaxon behavior belong to AnxietyWatch2.

#### Scenario: Sensor activity changes
- **WHEN** a subscribed source becomes active or idle
- **THEN** the package updates presentation state without scheduling notifications, playing audio, producing haptics, or sending watch alert messages

### Requirement: Authoritative gaps enable gap processing
The application SHALL enable package gap processing only after the active storage path emits transactional tombstones and sensor/storage consumers process their ranges without creating risk scores or alerts.

#### Scenario: Phase 2A gap validation passes
- **WHEN** an evicted range produces a persisted, synced, and replayed tombstone in integration tests
- **THEN** the gap-events flag may be enabled for the validated rollout cohort
