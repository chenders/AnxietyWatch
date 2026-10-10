# Tasks

## 1. Establish the current baseline

- [ ] 1.1 Inventory Oura cloud, OAuth, server, UI, HealthKit-adapter, and BLE foundations using `AnxietyWatchKit/Sources/AnxietyWatchKit/Oura/`, `BLE/Oura*`, `AnxietyWatch/Views/Oura*`, server Oura code, and tests; add implemented/tested/app-wired/production-authoritative states to `design.md`, verified by code and test links.
- [ ] 1.2 Inventory Apple Watch/Ultra sensor capture and each proposed Action button, voice, State of Mind, location, ECG, prediction, and Smart Stack capability against current targets and entitlements; record separate status rows with no group-level inference.

## 2. Decide the Oura roadmap

- [ ] 2.1 Verify current official Oura API, OAuth, data availability, rate limits, account access, terms, and branding requirements; record dated primary-source links and an accept/defer/reject impact for the existing cloud path.
- [ ] 2.2 Validate the existing Oura cloud flow with a designated non-production account through authorization, refresh, offline retry, server sync, and revocation; record redacted observable results without credentials or health payloads.
- [ ] 2.3 Evaluate direct Oura BLE protocol stability, latency benefit, battery cost, permission flow, maintenance burden, and cloud fallback; record an explicit accept, defer, reject, or research decision with a re-evaluation trigger.

## 3. Decide the Apple platform roadmap

- [ ] 3.1 Produce an individual decision record for Action button and voice workflows, including supported OS/hardware, background limits, privacy, fallback, and testability; verify each decision has authoritative sources and a follow-on owner if accepted.
- [ ] 3.2 Produce individual decision records for State of Mind and ECG, explicitly checking the HealthKit read-only ownership rule and clinical interpretation boundary; verify no accepted decision silently authorizes HealthKit writes.
- [ ] 3.3 Produce individual decision records for location, predictive classifiers, next-day prediction, and Smart Stack, including consent, retention, explainability, battery, and unavailable-data behavior.

## 4. Convert accepted decisions into owned work

- [ ] 4.1 For each accepted capability, create a focused OpenSpec change with proposal, behavioral specs, design, tasks, data ownership, restore/export, first-run, permissions, tests, rollout, and rollback; verify `openspec validate --strict` succeeds for every new change.
- [ ] 4.2 Mark every non-accepted capability deferred, rejected, or research with rationale and a concrete re-evaluation trigger; verify no undecided legacy task remains outside the decision table.
- [ ] 4.3 Update `openspec/PORTFOLIO.md` with the resulting implementation plans and archive this roadmap after all decisions have durable owners.
