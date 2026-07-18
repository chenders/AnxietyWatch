# Rendered technical accuracy review — iteration 1

**Role:** Independent Technical Accuracy Critic  
**Artifacts inspected as rendered PNGs:**

- `docs/pr16-visuals/rendered/architecture.png` — 1600×940, SHA-256 `2d972994af0fdc21a89b947a8c08196123d2c7a49c4fa0134ff1ce1ac65401c2`
- `docs/pr16-visuals/rendered/provenance.png` — 1600×940, SHA-256 `173ffc6661d219414f3575518526b679df39c81fee0e2e2c0cbfa739cbca79e1`
- `docs/pr16-visuals/rendered/ui-montage.png` — 1800×1360, SHA-256 `c790e86557bbba0899255d76997067536471c9a1737afe76db5d847ddd44e556`

The PNGs were inspected at intrinsic size, by extracted quadrants/regions, and with OCR to verify the text actually present in raster output. SVG/source was consulted afterward only to disambiguate arrow endpoints and exact wording. `preimplementation-technical.md` was verified saved before this review (SHA-256 `61687caad26ce1d85fa78fb93434a7188db667ba3121d0341143a2c5e59d598a`).

## Verdict: **ITERATE**

The montage is technically acceptable with one caption/selection caveat, but the architecture and provenance renders retain several blocking inaccuracies identified before implementation. In particular, arrow geometry communicates unsupported runtime integrations, and qualifiers still overstate HealthKit bridging and universal provenance. **Do not publish iteration 1.**

## Blocking findings

### TA1 — Architecture’s only input arrow visually routes Apple Health **and Oura Cloud** into the production adapter/router pipeline

**Artifact:** `architecture.png`  
**Severity:** Blocking

The rendered “observations” arrow begins at the right edge of the Apple Health/Oura Cloud row and terminates at “Adapters and sensor actors.” Because the row contains both cards and there are no separate source arrows from Polar or EMAY, the image’s dominant reading is that Oura Cloud daily summaries feed the same integrated adapter path while the live Polar/EMAY cards do not visibly connect. The SVG description is even broader: it says all listed inputs “feed shared routing and CNS processing.”

That is not the merged runtime graph:

- `KitPipelineService` constructs `PolarActor`, `EMAYActor`, and `HealthKitAdapterActor` and passes only those three to `SensorRouter`.
- Oura Cloud can convert polled IBI into router samples when a separately configured `OuraService` is started with a router, but the app’s `KitPipelineService` does not configure or wire that service.
- CPAP and Oura daily summaries are app data/UI paths, not production `SensorRouter`/CNS inputs.
- Direct Oura BLE bridging is a separate optional method and is not called by `KitPipelineService`.

**Required correction:** Use explicit arrows from **Polar H10**, **EMAY live BLE**, and **Apple Health/HealthKit adapter** to the integrated pipeline. Put Oura Cloud summaries, CPAP/imported records, Oura BLE foundation, and demo fixtures in visibly separate lanes with no arrow into the active pipeline. If optional Oura IBI support is shown, label it “foundation / separately configured; not wired by `KitPipelineService`.” Update the SVG description to match.

**Evidence:**
- `AnxietyWatch/Services/KitPipelineService.swift:35-69`
- `AnxietyWatchKit/Sources/AnxietyWatchKit/BLE/SensorRouter.swift:5-18,94-137`
- `AnxietyWatchKit/Sources/AnxietyWatchKit/BLE/OuraBLEActor+SensorRouterBridge.swift:5-27`
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Oura/OuraService.swift:89-148`
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Diagnostics/DependencyContainer.swift:180-197`

### TA2 — “Adapters and sensor actors → Local GRDB storage” invents an integrated persistence write

**Artifact:** `architecture.png`  
**Severity:** Blocking

A rendered arrow labeled “persist” runs from the integrated kit container at adapter height into “Local GRDB storage.” `KitPipelineService` does not insert its routed observations into `SamplesStore`; it starts the router/coordinator, publishes monitoring snapshots, and submits complication state. GRDB schema/stores exist as package foundations, but the render turns foundation coexistence into a concrete active write path.

