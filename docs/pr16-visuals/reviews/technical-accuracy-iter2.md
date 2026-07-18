# Rendered technical accuracy review — iteration 2

**Role:** Independent Technical Accuracy Critic  
**Verdict:** **ITERATE**

Iteration 2 corrects most of the false integrations from iteration 1, but it does not meet the iteration-2 technical pass criteria. The architecture still describes the package-backed live path with the wrong CNS sequence and still conflates the iPhone pipeline’s cache output with the separate watch runtime. Both architecture and provenance retain an incomplete Oura BLE limitation. Do not publish these renders yet.

## Artifacts inspected

Canonical rendered PNGs:

- `docs/pr16-visuals/rendered/architecture.png` — 1600×980 — SHA-256 `66af0bf813e76b361904eb88af962af23cdd6a56c901ca7a16cdfabe861d0552`
- `docs/pr16-visuals/rendered/provenance.png` — 1600×960 — SHA-256 `a62fe02bb71092f135399eb4deb0af088d8e7aa4528eae47c757cb798b6b6804`
- `docs/pr16-visuals/rendered/ui-montage.png` — 1470×1570 — SHA-256 `dd0ce9c643b903697f7649a37d715a7903604399266300ab8594f06a3e947c66`

Scaled output inspected:

- `docs/pr16-visuals/reviews/renders-iter2/320/*.png`
- `docs/pr16-visuals/reviews/renders-iter2/768/*.png`
- `docs/pr16-visuals/reviews/renders-iter2/1024/*.png`
- `docs/pr16-visuals/reviews/renders-iter2/1280/*.png`

The raster output was checked at intrinsic size and by OCR at every supplied width. Generator output was then compared with implementation evidence; source review was not treated as a substitute for rendered review.

## Findings

### TA2-1 — [BLOCKING] The rendered CNS sequence belongs to a different app pipeline, not the live package path drawn here

**Artifact:** `architecture.png`

The active lane visibly says:

> `CNS processing`  
> `quality → severity → fusion`  
> `→ monitoring state`

There is now an app-level `Services/CNSRisk` pipeline whose sequence genuinely is quality gate → severity scorer → fusion → tier machine. However, that is not the path connected to `SensorRouter` and `KitPipelineService` in this diagram. The rendered lane shows the package `SensorRouter`, package monitoring view model, and package complication output. That package coordinator performs:

1. sample translation to `SensorEvent`;
2. `PipelineStep.step`;
3. `CNSFusionEngine.fuse`;
4. `PipelineStep.applyFusion`, including tier-machine state;
5. publication through router snapshots/view models.

`KitPipelineService` constructs `PipelineCoordinator` from the package router; it does not call the app-level `CNSDetectionPipeline`. Thus the words are individually real but attached to the wrong architecture path.

**Required correction:** For this rendered package path, use an evidenced phrase such as **“event step → fusion → tier state”**, or explicitly name `PipelineStep`, package `CNSFusionEngine`, and the package tier state. If the newer app `CNSDetectionPipeline` is shown instead, it must be a separate lane with its actual entry point and sequence **quality gate → severity scorer → fusion → tier machine**; do not splice its stages into the package `SensorRouter` graph.

**Evidence:**

- `AnxietyWatch/Services/KitPipelineService.swift`
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Pipeline/CNSMonitoringCoordinator.swift` (`process`)
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Pipeline/PipelineStep.swift`
- `AnxietyWatch/Services/CNSRisk/CNSDetectionPipeline.swift`
- `AnxietyWatch/Services/CNSRisk/CNSQualityGate.swift`
- `AnxietyWatch/Services/CNSRisk/CNSSeverityScorer.swift`
- `AnxietyWatch/Services/CNSRisk/CNSFusionEngine.swift`
- `AnxietyWatch/Services/CNSRisk/CNSAlertTierMachine.swift`

### TA2-2 — [BLOCKING] Oura BLE still omits the required 16-byte key and incomplete physical-key validation qualification

**Artifacts:** `architecture.png`, `provenance.png`

The rendered labels say only:

- architecture: `feature-gated · key required · hardware-dependent`;
- provenance: `feature-gated · key required · hardware-dependent`;
- provenance footer: `Physical Oura Ring 5 BLE protocol/decryption validation remains hardware-dependent.`

This remains weaker than the implementation and the iteration-1 pass criterion. The key store accepts exactly a **16-byte shared key**, but length/hex-shape validation is not physical Ring 5 authentication validation. More importantly, `OuraBLEActor.connect()` contains comments for the scan, service discovery, nonce exchange, AES decryption, feature enablement, and notifications, then immediately transitions to `.streaming` as a testability placeholder. A stored 16-byte value therefore does not establish that the physical key is correct or that Ring 5 protocol/decryption works.

**Required correction:** Both relevant visuals should communicate the complete bounded claim, preferably verbatim:

> **Feature-gated foundation; 16-byte shared key required; physical Ring 5 protocol, decryption, and key validation not completed.**

