# Rendered technical accuracy review — iteration 3

**Role:** Independent Technical Accuracy Critic  
**Verdict:** **ITERATE**

Iteration 3 closes TA2-1 through TA2-5 in both the desktop and dedicated mobile architecture/provenance assets. The implementation claims are now correctly bounded: the package pipeline sequence is accurate, the complete Oura BLE limitation is present, iPhone and watch cache runtimes are separate, all three iPhone live sources visibly feed the router, and active legacy WatchConnectivity is distinguished from incomplete package migration on watchOS.

TA2-6 is not closed at the supplied 320 px publication width. The dedicated mobile compositions are structurally correct and unclipped, but their body text is still uniformly reduced from a 720 px source. At 320 px, the safety-critical qualifiers are approximately 8–10 px high and are not reliably readable without zoom/opening the asset. The rendered assets therefore cannot yet be approved as the sole narrow presentation of those claims.

## Artifacts inspected

### Canonical desktop PNGs

- `docs/pr16-visuals/rendered/architecture.png` — 1600×1280 — SHA-256 `520891d5572048b5a3e48422eeec3269a28dad3ad904b8d797ee68ae6afce6bb`
- `docs/pr16-visuals/rendered/provenance.png` — 1600×960 — SHA-256 `5fa6e8e3b98be372c6fdd88c2017ba3fbbe27960efe81f191cff38ed5461fee7`
- `docs/pr16-visuals/rendered/ui-montage.png` — 1470×1570 — SHA-256 `dd0ce9c643b903697f7649a37d715a7903604399266300ab8594f06a3e947c66`

### Canonical dedicated mobile PNGs

- `docs/pr16-visuals/rendered/architecture-mobile.png` — 720×2338 — SHA-256 `36abf26f03014ad4cc4a153d45efb7ec1c47f24463cd5936d2e8fbba43b80db1`
- `docs/pr16-visuals/rendered/provenance-mobile.png` — 720×1815 — SHA-256 `3674072ee57052adb390b060c8b624b7d7e7177f032721ebd50fbb283c0dfcfe`
- `docs/pr16-visuals/rendered/ui-montage-mobile.png` — 720×4955 — SHA-256 `b0aeb480c3f2c3a9881f2e1f53a2725947cb1abd6ba7d00cd2345c00e09afcb6`

### Multi-width rendered evidence

All PNGs under:

- `docs/pr16-visuals/reviews/renders-iter3/320/`
- `docs/pr16-visuals/reviews/renders-iter3/768/`
- `docs/pr16-visuals/reviews/renders-iter3/1024/`
- `docs/pr16-visuals/reviews/renders-iter3/1280/`

The canonical desktop and mobile rasters were inspected at intrinsic size. Every supplied scaled raster was inspected and OCR-checked. Generator/SVG output was consulted afterward to verify connector endpoints and exact wording against implementation evidence; source alone was not treated as rendered approval.

## TA2 verification

### TA2-1 — [CLOSED] The shown package pipeline now uses the actual package sequence

Both architecture renders now label the package lane:

> `Package CNS processing`  
> `event step → fusion → tier state`

This matches the package coordinator connected to `KitPipelineService` and `SensorRouter`:

1. translate the routed sample to a package `SensorEvent`;
2. call `PipelineStep.step`;
3. call package `CNSFusionEngine.fuse`;
4. call `PipelineStep.applyFusion`, which applies fusion-driven tier state;
5. expose tier/fusion through the router snapshot and monitoring view model.

The diagram no longer imports the separate app-level `CNSQualityGate → CNSSeverityScorer → CNSFusionEngine → CNSAlertTierMachine` sequence into the package path.

**Rendered evidence:**

- `docs/pr16-visuals/rendered/architecture.png`
- `docs/pr16-visuals/rendered/architecture-mobile.png`
- `docs/pr16-visuals/reviews/renders-iter3/{768,1024,1280}/architecture-mobile.png`

**Implementation evidence:**

- `AnxietyWatch/Services/KitPipelineService.swift`
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Pipeline/CNSMonitoringCoordinator.swift` (`process`)
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Pipeline/PipelineStep.swift`
- Contrast: `AnxietyWatch/Services/CNSRisk/CNSDetectionPipeline.swift`

### TA2-2 — [CLOSED] The exact Oura BLE limitation is now present

The desktop architecture and both mobile technical diagrams state:

> `Feature-gated; 16-byte shared key required.`  
> `Physical Ring 5 protocol, decryption,`  
> `and key validation not completed.`

The desktop provenance card uses shorter wording (`16-byte shared key required` and `physical validation incomplete`), but the same rendered provenance asset’s footer explicitly states:

> `Physical Ring 5 protocol, decryption, and key validation are not completed.`

Therefore the full limitation is visibly present in each relevant canonical visual rather than existing only in metadata. Oura BLE also remains outside the active iPhone monitoring arrows.