**Required correction:** Remove the persist arrow or relabel/recompose GRDB as “package local storage foundation” without claiming routed live observations are written by this service. Only show a concrete arrow if its actual writer and row path are named and evidenced.

**Evidence:**
- `AnxietyWatch/Services/KitPipelineService.swift:45-105`
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Storage/SamplesStore.swift`
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Diagnostics/DependencyContainer.swift:120-153`

### TA3 — Watch UI/cache portrayal collapses iPhone and watch runtime paths

**Artifact:** `architecture.png`  
**Severity:** Blocking

The render points the central iPhone integration container to a combined “iPhone + Watch UI” card and to “Complication cache — watch-facing snapshot output.” This implies one phone-side pipeline directly drives both UIs/cache. Actual behavior is phased and platform-specific:

- On iOS, `KitPipelineService` creates `ComplicationCacheWriter`, but its own comment says this is a no-op for the complication target.
- watchOS constructs a separate **HealthKit-only** `SensorRouter` and feeds `ComplicationFeedService`.
- watchOS does not start package `SyncEngine`/`WCSessionCoordinator` during the current migration.

**Required correction:** Split “iPhone monitoring UI” from “watch HealthKit router → complication feed/cache.” Add a visible phased-coexistence qualifier. Do not use a single arrow from the iPhone integration box to combined iPhone/watch presentation.

**Evidence:**
- `AnxietyWatch/Services/KitPipelineService.swift:75-104`
- `AnxietyWatch Watch App/AnxietyWatchApp.swift:99-105,169-196`
- `AnxietyWatch Watch App/ComplicationFeedService.swift:4-37`

### TA4 — WatchConnectivity → server “sync” arrow falsely suggests a single completed transport chain

**Artifact:** `architecture.png`  
**Severity:** Blocking

The right column places WatchConnectivity immediately over Server mirror and connects them with a downward arrow labeled “sync.” This reads as device transport syncing onward to the server. The implementation instead has parallel/phased paths:

- existing app `SyncService` is push-only to a personal server mirror;
- package `SyncCoordinator`/REST is a separate HLC delta foundation;
- package `SyncEngine` is P2P over `WCSession`;
- watchOS explicitly does not start package P2P transport and uses legacy `WatchConnectivityManager` while migration is incomplete;
- watch package server endpoint is no-op.

**Required correction:** Remove the WatchConnectivity→server arrow. Show peer transport and server sync as separate branches. Label the mirror “existing app push sync,” package delta sync “foundation,” and watch package transport “watch-side migration incomplete” if depicted.

**Evidence:**
- `AnxietyWatch/Services/SyncService.swift:7-10`
- `AnxietyWatch/App/AnxietyWatchApp.swift:250-303`
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Transport/SyncEngine.swift:3-15`
- `AnxietyWatch Watch App/AnxietyWatchApp.swift:99-105,145-176,284-299`
- `AnxietyWatch Watch App/WatchConnectivityManager.swift`

### TA5 — “quality → severity → fusion → tier state” is not the package pipeline shown

**Artifact:** `architecture.png`  
**Severity:** Blocking

The central CNS card claims an ordered quality/severity/fusion pipeline. The package path shown in this diagram is `PipelineStep.step` → `CNSFusionEngine.fuse` → `PipelineStep.applyFusion` / tier machine. It does not contain named quality-gate and severity-scorer stages. This wording appears to conflate a different/newer app CNS architecture with the PR’s package pipeline.

**Required correction:** Use implementation-neutral, evidenced text such as “event step → fusion → tier state,” or name the actual package types. Do not import `CNSQualityGate`/`CNSSeverityScorer` concepts into this PR/package visual.

**Evidence:**
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Pipeline/CNSMonitoringCoordinator.swift:95-118`
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Pipeline/PipelineStep.swift`
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Pipeline/CNSFusionEngine.swift`
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Pipeline/CNSAlertTierMachine.swift`

### TA6 — Provenance still claims unsupported universal labeling

**Artifact:** `provenance.png`  
**Severity:** Blocking

The central panel visibly says, “Every metric keeps a visible source or demo label.” Evidence supports source-aware labels on selected Oura and demo surfaces, not a universal invariant for every app metric. This was preimplementation finding T4 and remains unresolved.

**Required correction:** Replace with “These Oura/demo surfaces show a visible source or mode label” or similarly bounded wording. The title/subtitle must also avoid implying universal per-value provenance if only surface-level labels exist.

**Evidence:**
- `AnxietyWatch/Views/OuraDataDashboardView.swift:45-54,163-172`
- `AnxietyWatch/Views/OuraIntegratedViews.swift:81-103,133-149`
- `AnxietyWatch/Views/CNSMonitoringDemoView.swift:4-5,64-74,119-125`

### TA7 — “HealthKit import / bridge” still implies Oura→HealthKit transfer not implemented by this PR

**Artifact:** `provenance.png`  
**Severity:** Blocking

The Apple Health card says “HealthKit import / bridge.” In the Oura implementation, `OuraHealthKitAdapter` requests read access to sleep analysis and oxygen saturation with an empty share set. It does not write Oura Cloud data into HealthKit. The rendered phrase, placed beside Oura Cloud and a “Cloud summary” legend, invites exactly that false interpretation.

**Required correction:** Use “HealthKit read/import source” or “Apple Health read permissions: sleep + oxygen.” Do not use “bridge” unless the visual explicitly says the user-facing control only enables read permissions and no Oura Cloud values are written to HealthKit.

**Evidence:**
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Oura/OuraHealthKitAdapter.swift:5-32`
- `AnxietyWatch/Views/OuraSettingsView.swift:124-131,248-254`

