# Pre-implementation technical accuracy review

**Role:** Independent Technical Accuracy Critic  
**Stage:** Format/storyboard review only; no rendered artifact existed at review time  
**PR scope checked:** PR #16 body/files plus merged implementation at `720609a` / feature head `9066936`  
**Visual approval:** **RESERVED — rendered assets must be reviewed separately**

## Verdict

**Format selection: APPROVED.** Three static aids (architecture, provenance/safety, representative UI montage) are appropriate and safer than a walkthrough video for this PR.

**Storyboards: CORRECTIONS REQUIRED before implementation.** The architecture and provenance storyboards currently flatten several foundations and phased/legacy paths into a more integrated system than the merged code provides. The montage storyboard is approved subject to screenshot provenance/PII review and the conditions below.

## Blocking pre-implementation corrections

### T1 — Architecture must not route every listed input through `SensorRouter`/CNS

**Severity:** Blocking  
**Affected:** `storyboards/architecture.md`

The proposed left lane lists Polar, EMAY, Apple Health, Oura Cloud, Oura BLE, CPAP, and demo fixtures, then instructs the reader to follow sources into one shared router/CNS path. That is not the runtime graph.

- The integrated iOS `KitPipelineService` constructs only `PolarActor`, `EMAYActor`, and `HealthKitAdapterActor`, then passes those three to `SensorRouter`.
- Oura is supported by the router enum and separate bridge/service foundations, but `KitPipelineService` does not construct an `OuraBLEActor`, call `startOuraBLEBridging`, or configure Oura Cloud polling with its router.
- CPAP/imported records and `DemoSeeder` fixtures are app data/UI paths, not `SensorRouter` inputs.
- The isolated full-app Polar/EMAY device simulation adapts legacy view-facing services and deliberately bypasses production BLE/persistence; it is not a production router input.

**Required correction:** Split inputs into at least:

1. **Integrated live pipeline:** Polar actor, EMAY actor, HealthKit adapter → `SensorRouter` → package CNS coordinator → monitoring/cache.
2. **Separate app data/import/UI paths:** Oura Cloud summaries, CPAP/imported records, deterministic fixtures.
3. **Optional foundations, not shown as active integration:** Oura BLE IBI bridge and Oura Cloud IBI-to-router support, labeled “available foundation; not wired by `KitPipelineService`; hardware/configuration dependent.”
4. **Isolated demo lane:** never arrows into production router/storage/HealthKit.

**Evidence:**
- `AnxietyWatch/Services/KitPipelineService.swift:35-104`
- `AnxietyWatchKit/Sources/AnxietyWatchKit/BLE/SensorRouter.swift:5-18,85-137`
- `AnxietyWatchKit/Sources/AnxietyWatchKit/BLE/OuraBLEActor+SensorRouterBridge.swift:5-27`
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Oura/OuraService.swift:5-20,89-148`
- `AnxietyWatch/Utilities/DemoSeeder.swift`
- `AnxietyWatch/Utilities/FullAppDemoDeviceSession.swift:40-72`

### T2 — Keep pipeline output, GRDB, SwiftData, WatchConnectivity, and server paths distinct

**Severity:** Blocking  
**Affected:** `storyboards/architecture.md`, evidence ledger storage/sync rows

The storyboard’s “Storage and outputs” and “Transport and mirror” composition can imply one completed end-to-end route from router → GRDB → WatchConnectivity → server. The merged app has parallel/phased systems:

- `KitPipelineService` produces monitoring snapshots and complication-cache submissions; it does not write those samples to `SamplesStore`.
- The package contains GRDB/HLC stores, a P2P `SyncEngine`, and a REST `SyncCoordinator`, but these are foundations with different lifecycle paths.
- iOS starts the package P2P `syncEngine`; watchOS explicitly does **not** start package `SyncEngine`/`WCSessionCoordinator` because the legacy `WatchConnectivityManager` owns the single delegate during phased migration.
- Watch sensor capture persists through the existing SwiftData path and transfers via the legacy manager.
- The existing app `SyncService` is push-only and calls the personal server a mirror. Package HLC delta sync is a separate foundation and should not be collapsed into that same arrow.
- The watch’s package server endpoint is explicitly no-op; comments say server sync is future Phase 2C.

**Required correction:** Draw separate, named paths and state their maturity:

- **Monitoring output:** router/CNS → monitoring view model; snapshot → complication cache.
- **Package local foundation:** GRDB/HLC stores (do not draw a router-write arrow unless a concrete writer is evidenced).
- **Phone↔watch current path:** legacy `PhoneConnectivityManager` / watch `WatchConnectivityManager` for current app data transfer.
- **Package WatchConnectivity foundation:** `WCSessionCoordinator` + `SyncEngine`; iOS startup exists, watch migration is not complete.
- **Server paths:** existing SwiftData `SyncService` → personal server mirror (push-oriented), separately from package REST/HLC delta-sync foundation. Avoid claiming a fully deployed end-to-end delta path.

Use “foundation,” “phased coexistence,” and “watch-side package transport not started” visibly, not only in alt text.

**Evidence:**
- `AnxietyWatch/Services/KitPipelineService.swift:68-105`
- `AnxietyWatch/App/AnxietyWatchApp.swift:250-303,325-343`
- `AnxietyWatch Watch App/AnxietyWatchApp.swift:99-105,145-176,189-216,284-299`
- `AnxietyWatch Watch App/WatchConnectivityManager.swift`
- `AnxietyWatch/Services/PhoneConnectivityManager.swift`
- `AnxietyWatch/Services/SyncService.swift:7-10`
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Diagnostics/DependencyContainer.swift:120-153,167-197`
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Transport/SyncEngine.swift:3-15`
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Sync/RESTClient.swift:7-11`