Keep Oura BLE outside active runtime arrows.

**Evidence:**

- `AnxietyWatchKit/Sources/AnxietyWatchKit/BLE/OuraBLEProtocol.swift` (`sharedKeyLength = 16`)
- `AnxietyWatchKit/Sources/AnxietyWatchKit/BLE/OuraBLEKeyStore.swift` (`write`, `importHex`)
- `AnxietyWatchKit/Sources/AnxietyWatchKit/BLE/OuraBLEActor.swift` (`provisionKey`, `connect`; placeholder transition)

### TA2-3 — [HIGH] The complication cache remains visually attached to the iPhone presentation path and is labeled as a watch output

**Artifact:** `architecture.png`

The render places `Monitoring view model — iPhone presentation state` above `Complication cache — watch-facing snapshot output` and connects them vertically with `cache`. This still reads as the iPhone presentation path feeding the watch cache.

The implementation has two distinct runtime facts:

- iOS `KitPipelineService` consumes the router’s throttled stream in parallel with `MonitoringViewModel` and submits snapshots to `ComplicationCacheWriter`; its own comment says the iOS setup is a no-op for the complication target.
- watchOS builds a separate **HealthKit-only** `SensorRouter` and passes that router to `ComplicationFeedService`.

The cache is not written by the monitoring view model, and the shown iPhone package pipeline is not the watch’s HealthKit-only route.

**Required correction:** Draw iPhone monitoring presentation and watch HealthKit router → complication feed/cache as separate branches. At minimum, remove the view-model→cache implication and the unqualified “watch-facing” label from the iPhone lane. Preserve the watch migration qualifier described in TA2-5.

**Evidence:**

- `AnxietyWatch/Services/KitPipelineService.swift` (`MonitoringViewModel` and separate `monitoringTask`)
- `AnxietyWatch Watch App/AnxietyWatchApp.swift` (`bootstrapKit`, HealthKit-only watch router)
- `AnxietyWatch Watch App/ComplicationFeedService.swift`

### TA2-4 — [HIGH] The live-source connector still does not explicitly connect all three claimed inputs

**Artifact:** `architecture.png`

The active lane lists Polar, EMAY, and Apple Health, but the actual rendered/generator geometry contains one horizontal source arrow beginning at `(380, 300)`. That point is on the EMAY card’s upper-right boundary; there are no source arrows from the Polar or Apple Health cards. The SVG description says all three route through `SensorRouter`, which is true of `KitPipelineService`, but the visible graph does not unambiguously express it.

This is materially safer than iteration 1—Oura Cloud, CPAP, and fixtures are now in a separate lane—but it has not satisfied iteration 1’s explicit-arrow pass criterion.

**Required correction:** Give Polar, EMAY, and Apple Health/HealthKit adapter their own converging connectors, or place them in one clearly bounded “three configured adapters” group with a group-level connector that cannot be read as belonging to only EMAY.

**Evidence:**

- `docs/pr16-visuals/source/generate_assets.py` (`architecture_v2`, source-card positions and `M380 300 H464`)
- `AnxietyWatch/Services/KitPipelineService.swift` (constructs all three actors and passes them to `SensorRouter`)

### TA2-5 — [MEDIUM] Legacy/package coexistence is acknowledged, but the watch-side transport state is still underspecified

**Artifact:** `architecture.png`

The separate foundations are a substantial correction: GRDB/HLC, phone↔watch, existing app sync, and Oura BLE are no longer drawn as one completed chain. `Phased coexistence` also correctly says legacy services remain during package rollout.

However, `Phone ↔ Watch — legacy path + package transport foundation` can still be read as both paths operating end-to-end. On iOS the package `SyncEngine` starts, while watchOS explicitly does **not** start package `SyncEngine`/`WCSessionCoordinator`; the existing `WatchConnectivityManager` retains the single delegate role. The watch’s package server endpoint is also no-op. This distinction matters because the prior render falsely presented a completed watch-to-server chain.

**Required correction:** Qualify the foundation as, for example, **“existing WatchConnectivity path active; package peer transport foundation; watch migration incomplete.”** Do not add a connector to the server mirror.

**Evidence:**

