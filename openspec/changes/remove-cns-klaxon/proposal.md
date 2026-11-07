# Proposal

## Why

The on-device CNS-depression Klaxon (detection engine, dose-window arming, alarm presentation, server backstop, and related docs) was a generation-one experiment in this repository. That responsibility has moved to the superseding **AnxietyWatch2** stack: a local-first Raspberry Pi vitals core (`vitalsd` / `vitals-core`), multi-modal `klaxond` design, provenance-weighted fusion, and an iPhone client that is explicitly **not** an analysis or tier engine (`analysis.baselines_trends_cns_correlations` → remove in GEN1-PARITY). Keeping a parallel clinical-alert path here creates dual ownership, false product claims, and ongoing review/maintenance cost for a feature this app no longer owns.

**Observed current behavior:** this repo still ships app-level `Services/CNSRisk/`, package `Pipeline/CNS*` types, Settings → CNS Monitoring, medication `cnsDepressantClass`, monitoring session / risk-sample models, watch `cnsKlaxonHaptic` handling, server `backstop` + `alert_channel` + APNs klaxon kinds, public README/FEATURES claims, agent rules that require CNS medical review, and an active OpenSpec plan `complete-clinical-respiratory-safety` that would extend the same path.

**Target behavior:** this app retains general journaling, medication logging (without CNS-class arming), HealthKit/Polar/EMAY/CPAP **observation and trends**, and sync/restore for non-alert data. It does **not** detect CNS depression, escalate alert tiers, sound a klaxon, arm overnight respiratory watches from doses, or claim early-warning/alarm capability. AnxietyWatch2 is the sole home of that product line.

## What Changes

- **BREAKING:** Remove the on-device CNS-depression detection and alarm product surface from the iOS/watchOS app, AnxietyWatchKit package pipeline, and sync server.
- Delete app `AnxietyWatch/Services/CNSRisk/` (quality gate, severity, fusion, tier machine, detection pipeline, alarm presenter/policy, dose-window gate, depressant classifier/class, AS11 stream source used for CNS context, device-state matrix, notification permission helpers tied to klaxon).
- Remove app `CNSMonitoringCoordinator`, Settings/Demo CNS views, medication CNS-depressant picker and arming hooks, and related SwiftData models (`MonitoringSession`, `CNSRiskSampleRecord`) from the production schema and UI.
- Remove package CNS pipeline types (`Pipeline/CNS*`, tier/fusion-centric `PipelineStep`/`PipelineState` alert-command path) while retaining non-alert sensor ingestion/storage work owned by redesign.
- Remove watch klaxon haptic message handling and phone→watch CNS alert transfers.
- Remove server redundant alert channel: `backstop.py`, klaxon-oriented `apns.py` kinds, `api/alert_channel.py`, alert-channel tables/migrations handling going forward, and upload/restore paths for those entities.
- Strip public and contributor documentation claims (README, FEATURES, diagrams, AGENTS/CLAUDE CNS engine sections, portfolio entry for further respiratory-safety klaxon work).
- **Cancel / archive** OpenSpec change `complete-clinical-respiratory-safety` and any converted RR/apnea-as-escalation follow-on that only exists to finish this product in-repo.
- Update redesign (`complete-redesign-v3-migration`) and canonical specs so “package CNS + app CNSRisk coexistence” is no longer a requirement; clinical side-effect ownership tasks become historical removal notes, not dual-engine rules.
- Keep historical completed plan/design records under `docs/plans/completed/` as **archive evidence** (not live instructions), clearly marked superseded by AnxietyWatch2—do not rewrite git history.

### Non-goals

- No changes inside `../AnxietyWatch2` and no merge of the quarantined AnxietyWatch2 branch into this repo.
- No removal of general Polar H10, EMAY oximeter, HealthKit, OSCAR/ez Share/CPAP import, or AirSense **data capture for trends/journals** except where a type exists solely to feed the klaxon (e.g. app AS11 CNS stream adapter, monitoring-session arming).
- No removal of ordinary local notifications used for mood check-ins, dose-anxiety follow-ups, or non-clinical reminders.
- No bulk deletion of unrelated redesign storage/sync/watch-transport work.
- No claim that AnxietyWatch (this repo) remains a clinical monitor after removal.

## Capabilities

### New Capabilities

- `cns-klaxon-retirement`: Durable rules for absence of CNS-depression detection/alarm behavior, documentation claims, and cross-repo ownership boundary after retirement.

### Modified Capabilities

- `sensor-processing`: Remove deterministic package CNS transition, CNS gap-activation, and dual app/package clinical-processing requirements; retain actor-isolated sensor routing and HealthKit ownership for non-alert use.
- `migration-rollout`: Remove “coexistence with app-level CNS processing” as an active rollout invariant.
- `diagnostics-operations`: Drop release metrics that assume continuous BLE CNS monitoring / urgent-alert klaxon latency as a product goal for this app (or restate them as generic sync health only where still applicable).

## Impact

| Area | Impact |
|---|---|
| **iOS app** | Delete CNSRisk services, monitoring coordinator wiring in `AnxietyWatchApp`/`ContentView`, Settings CNS destinations, medication CNS class UI, demo launch arguments (`-demoCNSSequence`). |
| **SwiftData / first-run** | Drop `MonitoringSession` and `CNSRiskSampleRecord` from the model container; migration or destructive lightweight migration policy must be explicit so upgrades do not crash on unknown models. Medication `cnsDepressantClass` field removed or ignored. |
| **AnxietyWatchKit** | Remove or hollow CNS pipeline modules and tests; keep BLE/HealthKit adapters used for ordinary capture; adjust `KitPipelineService` / dependency container so startup does not require CNS coordinators. |
| **watchOS** | Remove `cnsKlaxonHaptic` handling; no clinical haptic storm from phone. |
| **Server** | Retire backstop job, alert-channel API, APNs klaxon payloads; stop accepting/uploading those entities; schema: stop requiring `cns_depressant_class` / alert-channel tables for app operation (additive historical migrations remain; forward code paths gone). |
| **Restore / sync** | Remove entities from export, `ENTITY_QUERIES`, restore importers, and any `RestoreManifest` inventory so upload-without-restore gates stay green. |
| **OpenSpec / docs** | Portfolio priority reshuffle; cancel clinical-respiratory-safety; rewrite public claims; agent instructions no longer mandate CNSRisk reviewers. |
| **HealthKit** | Still read-only; no new types; no writes. |
| **Tests / CI** | Delete or rewrite ~20+ CNS/Klaxon/AS11-stream/AlertChannel test files; full app/server suites must stay green with zero warnings. |
| **User-data-loss risk** | **Moderate for klaxon-only rows** (monitoring sessions, CNS risk samples, alert-channel history, medication CNS class labels). Those rows are meaningless without the engine; journal, doses, HealthKit mirrors, Polar/EMAY samples, and CPAP nights must remain. Document that CNS-specific local/server rows may be dropped or left orphaned and ignored. |
| **Rollback boundary** | Revert the removal PR(s) before release, or restore from git. After production ship, rollback reintroduces code but does not recreate a supported clinical product—AnxietyWatch2 remains authoritative. |
