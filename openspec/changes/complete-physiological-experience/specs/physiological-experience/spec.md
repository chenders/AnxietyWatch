## Purpose

Defines a coherent, accessible, provenance-aware user experience for exploring physiological observations, recording sessions, and understanding their relationship to symptoms and medications.

## ADDED Requirements

### Requirement: Provenance-visible metric detail
Every supported physiological detail view SHALL identify the data source, measurement time, unit, freshness, and unavailable or invalid state without implying certainty the source does not provide. **Implementation status: partial.**

#### Scenario: Same metric has multiple sources
- **WHEN** a user opens a metric that contains observations from more than one source
- **THEN** the view distinguishes the sources and explains any arbitration or separation applied

### Requirement: Session drill-down
Users SHALL be able to move from a charted session interval to the corresponding session detail while retaining the selected time context. **Implementation status: partial for Polar heart-rate sessions.**

#### Scenario: User selects a Polar session interval
- **WHEN** a supported chart mark or session row is activated
- **THEN** the app opens the matching session detail and preserves the selected interval

### Requirement: Simple and advanced explanations
Complex physiological metrics SHALL provide a plain-language default explanation and an optional advanced methodology view. **Implementation status: partial.**

#### Scenario: User requests methodology
- **WHEN** the user expands an advanced explanation
- **THEN** the view describes calculation, source limitations, units, and known missing-data behavior without presenting medical diagnosis

### Requirement: Accessible physiological presentation
Charts, controls, and status indicators SHALL remain understandable with VoiceOver, increased Dynamic Type, reduced motion, and without color as the sole carrier of meaning. **Implementation status: partial.**

#### Scenario: VoiceOver focuses a chart element
- **WHEN** an accessible chart mark receives focus
- **THEN** its label states metric, value, unit, time, source context when material, and availability state

### Requirement: Explicit missing and stale states
Physiological views MUST distinguish no data, stale data, invalid data, disconnected source, and confirmed normal data. **Implementation status: partial.**

#### Scenario: Live provider disconnects
- **WHEN** a live provider stops producing current observations
- **THEN** the UI shows a disconnected or stale state and does not preserve the last value as if it were current

### Requirement: Export and restore coverage
Any new app-only physiological or session record SHALL be exportable and SHALL have an explicit server persistence and restore path before production release. **Implementation status: active project rule; requires per-feature verification.**

#### Scenario: Device is replaced
- **WHEN** a supported app-only session has previously synchronized and the user restores to an empty installation
- **THEN** the record returns with stable identity and without duplicate re-upload

### Requirement: Medication and report context
Reports and trend views SHALL present medication or dose overlays only when their time and source are known, and SHALL describe associations without asserting causation. **Implementation status: partial.**

#### Scenario: Dose overlaps a physiological change
- **WHEN** a report displays a dose beside a metric change
- **THEN** the presentation identifies temporal association and avoids claiming that the medication caused the change

### Requirement: Obsolete-request disposition
Legacy experience requests SHALL be checked against current behavior and intentionally implemented, deferred, rejected, or marked already satisfied before they become development tasks. **Implementation status: this change establishes the requirement.**

#### Scenario: Legacy checklist conflicts with current product direction
- **WHEN** a requested feature has since been retired or superseded
- **THEN** the plan records the disposition and does not reintroduce it silently
