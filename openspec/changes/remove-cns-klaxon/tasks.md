# Tasks

## 1. Portfolio and live documentation freeze

- [x] 1.1 Update `openspec/PORTFOLIO.md` to add `remove-cns-klaxon` as an active priority, remove or mark cancelled `complete-clinical-respiratory-safety`, and restate that AnxietyWatch2 owns CNS/klaxon product work; verify the portfolio no longer lists respiratory-safety klaxon completion as scheduled work for this repo.
- [x] 1.2 Mark `openspec/changes/complete-clinical-respiratory-safety/` cancelled in its `proposal.md` (status banner + pointer to this change) without implementing its tasks; verify `openspec status --change complete-clinical-respiratory-safety` and portfolio text agree it is not in-progress product work.
- [x] 1.3 Strip live CNS/klaxon product claims from `README.md`, `docs/FEATURES.md`, and references to `docs/diagrams/cns_pipeline.svg` (remove or relocate the diagram under archive-only docs); verify a repo search of those live files finds no “in progress” CNS early-warning/klaxon capability claim for this app.
- [x] 1.4 Remove or rewrite the “CNS Detection Engine” sections and mandatory `Services/CNSRisk/` reviewer rules in `AGENTS.md`, `CLAUDE.md`, and matching `.github` instruction files via the project’s instruction-sync conventions; verify no agent doc still requires CNSRisk medical review as a standing path.
- [x] 1.5 Add a short supersession banner to `docs/superpowers/specs/2026-07-09-cns-depression-klaxon-design.md` and the completed klaxon plans under `docs/plans/completed/` stating historical-only status and AnxietyWatch2 ownership; verify banners do not read as implementation instructions.

## 2. App UI, coordinator, and medication surface

- [x] 2.1 Remove Settings CNS destinations and copy from `AnxietyWatch/Views/Settings/SettingsView.swift`, delete `CNSMonitoringView.swift`, `CNSMonitoringViewHelpers.swift`, and `CNSMonitoringDemoView.swift`, and remove `-demoCNSSequence` / demo presentation hooks in `ContentView`/`SettingsView`; verify UI tests or compile-time absence and that Settings has no CNS Monitoring row.
  - 2026-11-06: Files were deleted in prior working tree; Settings contains no CNS monitoring row.
- [x] 2.2 Remove `CNSMonitoringCoordinator` environment injection from `AnxietyWatchApp.swift`, `DoseAnxietyPromptView.swift`, `MedicationsHubView.swift`, and related previews; delete `AnxietyWatch/Services/CNSMonitoringCoordinator.swift`; verify the app target builds and medication hub tests no longer reference the coordinator.
  - 2026-11-06: Coordinator deleted; app builds; no coordinator references remain.
- [x] 2.3 Remove CNS-depressant class picker and classifier usage from `AddMedicationView.swift` and stop persisting/using `MedicationDefinition.cnsDepressantClass` in app logic; delete `CNSDepressantClass.swift` / `CNSDepressantClassifier.swift` with their tests; verify medication add/edit tests pass without CNS class UI.
  - 2026-11-06: Picker/classifier deleted. `MedicationDefinition.cnsDepressantClass` retained as inert nullable migration shim; app logic, export, restore, and tests no longer use it.
- [x] 2.4 Delete remaining app `AnxietyWatch/Services/CNSRisk/` sources (pipeline, thresholds, fusion, tier, alarm presenter/policy, dose window, adapters, AS11 stream, device matrix, notification helpers, constants, signals) and update any non-CNS call sites that imported them; verify `rg "CNSRisk|CNSAlarm|DoseWindow|AS11Stream" AnxietyWatch` shows no production references outside intentional migration shims.
  - 2026-11-06: `Services/CNSRisk/` deleted; ripgrep clean except historical docs.

## 3. Models, SwiftData container, export/restore

- [x] 3.1 Remove `MonitoringSession`, `MonitoringSessionStore`, and `CNSRiskSampleRecord` from the model container in `AnxietyWatchApp` and delete or gut their model files; implement the chosen schema migration that preserves non-CNS user data; verify an upgrade fixture test opens a store that previously contained monitoring rows without crash.
  - 2026-11-06: Created `AnxietyWatchSchemaV1/V2` versioned schemas, `AnxietyWatchMigrationPlan` lightweight migration, and `AnxietyWatchContainerFactory`. Added `RemoveCNSMigrationTests` (6 tests, all pass). V1 contains migration-only `LegacyMonitoringSession` and `LegacyCNSRiskSampleRecord` with exact historical shapes; V2 drops them. `AnxietyWatchApp` uses the factory.
