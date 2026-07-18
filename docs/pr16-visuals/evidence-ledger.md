# PR #16 visual evidence ledger

This ledger constrains implementation claims. It is not a substitute for the later rendered-artifact review.

| Visual claim / label | Evidence | What it permits | Guardrail |
|---|---|---|---|
| iOS app owns the integrated launch graph and creates `KitPipelineService` | `AnxietyWatch/App/AnxietyWatchApp.swift` (`@StateObject`, bootstrap/start lifecycle) | Show iPhone app → kit/pipeline relationship. | Do not imply all legacy services were removed; source says phased coexistence. |
| BLE actors and HealthKit adapter feed `SensorRouter`; pipeline produces monitoring state and complication output | `AnxietyWatch/Services/KitPipelineService.swift` (`start()`) | Show Polar, EMAY, HealthKit → router → coordinator/view model/cache. | Keep source lanes distinct; HealthKit is not Oura Cloud. |
| Shared package contains BLE, Oura, pipeline, storage, sync, transport, view models | `AnxietyWatchKit/INTEGRATION.md`; `AnxietyWatchKit/Sources/AnxietyWatchKit/` | Show package as a shared foundation used by iOS/watch targets. | Do not claim every feature is hardware-validated. |
| GRDB/storage and HLC/sync/transport foundations exist | `AnxietyWatchKit/INTEGRATION.md`; `AnxietyWatchKit/Sources/AnxietyWatchKit/Storage/`, `Sync/`, `Transport/` | Show local storage and sync/transport layers. | Diagram is conceptual; do not invent exact server protocol arrows beyond implementation evidence. |
| Server is a mirror and sync is push-oriented | `AnxietyWatch/Services/SyncService.swift` doc comment and sync implementation | Show app → server mirror as sync path. | Do not suggest server replaces HealthKit or is source of truth. |
| Oura dashboard labels Cloud and simulator/demo provenance | `AnxietyWatch/Views/OuraDataDashboardView.swift` (`provenanceHeader`) | Show Oura Cloud and Demo Data as distinct labels. | Do not present demo as live Ring data. |
| Oura BLE is separate from daily Cloud summaries; signal/key support exists | `AnxietyWatch/Views/OuraDataDashboardView.swift` (`liveSection`); `AnxietyWatchKit/Sources/AnxietyWatchKit/BLE/OuraBLEActor.swift`; `OuraBLEKeyStore.swift` | Show separate Oura Cloud and feature-gated BLE lanes. | Ring 5 decryption/protocol and key validation remain hardware-dependent; provisioning is required. |
| Oura values are wellness summaries, not medical assessments | `OuraDataDashboardView.swift` score/cardiovascular cautions | Include caution label. | Never use diagnostic language. |
| Simulated Polar/EMAY session is deterministic and isolated | `AnxietyWatch/Utilities/FullAppDemoDeviceSession.swift` | Show “Polar H10 (Simulated)” and “EMAY Oximeter (Simulated)” in demo lane; six-hour logical clock is supported. | Do not call it a real recording or hardware validation. |
| Full-app demo mode avoids production BLE pipeline | `AnxietyWatch/App/AnxietyWatchApp.swift` launch task; `FullAppDemoDeviceSession.swift` | Show demo boundary excludes production BLE startup. | Keep “demo” visibly separate from production path. |
| CNS demo does not arm real monitoring, post notifications, or persist health events | `AnxietyWatch/Views/CNSMonitoringDemoView.swift` file header and footer/copy | Show isolated CNS demo and explicit exclusions. | Do not call it a delivered production alert feature or medical diagnosis. |
| Deterministic fictional fixtures exist | `AnxietyWatch/Utilities/DemoSeeder.swift` comments and seeded values | Label montage/demo values fictional and deterministic. | Avoid real names, identifiers, addresses, tokens, and personal data. |
| Representative dark-mode surfaces exist | Locally verified screenshot set under `~/anxietywatch-screenshots-verified/` (source material only) | Use Dashboard, Oura, Trends, Journal, Settings as montage categories after asset review. | Do not publish these local files or claim they are durable GitHub assets; do not expose unreviewed screenshots. |
| Full walkthrough remains follow-up | PR #16 body “Follow-up work” | Put “representative surfaces; comprehensive coordinator remains follow-up” in montage caption. | Never imply complete route coverage. |

## Evidence not used

- `PROJECT_FUTURE_PLAN.md` was explicitly not read and is not evidence.
- Planning docs (`FULL_APP_DEMO_PLAN.md`, `FULL_APP_DEMO_SPEC.md`) are not treated as proof of implementation.
- Local recordings are not treated as publication-ready or as proof of hardware validation.