### TA8 — Provenance arrow crosses into the isolation box

**Artifact:** `provenance.png`  
**Severity:** Blocking

A solid right-pointing arrow runs from “Source-aware presentation” across the vertical isolation boundary into the simulated-device box. Regardless of intent, arrow grammar means data/control flow and contradicts “demos stop at the boundary.” The simulated services are isolated adapters, not an output of source-aware production presentation.

**Required correction:** Remove that arrow. If the boundary relationship needs emphasis, use a barred/non-flow symbol and explicit “separate mode,” not the diagram’s solid-flow arrow style.

**Evidence:**
- `AnxietyWatch/App/AnxietyWatchApp.swift:167-184,319-330`
- `AnxietyWatch/Utilities/FullAppDemoDeviceSession.swift:40-72`
- `AnxietyWatchTests/FullAppDemoDeviceSessionTests.swift:58-83`

## Required qualifier improvements

### TA9 — Oura BLE limitation is incomplete

**Artifacts:** `architecture.png`, `provenance.png`  
**Severity:** Major

The renders show “feature-gated,” “key required,” and “hardware-dependent,” and the provenance footer mentions protocol/decryption validation. They still omit that the shared key is **16 bytes**, do not mention key validation explicitly, and architecture visually groups Oura BLE with active inputs. `connect()` contains placeholder protocol-flow comments rather than a completed physical implementation.

**Required correction:** Use: “Feature-gated foundation; 16-byte shared key required; physical Ring 5 protocol/decryption/key validation not completed.” Keep it outside the active runtime arrows.

**Evidence:**
- `AnxietyWatchKit/Sources/AnxietyWatchKit/BLE/OuraBLEActor.swift:13-24,162-223`
- `AnxietyWatchKit/Sources/AnxietyWatchKit/BLE/OuraBLEKeyStore.swift`
- PR #16 body, “Safety and provenance” / “Follow-up work”

### TA10 — CNS demo label should explicitly distinguish demo vocabulary from package tiers

**Artifact:** `provenance.png`  
**Severity:** Major

The render correctly says “DEMO UI PROGRESSION — NOT A CLINICAL ALARM” and includes the real exclusions. However, “CNS tier demonstration” still places `Clear → Watch → Confirm → Klaxon` under a generic tier label. The package production enum is `normal/advisory/warning/critical`.

**Required correction:** Rename to “Isolated scripted CNS demo labels” and, if space allows, add “not production `AlertTier` names.” Do not connect this box to the production pipeline.