This is accurate. `OuraBLEProtocol.sharedKeyLength` is 16, and `OuraBLEKeyStore` enforces that byte count. `OuraBLEActor.connect()` still contains placeholder comments for physical CoreBluetooth discovery, nonce authentication/decryption, feature enablement, and notification setup, followed by a testability-only transition directly to streaming. Length/hex validation does not validate that a provisioned key authenticates with a physical Ring 5.

**Rendered evidence:**

- `docs/pr16-visuals/rendered/architecture.png`
- `docs/pr16-visuals/rendered/architecture-mobile.png`
- `docs/pr16-visuals/rendered/provenance.png`
- `docs/pr16-visuals/rendered/provenance-mobile.png`

**Implementation evidence:**

- `AnxietyWatchKit/Sources/AnxietyWatchKit/BLE/OuraBLEProtocol.swift` (`sharedKeyLength = 16`)
- `AnxietyWatchKit/Sources/AnxietyWatchKit/BLE/OuraBLEKeyStore.swift` (`write`, `importHex`)
- `AnxietyWatchKit/Sources/AnxietyWatchKit/BLE/OuraBLEActor.swift` (`connect`; placeholder physical flow)

### TA2-3 — [CLOSED] iPhone and watch cache runtimes are now separate

The desktop architecture contains a standalone dashed card:

> `Separate watch runtime`  
> `Apple Health / HealthKit-only router`  
> `→ complication feed and cache`  
> `Not a direct continuation of the iPhone view model`

The mobile architecture equivalently says:

> `Watch HealthKit-only path`  
> `Apple Health → SensorRouter`  
> `→ complication feed and cache`  
> `Not an iPhone-view-model continuation`

No arrow joins the iPhone monitoring view model to the watch cache. This accurately distinguishes:

- iOS `KitPipelineService`, where `MonitoringViewModel` and the service’s separate complication-writer task independently consume router output; and
- watchOS, where a separate HealthKit-only `SensorRouter` is passed to `ComplicationFeedService`.

**Rendered evidence:**

- `docs/pr16-visuals/rendered/architecture.png`
- `docs/pr16-visuals/rendered/architecture-mobile.png`

**Implementation evidence:**

- `AnxietyWatch/Services/KitPipelineService.swift`
- `AnxietyWatch Watch App/AnxietyWatchApp.swift` (`bootstrapKit`)
- `AnxietyWatch Watch App/ComplicationFeedService.swift`

### TA2-4 — [CLOSED] All three configured iPhone live sources now connect to `SensorRouter`

The desktop architecture shows separate connector paths from:

- Polar H10;
- EMAY Oximeter; and
- Apple Health / HealthKit read adapter

into the shared `SensorRouter`. The paths have distinct origins and converge at separate points on the router, so none can be read as merely a label beside an EMAY-only connector.

The stacked mobile architecture repeats the relationship in each source card (`BLE actor → router` or `HealthKit read adapter → router`) before the shared `SensorRouter` card. This is a reasonable mobile replacement for three crossing connector lines and remains explicit in text.

The claim matches `KitPipelineService`, which constructs `PolarActor`, `EMAYActor`, and `HealthKitAdapterActor` and supplies all three to `SensorRouter`.

**Rendered evidence:**

- `docs/pr16-visuals/rendered/architecture.png`
- `docs/pr16-visuals/rendered/architecture-mobile.png`

**Implementation evidence:** `AnxietyWatch/Services/KitPipelineService.swift` (`start`).

### TA2-5 — [CLOSED] Active legacy watch transport and incomplete package watch migration are explicit

Both architecture variants now state:

> `Existing WatchConnectivity path is active;`  
> `package peer transport is a foundation ...`  
> `watch migration is incomplete.`

This removes the prior implication that legacy and package phone/watch transport are both complete end-to-end paths. The diagram also keeps `Existing app sync — pushes to personal server mirror` separate, with no WatchConnectivity-to-server connector.

This matches implementation state:

- iOS starts the package `SyncEngine`;
- watchOS does not start package `SyncEngine`/`WCSessionCoordinator` because the existing `WatchConnectivityManager` owns the delegate;
- watch sensor data continues through that existing manager;
- the watch package endpoint remains `NoOpSyncEndpoint`.

**Rendered evidence:**

- `docs/pr16-visuals/rendered/architecture.png`
- `docs/pr16-visuals/rendered/architecture-mobile.png`

**Implementation evidence:**

- `AnxietyWatch/App/AnxietyWatchApp.swift` (`bootstrapKit`)
- `AnxietyWatch Watch App/AnxietyWatchApp.swift` (package transport not started, active existing manager, `NoOpSyncEndpoint`)
- `AnxietyWatchKit/Sources/AnxietyWatchKit/Transport/SyncEngine.swift`

### TA2-6 — [OPEN / BLOCKING] Dedicated mobile layouts exist, but critical qualifiers are still too small at 320 px

