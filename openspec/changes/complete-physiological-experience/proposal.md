# Proposal

## Why

Several shipped sensor foundations still end in inconsistent or incomplete user experiences, especially Polar session exploration, provenance-aware metric detail, EMAY data presentation, and reports. Grouping these by the user's physiological-data journey creates a coherent delivery plan without mixing them into storage migration or speculative hardware work.

## What Changes

- Complete Polar session drill-down across relevant charts and finish the simple/advanced, accessibility, and methodology presentation work.
- Define and complete provenance-aware detail experiences for heart rate, HRV, respiratory rate, SpO2, glucose, and supported session-derived metrics.
- Decide and implement the supported EMAY waveform/import experience using validated source metadata.
- Consolidate report, medication-effect, dose-overlay, refresh, notification-action, and related expert-review gaps into prioritized experience increments.
- Re-audit older expert-review tasks against current code before implementation and explicitly retire obsolete requests.
- Require exportability, plain-language explanations, accessibility, and graceful missing-data behavior for each delivered increment.

## Capabilities

### New Capabilities

- `physiological-experience`: User-facing exploration, provenance, reporting, and action behavior for physiological and session data.

### Modified Capabilities

- None.

## Impact

Likely affected surfaces include Trends and metric-detail views, Polar session views, EMAY import/presentation, reports, medication overlays, settings, notifications, and accessibility tests. HealthKit remains read-only and authoritative for its data. Server or restore work is required only when an app-only record is added or changed, and every such record must have an explicit down path. The rollback boundary is feature-level: existing dashboards and detail views remain available until each replacement has parity. User-data-loss risk is low, but misleading aggregation or provenance is a medical-data accuracy risk.