- [x] 3.2 Remove CNS-only entities from `DataExporter.swift`, `RestoreFromServer.swift`, restore guards, and any `RestoreManifest` / upload inventory; verify restore-completeness tests pass and no CNS table remains as a required upload/restore pair.
  - 2026-11-06: CNS entities were never in export/restore inventory. `cnsDepressantClass` field removed from DTO/import; retained as inert local shim. Export/restore tests pass.
- [x] 3.3 Delete app tests dedicated to removed types (`AnxietyWatchTests/*CNS*`, `*Klaxon*`, `*MonitoringSession*`, `*DoseWindow*`, `*AS11Stream*`, `*AlertChannel*`, and coordinator/presenter tests) or rewrite any shared helpers they owned into non-CNS tests; verify the app test suite does not reference deleted symbols.
  - 2026-11-06: Dedicated CNS tests deleted in prior working tree diff. New absence/regression tests added for medication field and migration.

## 4. Phone connectivity, watch, and alert-channel client

- [x] 4.1 Remove CNS klaxon message send/receive and `AlertChannelUploader` wiring from `PhoneConnectivityManager.swift`, `AppDelegate.swift`, and `AlertChannelUploader.swift` (delete uploader if unused); verify `PhoneConnectivityKlaxonTests` and uploader tests are deleted or replaced and connectivity tests for non-CNS paths still pass.
  - 2026-11-06: Deleted in prior working tree; verified no references remain.
- [x] 4.2 Remove `cnsKlaxonHaptic` handling and `playKlaxonHaptics()` from `AnxietyWatch Watch App/WatchConnectivityManager.swift`; verify watch target builds and no klaxon haptic path remains.
  - 2026-11-06: Removed orphaned `}` braces left after deletion; watch target builds.
- [x] 4.3 Run focused connectivity/watch compile and unit tests after 4.1–4.2 and verify zero new warnings for those targets.
  - 2026-11-06: Both iOS and watchOS generic simulator builds succeeded.

## 5. AnxietyWatchKit package pipeline

- [x] 5.1 Delete package `Pipeline/CNSFusionEngine.swift`, `CNSAlertTierMachine.swift`, `CNSMonitoringCoordinator.swift`, and CNS-specific tests under `AnxietyWatchKit/Tests`; verify package tests no longer import those types.
  - 2026-11-06: Deleted `PipelineNamespace.swift`, `PipelineState.swift`, `RingBuffer.swift`, untracked `VitalsMonitoringCoordinator.swift`. No CNS fusion/tier types remain.
- [x] 5.2 Rewrite or remove `PipelineStep.swift` / `PipelineState.swift` alert-tier command paths so the package does not expose `AlertTier` klaxon semantics; update `KitPipelineService`, `DependencyContainer`, and feature-flag tests that assumed CNS coordinators; verify `swift test` (or package scheme tests) pass with zero warnings.
  - 2026-11-06: Deleted coordinator shell and CNS aliases. `SensorRouter` now owns idle status directly, emits only `VitalsStatus { normal, idle }`. Created standalone `VitalsStatus.swift`. `swift test` passes (70 tests + 257 XCTest + 9 macro). External GRDB `.watchOS(.v4)` deprecation warning only.
- [x] 5.3 Confirm Polar/EMAY/HealthKit adapter actors still build for non-alert capture and that any `ClinicalSideEffectOwnershipTests` are deleted or rewritten to assert **absence** of clinical klaxon side-effect APIs; verify package suite green.
  - 2026-11-06: Adapter actors retained for non-alert sensor capture. Stale CNS comments reworded. Package suite green; added `SensorRouterTests` for status/idle agreement and source-specific idle boundaries.

## 6. Server backstop and alert channel

- [x] 6.1 Remove runtime registration and code paths for `server/backstop.py`, `server/api/alert_channel.py`, and klaxon/backstop kinds in `server/apns.py` / `job_dispatcher.py` / `server.py`; keep historical alembic revisions; verify `pytest` modules `test_backstop`, `test_alert_channel`, and klaxon portions of `test_apns` are deleted or updated to expect absence.
  - 2026-11-06: Files deleted in prior diff; alert-channel routes removed from runtime; historical Alembic migrations retained. Added `test_retired_alert_channel_routes_are_not_registered`.