### T3 — Correct the Apple Health/Oura “bridge” claim

**Severity:** Blocking  
**Affected:** `storyboards/provenance.md`, evidence ledger

“Oura Cloud,” “Apple Health,” and direct Oura BLE must remain separate. More importantly, the merged `OuraHealthKitAdapter` only requests **read** access to sleep analysis and oxygen saturation (`toShare`/`share` is empty). It does not write Oura Cloud values into HealthKit. The settings label says “Bridge Oura Data to HealthKit,” but the implementation under that control is permission enablement, not a Cloud→HealthKit transfer.

**Required correction:** Use wording such as:

- “Apple Health / HealthKit — separate read/import source (sleep and oxygen permission support)”
- Do **not** draw Oura Cloud → Apple Health or say the PR writes/bridges Cloud observations into HealthKit.
- If documenting the UI control, explicitly distinguish its user-facing label from implemented behavior.

**Evidence:**
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Oura/OuraHealthKitAdapter.swift:5-32`
- `AnxietyWatch/Views/OuraSettingsView.swift:124-131,248-254`
- `AnxietyWatch/Views/OuraIntegratedViews.swift:96,138`

### T4 — Avoid “every metric carries provenance”

**Severity:** Blocking  
**Affected:** `storyboards/provenance.md`

The proposed center legend says “every metric carries provenance.” Evidence supports source-aware labels in specific Oura and demo surfaces, not a universal invariant across every metric in the app.

**Required correction:** Replace with “source-aware presentation labels supported on these surfaces” or “the illustrated Oura/demo surfaces visibly identify source/mode.” Keep each depicted card’s explicit label; do not assert universal metadata/UI coverage.

**Evidence:**
- `AnxietyWatch/Views/OuraDataDashboardView.swift:45-54,163-172`
- `AnxietyWatch/Views/OuraIntegratedViews.swift:81-103,133-149`
- `AnxietyWatch/Views/CNSMonitoringDemoView.swift:4-5,64-74,119-125`

### T5 — Distinguish demo CNS labels from production package tiers

**Severity:** Blocking  
**Affected:** `storyboards/provenance.md`, any CNS montage panel

“Clear → Watch → Confirm → Klaxon” is accurate for the isolated demo view, but it is not the package pipeline’s production `AlertTier` vocabulary (`normal`, `advisory`, `warning`, `critical`). A visual that places that sequence next to the production pipeline without qualification will imply a direct production tier mapping.

**Required correction:** Label the sequence **“isolated demo UI labels”** and state that it is scripted/deterministic and separate from production tier naming/monitoring. Do not draw it as output from the production coordinator.

**Evidence:**
- `AnxietyWatch/Views/CNSMonitoringDemoView.swift:4-31,205-218`
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Pipeline/PipelineState.swift:41-47`

### T6 — Scope “persistence-free” to simulated device observations, not the full demo mode

**Severity:** Blocking  
**Affected:** `storyboards/provenance.md`, `README.md`

The Polar/EMAY `FullAppDemoDeviceSession` and service adapters are side-effect-free for device observations, and tests show no `SensorSession` or `QuantityHealthSample` creation. However, full-app demo launch also calls `DemoSeeder.seedIfNeeded`, which intentionally writes deterministic fixtures to the demo store. Therefore “Full-app demo device session — persistence-free” is safe only if the noun and exclusion are precise; “full-app demo is persistence-free” is false.

**Required correction:** Say: “Simulated Polar/EMAY device observations are not persisted as readings and create no production sensor session.” Add a separate note that deterministic app fixtures may be seeded for screenshots. Keep the DEBUG-only nature of `FullAppDemoMode` if space permits.

**Evidence:**
- `AnxietyWatch/App/AnxietyWatchApp.swift:319-330`
- `AnxietyWatch/Utilities/FullAppDemoDeviceSession.swift:3-15,40-72`
- `AnxietyWatchTests/FullAppDemoDeviceSessionTests.swift:58-83`
- `AnxietyWatch/Services/PolarHRMService.swift:191-285,579`
- `AnxietyWatch/Services/EMAYRealtimeService.swift:358-370,472-514,553-564`

## Non-blocking but required during rendering

### T7 — Oura BLE limitation copy must be stronger than “hardware-dependent”

Include all of these visibly or in the adjacent caption:

