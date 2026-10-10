# Proposal

## Why

The CNS warning system exists, but the remaining respiratory-safety work is scattered across an unstarted RR/apnea proposal, deferred clinical-review notes, and incomplete AirSense 11 hardware validation. These items belong together because they all determine whether respiratory evidence can safely escalate, clear, or suppress a clinical warning.

## What Changes

- Establish a trusted-source and quality contract for continuous respiratory-rate and apnea observations.
- Add an independently testable RR/apnea escalation path with explicit stale, disconnected, invalid, and indeterminate behavior.
- Complete the deferred clinical review of medication interaction, threshold, and classifier assumptions before changing production alert behavior.
- Re-verify first-run and restored-install CNS monitoring, including dose-event availability and re-arming behavior.
- Finish physical AirSense 11 lifecycle validation and the stale-socket callback race harness.
- Keep all new clinical behavior disabled until source fidelity, tests, medical-data review, and rollback evidence pass.

## Capabilities

### New Capabilities

- `clinical-respiratory-safety`: Trust, quality, escalation, fault-suppression, and clinical-review requirements for respiratory safety signals.

### Modified Capabilities

- `sensor-processing`: Extend the production ingestion boundary only for respiratory sources that meet the new trust and quality contract.

## Impact

Likely affected surfaces include CNSRisk, sensor adapters, AirSense context ingestion, dose-event monitoring, diagnostics, and their tests. HealthKit remains authoritative for HealthKit-owned observations; no HealthKit writes are introduced. Server and watchOS behavior changes only if a later implementation task proves a required source path. First-run and restore tests are required. The rollback boundary is a runtime-disabled respiratory path with existing CNS behavior left authoritative. User-data-loss risk is low because this change adds no destructive migration, but false escalation or false reassurance is a high clinical risk.