Iteration 3 correctly replaces the uniformly downscaled desktop landscapes with dedicated one-column mobile assets. There is no clipping, and at intrinsic 720 px plus the supplied 768, 1024, and 1280 px renders, the following are clearly recoverable:

- `event step → fusion → tier state`;
- the separate watch HealthKit-only cache runtime;
- active existing WatchConnectivity versus incomplete package watch migration;
- the full 16-byte-key / physical protocol-decryption-key-validation limitation;
- HealthKit source-of-truth and server-mirror wording;
- simulated-session exclusions and the separate seeded-fixture persistence statement;
- fictional data and incomplete-walkthrough qualifications.

At the actual supplied 320 px width, however:

- `architecture-mobile.png` is 320×1039, reducing 18–23 px source body type to roughly 8–10 px;
- `provenance-mobile.png` is 320×807 with the same reduction;
- `ui-montage-mobile.png` is 320×2202, making screenshot details and its scope footer thumbnail-sized.

OCR illustrates the reliability problem rather than defining it. At 320 px it fragments or corrupts key phrases, including portions of:

- `Existing WatchConnectivity path is active; package peer transport is a foundation; watch migration is incomplete`;
- `Feature-gated; 16-byte shared key required; physical Ring 5 protocol, decryption, and key validation not completed`;
- the simulated-device no-production-session/no-HealthKit/no-save exclusions; and
- the montage’s incomplete-walkthrough footer.

Some keywords can still be inferred, but the complete bounded claims are not comfortably or dependably readable without zoom. Since those qualifiers prevent readers from mistaking foundations/demos for production behavior, their mere presence in tiny raster text does not close TA2-6.

**Required correction:** Either:

1. provide a 320-oriented narrow asset with materially larger body type and shorter high-priority wording; or
2. ensure the final narrow PR presentation places equivalent readable HTML/Markdown text immediately adjacent to the openable image, so the 320 raster is explicitly an overview and not the sole carrier of these technical boundaries.

A final `<picture>`/PR render must be checked at 320 CSS px. SVG `<desc>`, alt text hidden by a successfully loaded image, or the ability to zoom cannot by itself satisfy visible narrow qualifier preservation.

**Rendered evidence:**

- `docs/pr16-visuals/reviews/renders-iter3/320/architecture-mobile.png`
- `docs/pr16-visuals/reviews/renders-iter3/320/provenance-mobile.png`
- `docs/pr16-visuals/reviews/renders-iter3/320/ui-montage-mobile.png`
- Comparison: corresponding renders under `renders-iter3/{768,1024,1280}/`

## Retained technical boundaries

The iteration-2 passes remain intact:

- Apple Health is a separate HealthKit read/import source; Oura Cloud is not depicted as writing to HealthKit. `OuraHealthKitAdapter` requests read permissions and supplies no share set.
- HealthKit remains the physiological source of truth, while existing app sync is push-oriented to a personal server mirror.
- Oura Cloud, Oura BLE, Apple Health, CPAP, Polar, EMAY, and deterministic fixtures remain distinct.
- Simulated Polar/EMAY observations do not enter the production router, HealthKit, or production sensor sessions and are not saved as readings.
- Seeded deterministic application fixtures are separately acknowledged as demo-store writes.
- The scripted CNS UI demonstration is separate from production tier naming and claims no production monitoring, real notification, diagnosis, or clinical certainty.
- GRDB/HLC, existing server sync, watch transport, and Oura BLE remain separate foundations rather than a fabricated completed chain.
- The montage remains fictional, representative, and explicitly does not claim a completed comprehensive walkthrough or hardware validation.

**Supporting evidence:**

- `AnxietyWatchKit/Sources/AnxietyWatchKit/Oura/OuraHealthKitAdapter.swift`
- `AnxietyWatch/Services/SyncService.swift`
- `AnxietyWatch/Utilities/FullAppDemoDeviceSession.swift`
- `AnxietyWatch/Utilities/DemoSeeder.swift`
- `AnxietyWatch/App/AnxietyWatchApp.swift`
- `AnxietyWatch/Views/CNSMonitoringDemoView.swift`

## Per-artifact status

- Desktop `architecture.png`: **TECHNICAL PASS**
- Desktop `provenance.png`: **TECHNICAL PASS**
- Desktop `ui-montage.png`: **TECHNICAL PASS**
- Intrinsic mobile PNGs and 768/1024/1280 review renders: **TECHNICAL PASS**
- 320 px mobile review renders: **FAIL — TA2-6 remains open**

## Approval status

# **ITERATE**

All substantive architecture and implementation-accuracy findings from TA2-1 through TA2-5 are closed. Approval is withheld solely because the supplied 320 px presentation does not yet preserve the safety-critical technical qualifiers at a reliably readable visible size, and no final adjacent narrow-width prose fallback has yet been demonstrated.