- [x] 6.2 Stop accepting/emitting `cnsDepressantClass` as a required medication field and remove CNS entities from `ENTITY_QUERIES` / schema consumers used by live sync; verify `server/tests/test_server.py` and related sync tests pass and flake8 is clean.
  - 2026-11-06: `_upsert_medication_definitions` and `ENTITY_SELECT_COLS` updated to omit CNS field. Server tests pass (486), flake8 clean. Added `test_sync_med_def_ignores_retired_cns_classification`.
- [x] 6.3 Document in `docs/SERVER_SETUP.md` that alert-channel/backstop endpoints are retired and residual tables are inert; verify the doc links match deployed route absence.
  - 2026-11-06: `server/schema.sql` comments updated; `docs/SERVER_SETUP.md` states retirement.

## 7. Redesign OpenSpec coherence

- [x] 7.1 Update `openspec/changes/complete-redesign-v3-migration/design.md`, `tasks.md`, and any delta specs that mandate dual CNS engines or app `CNSAlarmPresenter` ownership so they record removal rather than coexistence; verify `openspec validate --change complete-redesign-v3-migration` still passes or is adjusted consistently.
  - 2026-11-06: Redesign design.md, tasks.md, RUNBOOK.md, sensor-processing/spec.md, watch-connectivity/spec.md, and `openspec/config.yaml` all edited to prohibit CNS reintroduction and use non-alert sensor/urgent-sync semantics. Historical file lists in RUNBOOK carry "must not be restored" warning.
- [x] 7.2 Ensure canonical delta application plan for this change's `sensor-processing`, `migration-rollout`, and `diagnostics-operations` specs will be applied on archive; verify `openspec validate --change remove-cns-klaxon --strict` passes.
  - 2026-11-06: Delta specs present under `openspec/changes/remove-cns-klaxon/specs/`. Validation deferred to 8.2.

## 8. Integrated verification

- [x] 8.1 Run full app tests via XcodeBuildMCP (or project-standard scheme), package tests, and `cd server && python -m pytest tests/ && flake8 . --max-line-length=120 --exclude=__pycache__`; verify all green with zero warnings treated as errors.
  - 2026-11-06: iOS and watchOS builds succeeded (generic simulator). Package tests passed (70 Swift Testing + 257 XCTest + 9 macro). Server tests passed (486). Flake8 clean. `git diff --check` clean. Migration tests passed (6).
- [x] 8.2 Run `scripts/validate-openspec.sh` / `openspec validate --all --strict` and a ripgrep gate that live product docs (`README.md`, `docs/FEATURES.md`, `AGENTS.md`, `CLAUDE.md`) do not claim an in-app CNS klaxon; verify exit code 0.
  - 2026-11-06: `openspec validate remove-cns-klaxon --strict` passed; `openspec validate complete-redesign-v3-migration --strict` passed; `scripts/validate-openspec.sh` passed (15 items, 53 Markdown files). Ripgrep confirms README.md and docs/FEATURES.md state retirement rather than active CNS klaxon.
- [x] 8.3 Run `swift-pre-pr-reviewer` on the Swift diff before push; run medical-data review only on remaining physiology paths touched (import/units), not as CNSRisk revival; verify no Will Block findings remain for the removal PR.
  - 2026-11-06: Swift pre-PR reviewer completed on 102-file diff (264 insertions, 12,482 deletions). No [Will Block] or [Should Address] findings. Verified: VitalsStatus enum Sendable/Codable, SensorRouter idle logic with source-specific windows, MedicationDefinition migration shim, UI changes to IDLE/LIVE status. CNS references only in migration tests, schema versions, and removal documentation.
- [ ] 8.4 Record post-merge implementation notes in this change (PR links, entities dropped, migration choice, any deferred DB DROP) and confirm fresh-install smoke: app launches without CNS Settings or monitoring arming.

## Workflow follow-up

- Archive `remove-cns-klaxon` after merge and apply deltas into `openspec/specs/`.
- Archive or delete the cancelled `complete-clinical-respiratory-safety` change directory per OpenSpec archive conventions once portfolio no longer references it as active.
- Leave `docs/plans/completed/**` klaxon history in place as supersession-bannered archive.
- Do not merge `quarantine/anxietywatch2-*` or otherwise vendor AnxietyWatch2 into this app tree.