- `AnxietyWatch/App/AnxietyWatchApp.swift` (`bootstrapKit`, starts package `syncEngine` on iOS)
- `AnxietyWatch Watch App/AnxietyWatchApp.swift` (package transport not started; existing manager owns delegate; no-op endpoint)
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Transport/SyncEngine.swift`

### TA2-6 — [MEDIUM] Safety-critical qualifiers do not survive the supplied 320 px raster presentation

**Artifacts:** all `reviews/renders-iter2/320/*.png`

At 320 px the architecture is 320×196 and provenance is 320×192. OCR recovers no useful text from either; only the montage title is recovered from its 320 px render. This is not a new factual falsehood in the canonical assets, but it means the distinctions that prevent false claims—Oura BLE incompleteness, demo exclusions, source boundaries, and phased coexistence—are unavailable in the supplied narrow presentation.

**Required correction:** Do not publish the desktop raster as the sole narrow-width rendering. Supply dedicated stacked/mobile assets or another presentation that keeps the technical qualifiers readable, and verify the final `<picture>`/PR rendering.

**Evidence:**

- `docs/pr16-visuals/reviews/renders-iter2/320/architecture.png`
- `docs/pr16-visuals/reviews/renders-iter2/320/provenance.png`
- `docs/pr16-visuals/reviews/renders-iter2/320/ui-montage.png`

## Corrected or acceptable claims

### [PASS] HealthKit and source distinctions

The provenance render now says `Apple Health — separate HealthKit read/import source`, eliminating the former implication that Oura Cloud values are written to HealthKit. That is consistent with `OuraHealthKitAdapter`, which requests read access for sleep and oxygen saturation and supplies no share types. Oura Cloud, Apple Health, Polar, EMAY, CPAP, and Oura BLE are visibly distinct.

**Evidence:**

- `AnxietyWatchKit/Sources/AnxietyWatchKit/Oura/OuraHealthKitAdapter.swift`
- `AnxietyWatch/Views/OuraIntegratedViews.swift`
- `AnxietyWatch/Views/OuraDataDashboardView.swift`

The architecture’s `Existing app sync — pushes to personal server mirror` is also accurate and is kept separate from HealthKit and phone/watch transport. The server is not shown as a physiological source of truth or as part of a WatchConnectivity chain. A final revision should retain that boundary and may beneficially restore the explicit sentence that HealthKit remains the physiological source of truth.

**Evidence:** `AnxietyWatch/Services/SyncService.swift` (push-only; app source of truth; server mirror).

### [PASS] Demo persistence exclusions are now properly narrow

The provenance render distinguishes two categories:

- simulated Polar/EMAY observations are hardware-free, start no production BLE/session, write no HealthKit data, and are not saved as readings;
- deterministic application fixtures may be seeded into the demo store for screenshots.

That avoids the prior risk of calling the entire demo “persistence-free.” In full-app demo mode, `DemoSeeder.seedIfNeeded` intentionally writes fixture rows, while launch skips production BLE, HealthKit setup, connectivity, sync, and notification setup. The isolated CNS demo does not start the real coordinator, BLE, notifications, or health-event persistence.

**Evidence:**

- `AnxietyWatch/Utilities/FullAppDemoDeviceSession.swift`
- `AnxietyWatch/Utilities/DemoSeeder.swift`
- `AnxietyWatch/App/AnxietyWatchApp.swift` (demo launch branches)
- `AnxietyWatch/Views/CNSMonitoringDemoView.swift`
- `AnxietyWatchTests/FullAppDemoDeviceSessionTests.swift`

### [PASS] Scripted CNS demo naming is separated from production naming

`Isolated CNS UI demonstration`, `scripted: Clear → Watch → Confirm → Klaxon`, and `separate from production tier naming` accurately bound the demo vocabulary. The no-production-monitoring, no-real-notification, and no-diagnosis statements are also supported.

### [PASS] Storage/sync foundations are no longer portrayed as an unsupported persistence chain

Iteration 2 removes the former SensorRouter→GRDB write and WatchConnectivity→server arrows. `Local GRDB + HLC` is accurately labeled as a package foundation, while existing app sync is a separate push-to-mirror item. Retain this separation.

### [PASS] Montage is technically scoped

The four rendered surfaces are clearly marked as fictional simulator material, Oura is described as an `Oura Cloud / demo surface`, and the footer explicitly says the comprehensive walkthrough is incomplete. No hardware-validation claim is made. No technical blocker was found in `ui-montage.png`.

## Per-artifact status

- `architecture.png`: **FAIL / ITERATE** — TA2-1, TA2-3, and TA2-4; retain its corrected source, demo, storage, and mirror separation.
- `provenance.png`: **FAIL / ITERATE** — TA2-2; otherwise the source distinctions and demo-persistence boundaries are technically sound.
- `ui-montage.png`: **TECHNICAL PASS** at intrinsic/normal PR widths; the supplied 320 px rendition does not preserve its qualifying text.

## Approval status

**ITERATE**

Approval requires rerendered output that:

1. uses the actual package sequence for the shown `SensorRouter` path (`event step → fusion → tier state`) or separates the newer app quality/severity pipeline into its own evidenced lane;
2. states the full Oura BLE limitation, including the **16-byte shared key** and incomplete physical Ring 5 **protocol/decryption/key validation**;
3. separates iPhone monitoring presentation from the watch HealthKit-only complication path;
4. visibly connects all three configured live sources to the router without making EMAY appear to be the sole connector;
5. makes active legacy watch transport versus incomplete package watch migration explicit; and
6. preserves these technical qualifiers in the narrow-width publication asset.