**Evidence:**
- `AnxietyWatch/Views/CNSMonitoringDemoView.swift:4-31,205-218`
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Pipeline/PipelineState.swift:41-47`

## Per-artifact assessment

### `architecture.png`: **FAIL / ITERATE**

Positive: source names are visibly separate; demo fixtures are visibly bounded; Oura BLE hardware dependence and server-mirror language appear; storage/UI/cache cards are visually distinguishable.

Blocking: TA1–TA5 and TA9. The actual arrow layout is more misleading than the prose because it creates integrations that do not exist and hides the live inputs that do.

### `provenance.png`: **FAIL / ITERATE**

Positive: Oura Cloud, Apple Health, Polar, EMAY, CPAP, Oura BLE, and simulated sources have separate visible labels. The simulated-device exclusions are accurate: no production BLE, no production `SensorSession`, no HealthKit write, no persistence of demo readings as real. The CNS exclusions are accurate: no production monitoring, no real notification/alert, no diagnosis. Six-hour deterministic hardware-free simulation is supported.

Blocking: TA6–TA8; required qualifiers TA9–TA10. The full-app demo wording is appropriately scoped to “Simulated device session,” so it does not incorrectly deny that `DemoSeeder` writes deterministic fixture rows.

**Evidence for accurate exclusions:**
- `AnxietyWatch/Utilities/FullAppDemoDeviceSession.swift:19-72`
- `AnxietyWatchTests/FullAppDemoDeviceSessionTests.swift:10-83`
- `AnxietyWatch/Services/PolarHRMService.swift:114-177,191-285,579`
- `AnxietyWatch/Services/EMAYRealtimeService.swift:358-370,472-514,539-564`
- `AnxietyWatch/Views/CNSMonitoringDemoView.swift:4-5,64,119-125,205-218`

### `ui-montage.png`: **TECHNICALLY PASS WITH CONDITIONS**

The rendered montage clearly labels every panel “SIMULATOR” and the footer states that values are deterministic/fictional and that the comprehensive walkthrough remains incomplete. It does not claim hardware validation. The selected crops show Dashboard, Oura data, Trends, Journal, Medications, and Settings/source controls; these are representative surfaces present in PR scope. No person name, account, token, device UUID, address, or other PII was found in the rendered crops or selected source screenshots. Medication names/doses are generic deterministic fixture content, not identifiers.

Conditions for final approval:

1. Keep “Cloud summary surface” under Oura, because the cropped Oura screenshot itself does not retain the `Oura Cloud`/`Demo Data` provenance header.
2. Keep the global “SIMULATOR” badges and fictional/deterministic footer legible in the published raster.
3. Do not use the Settings crop to claim that CNS klaxon/haptic delivery shipped in PR #16. The screenshot’s own small copy says loud alerting is later-phase work; at reduced size that caveat is not readily inspectable.
4. Do not call the montage a complete walkthrough.

**Evidence:**
- `AnxietyWatch/Views/OuraDataDashboardView.swift`
- `AnxietyWatch/Views/OuraIntegratedViews.swift`
- `AnxietyWatch/Views/Dashboard/DashboardView.swift`
- `AnxietyWatch/Views/Trends/TrendsView.swift`
- `AnxietyWatch/Views/Journal/JournalListView.swift`
- `AnxietyWatch/Views/Medications/MedicationsHubView.swift`
- `AnxietyWatch/Views/Settings/SettingsView.swift`
- `AnxietyWatch/Utilities/DemoSeeder.swift`
- PR #16 body, “Follow-up work”

## Iteration 2 pass criteria

Iteration 2 can receive technical **APPROVE** only if the actual rerendered PNGs:

- visibly connect only integrated live sources to `KitPipelineService`’s active router path;
- separate Oura Cloud summaries, CPAP/import paths, optional Oura BLE/IBI foundations, and demos from that runtime path;
- remove the unsupported adapter→GRDB write arrow;
- split iPhone and watch/cache runtime behavior;
- separate WatchConnectivity peer transport from server sync and disclose watch-side phased migration;
- use actual package CNS stages rather than quality/severity shorthand;
- narrow “every metric” and HealthKit “bridge” claims;
- remove the arrow crossing the demo isolation boundary;
- fully qualify Oura BLE’s 16-byte key and unvalidated physical Ring 5 protocol/decryption/key behavior;
- preserve all accurate demo exclusions and montage scope labels.

**Overall approval status: ITERATE.**
