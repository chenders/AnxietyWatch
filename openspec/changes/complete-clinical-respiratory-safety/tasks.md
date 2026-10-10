# Tasks

## 1. Establish the evidence boundary

- [ ] 1.1 Audit `AS11StreamSource.swift`, `AS11StreamModels.swift`, `CNSSensorAdapters.swift`, server context-feed code, and their tests against the converted AS11 and RR/apnea plans; record supported fields, units, cadence, timestamps, and unavailable fields in this change's `design.md`, verified by source links and fixture output.
- [ ] 1.2 Obtain medical-data-accuracy review of proposed RR/apnea source admission, threshold, medication-interaction, and clearing rules; record accepted rules and rejected assumptions in `design.md`, verified by a reviewer report with no unresolved Will Block finding.

## 2. Trusted respiratory ingestion

- [ ] 2.1 Add source-specific respiratory validation to `AnxietyWatch/Services/CNSRisk/CNSSensorAdapters.swift` and related models, with tests covering units, freshness, impossible values, missing quality, and unknown sources; verify the targeted CNSRisk test suite passes.
- [ ] 2.2 Route admitted observations through `CNSDetectionPipeline.swift` without changing existing HealthKit ownership or UI actor boundaries, adding deterministic routing tests; verify rejected observations contribute no commands or state transition.
- [ ] 2.3 Add privacy-safe diagnostics for rejected, stale, disconnected, and faulted respiratory observations, with log/export tests proving no physiological payload or identifier is emitted.

## 3. Independent escalation and safe clearing

- [ ] 3.1 Add RR/apnea configuration only through `CNSThresholds.swift` and implement the independent escalation transition in the CNSRisk pipeline, with injected-clock tests for persistence, anti-flapping, escalation without SpO2, and threshold boundaries.
- [ ] 3.2 Implement indeterminate/fault handling so missing or disconnected respiratory data cannot clear an active warning, with state-machine tests covering reconnect, invalid samples, and recovery.
- [ ] 3.3 Add a disabled-by-default runtime control and shadow-result diagnostics for the respiratory path, with tests proving both control values and rollback to existing authoritative behavior.

## 4. Restore and lifecycle correctness

- [ ] 4.1 Audit dose and monitoring records used by CNSRisk through `RestoreFromServer.swift`, server `ENTITY_QUERIES`, and sync encoders; add missing symmetric restore coverage and fresh-store tests that assert stable IDs, `syncedToServer`, empty-store guards, and second-sync idempotency.
- [ ] 4.2 Refactor the AS11 connection callback boundary to permit deterministic stale-socket injection and add tests proving a retired callback cannot replace current connection or clinical state.
- [ ] 4.3 Run and record physical AirSense lifecycle checks for connect, disconnect, reconnect, background/foreground, network loss, and stale callbacks; verify the completed matrix identifies hardware, app build, and observed result.

## 5. Review and controlled activation

- [ ] 5.1 Run the relevant CNSRisk, restore, server, and app tests plus a zero-warning build; record exact commands/results in this change and keep activation disabled on any failure.
- [ ] 5.2 Run `medical-data-accuracy-reviewer` and `swift-pre-pr-reviewer` on the complete diff and resolve all required findings; record any explicit deferral in the change notes.
- [ ] 5.3 Enable the respiratory path only after shadow, fresh-install, restore, and physical-device gates pass; verify disabling the control restores prior production behavior without deleting observations.

## Workflow follow-up

- Archive the change after production activation evidence and documentation are complete.
