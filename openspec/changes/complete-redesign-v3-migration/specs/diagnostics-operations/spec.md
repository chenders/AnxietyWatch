# Diagnostics and Operations Delta

## ADDED Requirements

### Requirement: Diagnostics is reachable and live
Settings SHALL expose the diagnostics screen using snapshots from active storage, sync, clock, transport, and feature-control providers without directly awaiting actors in view rendering.

#### Scenario: User opens diagnostics
- **WHEN** active components have current state
- **THEN** the screen shows a coherent timestamped snapshot and clearly labels unavailable providers

### Requirement: Diagnostic export is user-invocable
The diagnostics screen SHALL invoke the redacted export engine and present a shareable result or a privacy-safe failure without retaining unbounded temporary files.

#### Scenario: Export succeeds
- **WHEN** the user requests a support bundle
- **THEN** the app creates a bounded redacted archive and offers it through the platform sharing flow

### Requirement: MetricKit reports release evidence
The watch and phone applications SHALL register a MetricKit reporter that records peak-memory and runtime diagnostics using non-identifying dimensions and feeds the defined release checks.

#### Scenario: Metric payload arrives
- **WHEN** the operating system delivers a MetricKit payload
- **THEN** the app extracts the defined aggregate metrics without logging raw personal data

### Requirement: Instrumentation coverage is verified
Tests or review evidence SHALL verify signpost coverage for sensor parsing, storage batches, sync attempts, transfers, and watch refresh lifecycles.

#### Scenario: Release evidence is assembled
- **WHEN** a redesign phase requests rollout approval
- **THEN** the evidence includes current memory, battery, latency, overflow, corruption, and divergence results for that phase