- feature-gated/foundation status;
- 16-byte shared-key provisioning is required;
- physical Ring 5 decryption/protocol/key behavior is not validated by this PR;
- actor `connect()` contains protocol-flow placeholders/comments, so do not depict a completed live handshake or confirmed stream.

**Evidence:** `AnxietyWatchKit/Sources/AnxietyWatchKit/BLE/OuraBLEActor.swift:13-24,162-223`; PR #16 “Safety and provenance” and “Follow-up work.”

### T8 — CPAP and EMAY need precise source labels

- CPAP is imported/session data, not a live `SensorRouter` source in the v3 package pipeline.
- EMAY has distinct live BLE and imported historical paths. Avoid one arrow/card that makes “EMAY” provenance ambiguous.

**Evidence:** `AnxietyWatch/Services/EMAYRealtimeService.swift`; `AnxietyWatch/Services/EMAYImporter.swift`; CPAP services/models in `AnxietyWatch/Services/`.

### T9 — UI montage screenshots require artifact-level factual clearance

Before inclusion, verify every selected crop at full resolution:

- only deterministic simulator/demo data;
- no real name, account, device UUID/name, location, token, or notification content;
- source labels (“Oura Cloud,” “Demo Data,” “Simulated”) remain legible;
- no crop makes demo values look like hardware observations;
- CNS panel included only when “Demo simulation only” and no-real-alert language remain readable;
- montage caption says “representative surfaces,” not completed walkthrough or hardware validation.

The storyboard format is approved, but no screenshot is approved merely because it is in `~/anxietywatch-screenshots-verified/`.

### T10 — “Server mirror” should be attributed to the existing app sync path

The phrase is directly supported by `SyncService`, but it should not be attached indiscriminately to every package HLC/REST arrow. Label it “personal server mirror (existing app sync)” and show package delta sync as a separate foundation if included.

## Evidence-ledger recommendations

The current ledger is useful but should be amended before visual implementation:

1. Replace “BLE actors and HealthKit adapter feed `SensorRouter`” with the exact integrated set: Polar, EMAY, HealthKit in `KitPipelineService`; note optional Oura IBI bridges separately.
2. Split “GRDB/storage and HLC/sync/transport foundations exist” into four claims: local GRDB/HLC foundation; package REST delta foundation; package P2P transport foundation; current watch legacy transport. Record lifecycle/wiring status for each.
3. Replace the single WatchConnectivity implication with explicit evidence from both app targets, including the watch-side `SyncEngine` non-start and single-delegate limitation.
4. Add an Oura HealthKit row stating read-permission behavior only; prohibit Cloud→HealthKit write arrows.
5. Add a universal-provenance guardrail: selected screens are source-aware, but “every metric carries provenance” is unsupported.
6. Add the two CNS vocabularies and prohibit conflation of demo (`Clear/Watch/Confirm/Klaxon`) with package tiers (`normal/advisory/warning/critical`).
7. Amend demo persistence evidence: simulated Polar/EMAY readings are side-effect-free; `DemoSeeder` still intentionally seeds deterministic fixtures.
8. Add direct tests as evidence, not comments alone:
   - `AnxietyWatchTests/FullAppDemoDeviceSessionTests.swift`
   - `AnxietyWatchKit/Tests/AnxietyWatchKitTests/OuraBLEActorTests.swift`
   - `AnxietyWatchKit/Tests/AnxietyWatchKitTests/SyncEngineTests.swift` (where claims match test coverage)
   - package pipeline/router/coordinator tests under `AnxietyWatchKit/Tests/AnxietyWatchKitTests/`.
9. Record that planning documents and UI labels are not implementation proof when underlying code is narrower.

## Approval matrix

| Item | Status | Conditions |
|---|---|---|
| Three-aid minimum set | **APPROVED** | Keep static-first approach. |
| Static SVG architecture format | **APPROVED** | Storyboard must resolve T1–T2. |
| Architecture storyboard claims | **CHANGES REQUIRED** | Separate runtime, foundation, legacy/phased, and demo paths. |
| Static SVG provenance format | **APPROVED** | Storyboard must resolve T3–T6 and preserve T7–T8. |
| Provenance storyboard claims | **CHANGES REQUIRED** | Narrow HealthKit, provenance, CNS vocabulary, and persistence claims. |
| Static montage format | **APPROVED** | Every actual crop must pass T9. |
| Montage storyboard | **APPROVED WITH CONDITIONS** | Representative-only; fictional/deterministic; no implied hardware validation. |
| Publication | **NOT REVIEWED** | Conductor responsibility; durable hosting still required. |
| Rendered visual approval | **RESERVED** | Requires inspection of final SVG/PNG and rendered PR layout. |

## Re-review pass criteria

Pre-implementation technical approval can be granted after the storyboards/evidence ledger visibly incorporate T1–T6. Final visual approval requires inspection of the actual rendered artifacts, including arrow geometry, label adjacency, screenshot crops, captions, and GitHub-scale legibility; source review alone will not suffice.
