# Tasks

## 1. Reconcile the inherited experience backlog

- [ ] 1.1 Compare `docs/plans/converted/expert-review-improvement-plan.md` and `phase-4-polar-integration.md` with current Views, Services, models, and tests; add a finding table to `design.md` marking each residual item satisfied, actionable, deferred, rejected, or obsolete, verified by a code/test path for every disposition.
- [ ] 1.2 Order actionable vertical slices by medical correctness, data preservation, and user benefit; update `openspec/PORTFOLIO.md` and this task order, verified by having exactly one owning task for each accepted item.

## 2. Complete Polar session continuity

- [ ] 2.1 Extend supported Trends chart selection into `PolarSessionHRDetailView.swift` using shared session identity/time context, adding Swift tests for selection mapping and SwiftUI accessibility labels; verify each accepted Polar chart reaches the correct session.
- [ ] 2.2 Finish simple/advanced Polar presentation in the Trends views and `LFHFExplainerSheet.swift`, with tests or snapshots for plain language, methodology, missing data, VoiceOver, and large Dynamic Type.
- [ ] 2.3 Add accepted daytime-session, interruption, and server re-derivation metadata only where current models lack it; update client/server tests and verify every app-only field uploads, queries, restores, and avoids duplicate re-upload.

## 3. Complete provenance-aware metric detail

- [ ] 3.1 Define a shared presentation contract for source, unit, timestamp, freshness, invalidity, and arbitration, then apply it to heart rate, HRV, RR, and SpO2 detail views with unit tests and accessibility assertions.
- [ ] 3.2 Apply the contract to glucose and remaining accepted metrics, including time-in-range semantics where supported; verify mixed-source fixtures never silently merge incompatible observations.
- [ ] 3.3 Run `medical-data-accuracy-reviewer`, `swiftui-render-pitfall-detector`, and `chart-ux-auditor` for changed Trends/data paths and resolve required findings before marking the metric group complete.

## 4. EMAY, reports, and medication context

- [ ] 4.1 Decide the supported EMAY waveform/import provider path using `EMAYImporter.swift`, `EMAYRealtimeService.swift`, package EMAY code, and current device documentation; record the decision and implement the accepted slice with parser/import tests and export/restore coverage.
- [ ] 4.2 Implement accepted report and dose-overlay gaps in their current views/models, with tests proving known time/source, association-not-causation copy, missing-data behavior, and export consistency.
- [ ] 4.3 Implement accepted refresh and notification-action gaps with view/service tests proving offline, retry, and duplicate-action behavior; leave unrelated notification safety behavior unchanged.

## 5. Settings and integrated release

- [ ] 5.1 Complete only the settings status, appearance, provider, and privacy items accepted by the reconciliation table, with SwiftUI tests for current state, failure state, VoiceOver, and large Dynamic Type.
- [ ] 5.2 Run targeted tests with each slice and then the integrated zero-warning app test/build; verify no chart performs an async hardware read or introduces an unbounded query.
- [ ] 5.3 Run `swift-pre-pr-reviewer` plus relevant specialist reviews and record implementation state as implemented, tested, app-wired, and production-authoritative separately for each slice.

## Workflow follow-up

- Archive the change only after every accepted item is complete or explicitly split into a new focused change.
