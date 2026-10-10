# CNS Klaxon Phase 2 — Monitoring Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the monitoring layer that feeds the Phase 1 detection engine: CNS-depressant dose classification, pharmacokinetic dose-window activation gating (spec §14.1), a monitoring-session data model, real sensor adapters (EMAY + Polar), the device-state matrix with per-device fallback config (§7), and the coordinator that drives `CNSDetectionPipeline` once per second — plus a minimal functional arm/disarm surface. Phase 3 (klaxon audio/haptics, real settings UI, dashboard indicator, 1-hour view) consumes what this phase produces.

**Architecture:** Everything engine-adjacent stays pure and clock-explicit like Phase 1 (`Date` passed in, no singletons in logic). New pure units: `CNSDepressantClassifier` (name/category → drug class), `DoseWindowGate` (doses → active window + expiry with §14.1 stacking), `CNSDeviceStateMatrix` (per-source presence classification), static sample adapters (EMAYReading/Polar readings → `[CNSSignalSample]`). Stateful glue: two local-only SwiftData models (`MonitoringSession`, `CNSRiskSampleRecord`, following the `HealthSample` local-only precedent) and one app-scoped `@MainActor @Observable CNSMonitoringCoordinator` that owns the 1 Hz tick, the rolling sample buffer, baseline population, tier-edge detection, and session records — mirroring how `CNSDetectionPipelineTests.replay` already drives the engine.

**Tech Stack:** Swift 5.9+/SwiftUI/SwiftData, Swift Testing, Observation framework; no new dependencies.

## Scope Decisions (made autonomously 2026-07-12 while the project maintainer was unavailable — REVIEW THESE FIRST)

1. **Adapters thread `perfusionIndex`/`isArtifact`, not confidence** — the Phase 1 `CNSSignalSample` type governs; spec §10's "confidence" is derived downstream by `CNSSeverityScorer` (spec-vs-type mismatch resolved in favor of shipped code).
2. **Auto-sleep detection is OUT of Phase 2** — §14.3 forbids it as a gating condition (may only add coverage); the "arm the monitor?" nudge is deferred to Phase 3 with the rest of the notification/UI surface. Default triggers shipped here: manual toggle + post-dose windows (§14.3's stated default).
3. **Live sources are EMAY and Polar only.** The quality gate's coverage math assumes ~1 Hz (`CNSQualityGate` counts samples as seconds; `gateMaxContiguousGapSeconds = 3`); Apple Watch SpO₂ spot-checks/sparse HRV **must not** be fed through it unchanged (engine doc's own warning). The HealthKit path in Phase 2 populates `CNSBaselines` only (spo2Nadir, restingHeartRate, hrvMean, respiratoryRateMean from `HealthSnapshot`). A cadence-aware sparse-source gate is flagged for Phase 3/2b.
4. **Drug classification is a stored model field with conservative defaults.** New `cnsDepressantClass: String?` on `MedicationDefinition` (raw enum), default derived once by `CNSDepressantClassifier` from category + name matching (e.g. "Benzodiazepine" category → benzodiazepine; name containing hydrocodone/oxycodone/… → opioidIR unless ER markers; methadone → methadoneOrUnknownLongActing; Z-Drug → benzodiazepine-class window, fail-safe per §14.1's "treat unknown as long-acting" spirit). User-visible picker added to `AddMedicationView` (existing medication-management surface, not Phase 3 settings UI). Classifier never DOWN-classifies an existing explicit value.
5. **Minimum-bar guardrail (spec left TBD):** monitoring can ARM with any source, but reports `.insufficientData`-driven "can't assess" status unless at least one **primary-capable continuous** source is present-and-reporting — in practice EMAY streaming (the only continuous SpO₂; Polar has no primary kind; fidelity table). The status surfaces on the coordinator + session record; Phase 3 renders it.
6. **Per-device fallback: detection + config here, loud alerting in Phase 3.** Phase 2 detects died-mid-session/present-but-idle transitions, persists the per-device choice (klaxon / gentle alarm / notify-only) in `UserDefaults` via a typed config, and — as an interim "never a silent stop" measure — posts a standard local notification (same `UNUserNotificationCenter` plumbing as dose follow-ups). `KlaxonAlarmService` replaces the interim path in Phase 3.
7. **Companion re-marking must not reset escalation state.** `CNSDetectionPipeline` bakes `companionPresent` in at init; rebuilding mid-session would reset the tier machine's sustain windows (delaying escalation — wrong direction for safety). Phase 2 adds a minimal Phase 1 amendment: `mutating func setCompanionPresent(_:)` on the pipeline (threads to the tier machine's threshold context) preserving all sustain state, with tests proving tier state survives the flip.
8. **Session/sample persistence:** `MonitoringSession` (one row per arm→disarm) + `CNSRiskSampleRecord` (one row per 10 s while assessing; pruned beyond 24 h) — local-only (HealthSample precedent: registered in both Schema lists, absent from the sync trio). The ~1-hour view (Phase 3) reads the records. Cadence/retention constants live in `CNSMonitoringConstants`, not magic numbers.
9. **"EMAY service promotion" is already done** on main (app-scoped `@State` + `.environment` injection since the EMAY continuous-mode work) — verified; no task needed.
10. **Minimal arm/disarm surface ships now** (Settings → "CNS Monitoring"): arm/disarm toggle, "monitor me now", companion toggle with the §6 re-mark warning, live status line (armed reason, sources reporting, can-assess, current tier as text). This is the functional surface Phase 2 needs to be drivable end-to-end; Phase 3 redesigns it. No klaxon, no haptics, no dashboard changes.
11. **Alone-mode fast escalation** (shorter sustains when alone) stays deferred to Phase 3 with the confirmation tier, per the Phase 1 note; Phase 2 wires `companionPresent` → existing `aloneModeThresholdDelta` only.
12. **Synergy detection rule (amended during execution, 2026-07-12):** the plan's original "monitoring-window overlap" rule under-detected the spec's "benzo + opioid ONBOARD together" case (a benzo 23h50m before an opioid has no window overlap but is pharmacologically onboard — clonazepam t½ 30-40h). Final rule: synergy = UNION of (a) dose timestamps within a 24h pairing horizon, OR (b) §14.1 monitoring windows overlapping. The union is strictly more protective (the horizon-only variant forgoes 62h of monitoring in the methadone@t0 + benzo@t0+50h case: t0+134h vs t0+72h). Constants and rationale in `CNSMonitoringConstants.synergyPairingHorizon`. **Pending clinical review** — as is the buprenorphine→24h window assignment from Task 1.

## Global Constraints

- **Swift Testing only** (`import Testing`, `@Test`, `#expect`) — never XCTest.
- **Float comparisons:** never `#expect(x == y)` on `Double` — use `abs(actual - expected) < 0.001`.
- **Fixed reference dates** in all tests — never `Date.now`/`Date()` in assertions. Use `Date(timeIntervalSince1970: 1_750_000_000)` as `t0` (Phase 1 convention).
- **Never coerce invalid/missing sensor data to a value** (spec §5.1, §11): adapters emit nothing for invalid readings (`hasSpO2 == false` → no spo2 sample; nil pulse → no heartRate sample).
- **Asymmetry rule (spec §14.2):** low quality surfaces as "can't assess," never "OK". Fallback/degradation is disclosed, never silent.
- **SwiftLint:** 150-char warn / 200 error; zero warnings (CI: SWIFT_TREAT_WARNINGS_AS_ERRORS=YES).
- **Magic numbers:** every new constant lives in `CNSMonitoringConstants` (Task 2) or existing `CNSThresholds`; tests reference the constants.
- **Public repo:** no personal medical assertions, no PII. Fixture med names are generic ("Test Benzo 1mg"); real drug names appear only in the classifier's clinical word lists (that's reference data, not personal info).
- **New Swift files auto-register** (synchronized pbxproj) — do NOT edit project.pbxproj. New `@Model` types MUST be added to BOTH Schema lists: `AnxietyWatchApp.swift:16-40` and `AnxietyWatchTests/Helpers/TestHelpers.swift:42-67`.
- **Branch:** all work on `feat/klaxon-phase2-monitoring` off `main`. Never commit to main.
- **Test command (per-suite):** `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/<SuiteName>`; full suite = same without `-only-testing`.
- **Dose windows are safety-critical logic:** §14.1 constants verbatim — benzo 12 h; IR opioid 8 h; ER opioid 24 h; methadone/unknown-long-acting 72 h; benzo+opioid `max(class windows) + 12 h` from the later dose with 24 h floor; stacking always takes the LATER expiry (re-arm/extend, never shorten).

---

## File Structure

| File | Responsibility |
|---|---|
| `AnxietyWatch/Services/CNSRisk/CNSDepressantClass.swift` (create) | `CNSDepressantClass` enum (raw String) + per-class window durations |
| `AnxietyWatch/Services/CNSRisk/CNSDepressantClassifier.swift` (create) | Pure category/name → class default classification |
| `AnxietyWatch/Services/CNSRisk/CNSMonitoringConstants.swift` (create) | Sample-persist cadence, retention, tick interval, notification identifiers |
| `AnxietyWatch/Services/CNSRisk/DoseWindowGate.swift` (create) | Pure §14.1 window computation over `[LoggedDose]` value inputs |
| `AnxietyWatch/Services/CNSRisk/CNSDeviceStateMatrix.swift` (create) | Device presence states, ignorable/degrade/end classification, fallback config |
| `AnxietyWatch/Services/CNSRisk/CNSSensorAdapters.swift` (create) | Pure static EMAY/Polar → `[CNSSignalSample]` mapping |
| `AnxietyWatch/Services/CNSRisk/CNSDetectionPipeline.swift` (modify) | Add state-preserving `setCompanionPresent(_:)` |
| `AnxietyWatch/Services/CNSRisk/CNSAlertTierMachine.swift` (modify) | Thread mutable companion flag to threshold context (state-preserving) |
| `AnxietyWatch/Models/MonitoringSession.swift` (create) | `@Model` session record (local-only) |
| `AnxietyWatch/Models/CNSRiskSampleRecord.swift` (create) | `@Model` rolling risk sample (local-only) |
| `AnxietyWatch/Models/MedicationDefinition.swift` (modify) | Add `cnsDepressantClass: String?` |
| `AnxietyWatch/Services/CNSMonitoringCoordinator.swift` (create) | App-scoped tick loop; buffer; baselines; tier edges; sessions; device states; arming |
| `AnxietyWatch/Views/Settings/CNSMonitoringView.swift` (create) | Minimal arm/companion/status surface |
| `AnxietyWatch/Views/Settings/SettingsView.swift` (modify) | Nav link |
| `AnxietyWatch/Views/Medications/AddMedicationView.swift` (modify) | Class picker + classifier default |
| `AnxietyWatch/Views/Medications/MedicationsHubView.swift` + `DoseAnxietyPromptView.swift` (modify) | Post-dose arming hook at both log sites |
| `AnxietyWatch/App/AnxietyWatchApp.swift` (modify) | Coordinator construction/injection/launch hook; Schema additions |
| Tests: one suite per pure unit + coordinator suite + adapter suite (create) | See tasks |

---

### Task 1: Drug classes and the classifier

**Files:**
- Create: `AnxietyWatch/Services/CNSRisk/CNSDepressantClass.swift`
- Create: `AnxietyWatch/Services/CNSRisk/CNSDepressantClassifier.swift`
- Modify: `AnxietyWatch/Models/MedicationDefinition.swift` (add field)
- Modify: `AnxietyWatch/Views/Medications/AddMedicationView.swift` (picker + default)
- Test: `AnxietyWatchTests/CNSDepressantClassifierTests.swift` (create)

**Interfaces:**
- Consumes: `MedicationDefinition.category: String` (free-form; existing picker values incl. "Benzodiazepine", "Z-Drug", "Other"), `MedicationDefinition.name`.
- Produces: `enum CNSDepressantClass: String, CaseIterable, Sendable { case benzodiazepine, opioidIR, opioidER, methadoneOrUnknownLongActing }` with `var doseWindow: TimeInterval` (12 h / 8 h / 24 h / 72 h in seconds); `CNSDepressantClassifier.classify(name: String, category: String) -> CNSDepressantClass?` (nil = not a CNS depressant); `MedicationDefinition.cnsDepressantClass: String?` storing the raw value (nil = unclassified/not applicable). Later tasks call `CNSDepressantClass(rawValue:)` on it.

- [ ] **Step 1: Write failing classifier tests**

```swift
import Testing
@testable import AnxietyWatch

struct CNSDepressantClassifierTests {
    @Test("Benzodiazepine category classifies regardless of name")
    func benzoCategory() {
        #expect(CNSDepressantClassifier.classify(name: "Test Med", category: "Benzodiazepine")
            == .benzodiazepine)
    }
    @Test("Z-Drug category maps to benzodiazepine-class window (fail-safe)")
    func zDrug() {
        #expect(CNSDepressantClassifier.classify(name: "Zolpidem Tartrate", category: "Z-Drug")
            == .benzodiazepine)
    }
    @Test("Known IR opioid by name, category Other")
    func opioidByName() {
        #expect(CNSDepressantClassifier.classify(name: "hydrocodone", category: "Other") == .opioidIR)
    }
    @Test("ER markers upgrade an opioid to opioidER")
    func erOpioid() {
        #expect(CNSDepressantClassifier.classify(name: "Oxycodone ER 10mg", category: "Other") == .opioidER)
        #expect(CNSDepressantClassifier.classify(name: "MS Contin", category: "Other") == .opioidER)
    }
    @Test("Methadone maps to the 72h unknown-long-acting class")
    func methadone() {
        #expect(CNSDepressantClassifier.classify(name: "Methadone 5mg", category: "Other")
            == .methadoneOrUnknownLongActing)
    }
    @Test("Non-CNS-depressants return nil")
    func nonDepressant() {
        #expect(CNSDepressantClassifier.classify(name: "Sertraline 50mg", category: "SSRI") == nil)
        #expect(CNSDepressantClassifier.classify(name: "Allopurinol", category: "Other") == nil)
    }
    @Test("Case-insensitive matching")
    func caseInsensitive() {
        #expect(CNSDepressantClassifier.classify(name: "CLONAZEPAM", category: "other") == .benzodiazepine)
    }
    @Test("Dose windows match spec §14.1")
    func windows() {
        #expect(CNSDepressantClass.benzodiazepine.doseWindow == 12 * 3600)
        #expect(CNSDepressantClass.opioidIR.doseWindow == 8 * 3600)
        #expect(CNSDepressantClass.opioidER.doseWindow == 24 * 3600)
        #expect(CNSDepressantClass.methadoneOrUnknownLongActing.doseWindow == 72 * 3600)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `-only-testing:AnxietyWatchTests/CNSDepressantClassifierTests`, expect compile failure (types missing).

- [ ] **Step 3: Implement**

`CNSDepressantClass.swift`:

```swift
import Foundation

/// Drug classes whose logged doses arm the CNS-depression monitor, with the
/// spec §14.1 pharmacokinetic monitoring windows. Windows are deliberately
/// shorter than elimination half-lives (a multi-day alert = alarm fatigue);
/// they cover the peak respiratory-depression risk period.
enum CNSDepressantClass: String, CaseIterable, Sendable {
    case benzodiazepine
    case opioidIR
    case opioidER
    case methadoneOrUnknownLongActing

    /// Monitoring window measured from the logged dose time (spec §14.1).
    var doseWindow: TimeInterval {
        switch self {
        case .benzodiazepine: 12 * 3600
        case .opioidIR: 8 * 3600
        case .opioidER: 24 * 3600
        case .methadoneOrUnknownLongActing: 72 * 3600
        }
    }
}
```

`CNSDepressantClassifier.swift` — pure, case-insensitive; category match first, then name lists. Opioid names: hydrocodone, oxycodone, morphine, codeine, tramadol, fentanyl, hydromorphone, oxymorphone, buprenorphine, tapentadol. ER markers: " er", " xr", " sr", "extended", "contin", "la ". Methadone checked before the generic opioid list. Benzo names as backstop for category "Other": clonazepam, alprazolam, lorazepam, diazepam, temazepam, midazolam, chlordiazepoxide. Z-drug names: zolpidem, zaleplon, eszopiclone (→ .benzodiazepine). The exact implementation is the engineer's, but every test in Step 1 must pass and matching must be word-boundary-tolerant substring on the lowercased name (e.g. "Oxycodone ER 10mg" hits both lists correctly).

- [ ] **Step 4: Model field + picker**

`MedicationDefinition.swift`: add `/// Raw CNSDepressantClass; nil = not a CNS depressant / unclassified.` `var cnsDepressantClass: String?` (with init param default nil). Lightweight migration.
`AddMedicationView.swift`: add a "CNS depressant class" picker (options: None + the four classes, display names "Benzodiazepine / Z-drug", "Opioid (immediate release)", "Opioid (extended release)", "Methadone / long-acting") defaulting from `CNSDepressantClassifier.classify(name:category:)` when the user hasn't touched it; persist to the new field on save. Never overwrite an explicit existing value when editing.

- [ ] **Step 5: Run suite green** — classifier suite + `-only-testing:AnxietyWatchTests/ModelNormalizationTests` (schema change smoke).
- [ ] **Step 6: Commit** — `feat: CNS-depressant drug classes with §14.1 windows and default classifier`

---

### Task 2: DoseWindowGate + monitoring constants

**Files:**
- Create: `AnxietyWatch/Services/CNSRisk/DoseWindowGate.swift`, `AnxietyWatch/Services/CNSRisk/CNSMonitoringConstants.swift`
- Test: `AnxietyWatchTests/DoseWindowGateTests.swift` (create)

**Interfaces:**
- Consumes: `CNSDepressantClass` (Task 1).
- Produces:

```swift
struct LoggedCNSDose: Equatable, Sendable {
    let timestamp: Date
    let drugClass: CNSDepressantClass
}

enum DoseWindowGate {
    struct Window: Equatable, Sendable {
        let expiry: Date
        let synergyActive: Bool   // benzo + opioid both onboard
    }
    /// §14.1: per-dose windows; benzo+opioid synergy = max(class windows) + 12h
    /// from the LATER dose, 24h floor; stacking always takes the LATER expiry.
    /// Returns nil when no window is active at `now`.
    static func activeWindow(doses: [LoggedCNSDose], at now: Date) -> Window?
}

enum CNSMonitoringConstants {
    static let tickInterval: TimeInterval = 1
    static let samplePersistInterval: TimeInterval = 10
    static let sampleRetention: TimeInterval = 24 * 3600
    static let degradedNotificationID = "cns.monitoring.degraded"
    static let endedNotificationID = "cns.monitoring.ended"
}
```

- [ ] **Step 1: Failing tests** — cover, with `t0 = Date(timeIntervalSince1970: 1_750_000_000)` and hour helpers: single benzo dose active at t0+11h, expired at t0+12h+1s; single IR opioid 8 h; ER 24 h; methadone 72 h; **synergy**: benzo at t0, IR opioid at t0+2h → expiry = t0+2h + max(12h, 8h) + 12h = t0+26h and `synergyActive == true`; synergy floor: benzo at t0, opioid at t0+23h50m → expiry ≥ later dose + 24 h; **stacking never shortens**: benzo at t0 (→ t0+12h), second benzo at t0+1h (→ t0+13h) → expiry t0+13h; a hypothetical shorter later window must not pull expiry earlier (methadone at t0 → t0+72h, then IR opioid at t0+1h: synergy? no — opioid+opioid is not benzo+opioid; expiry stays t0+72h, the max); empty doses → nil; doses fully expired → nil.
- [ ] **Step 2: Verify failure.**
- [ ] **Step 3: Implement** — pure: per-dose expiry = timestamp + class window; synergy detection = any benzo dose whose window overlaps any opioid-class (opioidIR/opioidER/methadone) dose window at any point ≤ now, in which case add a synergy window anchored at the later of the two dose times: `laterDose + max(benzoClassWindow, opioidClassWindow) + 12h`, floored at `laterDose + 24h`. Final expiry = max over all individual and synergy windows. Return nil if max ≤ now.
- [ ] **Step 4: Green.**
- [ ] **Step 5: Commit** — `feat: §14.1 dose-window gate with synergy stacking`

---

### Task 3: Monitoring session models (local-only)

**Files:**
- Create: `AnxietyWatch/Models/MonitoringSession.swift`, `AnxietyWatch/Models/CNSRiskSampleRecord.swift`
- Modify: `AnxietyWatch/App/AnxietyWatchApp.swift` (Schema list), `AnxietyWatchTests/Helpers/TestHelpers.swift` (makeFullContainer)
- Test: `AnxietyWatchTests/MonitoringSessionTests.swift` (create)

**Interfaces:**
- Produces:

```swift
@Model final class MonitoringSession {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    /// Raw ActivationTrigger values active at start (e.g. ["manual", "doseWindow"]).
    var activationTriggers: [String]
    /// §6: per-start, re-markable mid-session. Mutations append to companionLog.
    var companionPresent: Bool
    /// JSON-encoded [(Date, Bool)] history of companion re-marks (small, bounded).
    var companionLogData: Data?
    /// Raw EndReason: "manual", "windowExpired", "deviceLoss", "appTerminated".
    var endReason: String?
    /// Highest CNSAlertTier.rawValue reached during the session.
    var peakTier: Int
    var samples: [CNSRiskSampleRecord]?   // cascade delete
}

@Model final class CNSRiskSampleRecord {
    var timestamp: Date
    var riskScore: Double?      // nil = insufficientData at this instant
    var tier: Int               // CNSAlertTier.rawValue
    var canAssess: Bool
    /// JSON-encoded [CNSSignalAssessment-lite] per-signal contributions for the 1-hour view.
    var contributionsData: Data?
    var session: MonitoringSession?
}
```

Local-only (HealthSample precedent): registered in BOTH schema lists; NOT added to DataExporter/SyncService/RestoreFromServer.

- [ ] **Step 1: Failing tests** — create session in `TestHelpers.makeFullContainer()` context; append samples; prune helper removes samples older than `CNSMonitoringConstants.sampleRetention` relative to a fixed `now` but never samples of the CURRENT (un-ended) session's last hour; cascade delete removes samples with session; peakTier monotonically ratchets via a `recordTier(_:)` helper.
- [ ] **Step 2: Verify failure** (also confirms both Schema lists compile with the new models).
- [ ] **Step 3: Implement** models + a small `MonitoringSessionStore` enum of static helpers (insert sample, prune(before:), ratchet peakTier) so logic stays testable without the coordinator.
- [ ] **Step 4: Green.** Also run `-only-testing:AnxietyWatchTests/RestoreFromServerTests` to prove the restore gate is unaffected by new local-only tables.
- [ ] **Step 5: Commit** — `feat: local-only monitoring session + risk sample models`

---

### Task 4: Sensor adapters + state-preserving companion flip

**Files:**
- Create: `AnxietyWatch/Services/CNSRisk/CNSSensorAdapters.swift`
- Modify: `AnxietyWatch/Services/CNSRisk/CNSDetectionPipeline.swift`, `AnxietyWatch/Services/CNSRisk/CNSAlertTierMachine.swift`
- Modify: `AnxietyWatch/Services/PolarHRMService.swift` (expose a live-sample tap)
- Test: `AnxietyWatchTests/CNSSensorAdapterTests.swift` (create), `AnxietyWatchTests/CNSAlertTierMachineTests.swift` (extend)

**Interfaces:**
- Consumes: `EMAYReading` (`spo2: Int?` 0-100 percent, `pulseRate: Int?`, `hasSpO2`/`hasPulse` — gate on these, never `isMeasuring`); Polar live values.
- Produces:

```swift
enum CNSSensorAdapters {
    /// nil-safe: emits 0, 1, or 2 samples. SpO₂ scale is 0-100 percent on both
    /// sides (EMAYReading and CNSSignalSample) — no conversion. EMAY exposes no
    /// perfusion index; perfusionIndex stays nil and the gate's PI rules are
    /// inert for this source (spec §14.2 fallback: recency + agreement).
    static func samples(from reading: EMAYReading) -> [CNSSignalSample]
    /// Polar: heartRate from live HR (bpm); hrv from per-minute RMSSD (ms) —
    /// corroborating-only kinds, no PI.
    static func samples(polarHR: Int?, at timestamp: Date) -> [CNSSignalSample]
    static func samples(polarRMSSD: Double?, at timestamp: Date) -> [CNSSignalSample]
}
```

`CNSDetectionPipeline`: `mutating func setCompanionPresent(_ present: Bool)` — updates the alone-mode threshold context WITHOUT resetting `CNSAlertTierMachine` sustain state (implementation: the machine stores `companionPresent` as a `var` consulted at threshold-comparison time; move it from init-time capture if needed). `PolarHRMService`: a `var onLiveSample: ((Int?, Date) -> Void)?` (or equivalent minimal tap) invoked on the main actor whenever `state.currentHR` updates — keep the tap optional and inert when nil so existing behavior is unchanged.

- [ ] **Step 1: Failing adapter tests** — EMAY reading with both values → exactly [spo2, heartRate] samples with `.emayOximeter` source, values as Double percent/bpm, `perfusionIndex == nil`; pulse-only reading (`spo2: nil`) → only heartRate (never a fabricated spo2); fully-nil reading → `[]`; polar HR 62 → one `.heartRate`/`.polarH10` sample; polar nil → []; RMSSD 45.0 → one `.hrv` sample.
- [ ] **Step 2: Failing tier-machine test** — drive a machine to `.watch` with alone-mode thresholds mid-sustain toward `.confirm`, flip `setCompanionPresent(true)`, continue driving: sustain clock must NOT restart (assert confirm arrival time unchanged vs a no-flip control run except for the threshold delta itself); `canAssess`/tier unchanged at the flip instant.
- [ ] **Step 3: Implement.** Keep the Polar tap surgical — one closure property + one call site where `state.currentHR` is set.
- [ ] **Step 4: Green** — new suites + FULL existing CNS suites (`CNSDetectionPipelineTests`, `CNSAlertTierMachineTests`, `CNSFusionEngineTests`, `CNSQualityGateTests`, `CNSSeverityScorerTests`) to prove the Phase 1 amendment is behavior-preserving.
- [ ] **Step 5: Commit** — `feat: sensor adapters; state-preserving companion re-mark`

---

### Task 5: Device-state matrix + fallback config

**Files:**
- Create: `AnxietyWatch/Services/CNSRisk/CNSDeviceStateMatrix.swift`
- Test: `AnxietyWatchTests/CNSDeviceStateMatrixTests.swift` (create)

**Interfaces:**
- Produces:

```swift
enum CNSDeviceState: String, Sendable { case reporting, idle, absentFromStart, diedMidSession }

enum CNSDeviceStateClassification: String, Sendable { case ignorable, degradeDisclosed, endMonitoring }

struct CNSDeviceFallbackConfig: Codable, Equatable {
    enum Action: String, Codable, CaseIterable { case klaxon, gentleAlarm, notifyOnly }
    var emay: Action = .klaxon        // losing the only continuous SpO₂ = loudest default
    var polar: Action = .notifyOnly
    var appleWatch: Action = .notifyOnly
    static func load(from defaults: UserDefaults) -> CNSDeviceFallbackConfig
    func save(to defaults: UserDefaults)
}

enum CNSDeviceStateMatrix {
    /// The §7 enumerated matrix. Inputs: per-source state + whether that source
    /// is the ONLY present primary-capable (continuous SpO₂) source.
    static func classify(
        source: CNSSignalSource, state: CNSDeviceState, isOnlyPrimarySource: Bool
    ) -> CNSDeviceStateClassification
    /// Derive a source's state from observation timestamps.
    static func state(
        lastSample: Date?, sessionStart: Date, now: Date, wasEverReporting: Bool
    ) -> CNSDeviceState
}
```

Matrix rules (the §7 "enumerate and mark" task, resolved conservatively): any source `.reporting` → n/a; `.absentFromStart` → `.ignorable` for corroborating-only sources (polarH10, appleWatch), `.degradeDisclosed` for emayOximeter (arming without the primary source is allowed but must be disclosed — decision 5); `.idle`/`.diedMidSession` → `.endMonitoring` if `isOnlyPrimarySource` (EMAY died and nothing else primary — the dangerous silent gap), else `.degradeDisclosed`. Idle threshold: no sample for > 60 s (`gateWindowSeconds`) after having reported.

- [ ] **Step 1: Failing tests** — the full matrix table as parameterized cases (all 3 sources × 4 states × only-primary true/false where meaningful; assert H10-absent-from-start = ignorable per the spec's own example); state derivation (never sampled + wasEverReporting=false → absentFromStart; last sample 61 s ago after reporting → diedMidSession; 30 s ago → reporting); config round-trip through an isolated `UserDefaults` suite (TestHelpers pattern) with defaults preserved.
- [ ] **Step 2-4:** Fail → implement → green.
- [ ] **Step 5: Commit** — `feat: §7 device-state matrix and per-device fallback config`

---

### Task 6: CNSMonitoringCoordinator

**Files:**
- Create: `AnxietyWatch/Services/CNSMonitoringCoordinator.swift`
- Modify: `AnxietyWatch/App/AnxietyWatchApp.swift` (construct in init like emayService; `.environment` inject; launch hook re-arms if a dose window is still active after relaunch)
- Modify: `AnxietyWatch/Views/Medications/MedicationsHubView.swift` (direct-insert `logDose` site) + `AnxietyWatch/Views/Medications/DoseAnxietyPromptView.swift` (prompt-confirm site): after inserting a `MedicationDose`, call `coordinator.doseLogged(dose)` (mirror the DoseFollowUpManager imperative-hook precedent; BOTH sites).
- Test: `AnxietyWatchTests/CNSMonitoringCoordinatorTests.swift` (create)

**Interfaces (public surface):**

```swift
@MainActor @Observable
final class CNSMonitoringCoordinator {
    enum ActivationTrigger: String { case manual, doseWindow, adHoc }
    private(set) var isMonitoring: Bool
    private(set) var activeTriggers: Set<ActivationTrigger>
    private(set) var companionPresent: Bool
    private(set) var currentTier: CNSAlertTier
    private(set) var canAssess: Bool
    private(set) var reportingSources: Set<CNSSignalSource>
    private(set) var statusLine: String   // human-readable for the minimal UI
    func armManually(companionPresent: Bool)
    func armAdHoc()
    func disarm()   // manual disarm always wins; ends session with .manual
    func setCompanionPresent(_ present: Bool)   // re-mark, threads to pipeline state-preservingly
    func doseLogged(_ dose: MedicationDose)     // classifies, extends/starts dose window, arms if configured
    // Testability seam: init takes modelContext, a clock/tick injection point,
    // sample providers (closures returning latest EMAY reading / polar HR / RMSSD),
    // and a notification poster protocol — so tests drive synthetic time and
    // sensors with zero BLE. The production convenience init wires the real
    // EMAYRealtimeService/PolarHRMService observation reads and UNUserNotificationCenter.
}
```

Behavior contract (each item gets a test):
1. **Tick loop:** while monitoring, once per `CNSMonitoringConstants.tickInterval`, reads latest sensor values via the injected providers, appends adapter samples to a rolling buffer (trim > `gateWindowSeconds` + slack), builds `CNSBaselines` (loaded once per session from the most recent `HealthSnapshot` fields: spo2Nadir/restingHR/hrvMean/respRateMean — nil-safe), calls `pipeline.process`, updates `currentTier`/`canAssess`.
2. **Persistence:** every `samplePersistInterval` (10 s), writes a `CNSRiskSampleRecord`; prunes older than retention; ratchets `peakTier`.
3. **Tier edges:** on any tier increase, appends to the session record; Phase 3 hooks here (documented TODO with the phase reference — allowed as an architecture seam note, not missing work).
4. **Dose arming:** `doseLogged` classifies via the medication's `cnsDepressantClass` (fallback: classifier on name/category); maintains a persisted `[LoggedCNSDose]` (UserDefaults, like PendingFollowUp precedent) so relaunch re-arms; consults `DoseWindowGate.activeWindow`; arms with `.doseWindow` trigger when a window is/becomes active; NEVER disarms an active manual/adHoc trigger when a window expires (triggers are independent; monitoring ends when the SET becomes empty).
5. **Window expiry:** when the dose window expires and it's the only trigger, ends the session with `.windowExpired`.
6. **Device states:** per tick, derives each source's `CNSDeviceState`; on a transition to `diedMidSession`/`idle`, classifies via the matrix; `.endMonitoring` → ends session with `.deviceLoss` AND posts the interim local notification (fallback action recorded in the session for Phase 3); `.degradeDisclosed` → posts the degraded notification once per session per source and sets a disclosed flag on `statusLine`. Never a silent stop.
7. **Minimum bar (decision 5):** armed without EMAY reporting → `statusLine` states the bare-minimum device requirement verbatim-ish ("Connect the EMAY oximeter for danger-relevant monitoring — currently can't assess").
8. **Companion re-mark:** mutates session record + companion log + pipeline (state-preserving), and shows the §6 warning text via the UI (Task 7).

- [ ] **Step 1: Failing tests** — synthetic clock + provider closures; cover contracts 1-8 (session lifecycle, dose arming incl. relaunch re-arm from persisted doses, window expiry vs manual trigger independence, device-loss end + notification poster spy called with `endedNotificationID`, degrade disclosed once, min-bar status, companion re-mark preserved mid-sustain). Use `t0` fixed dates; drive ticks manually (no real Timer in tests).
- [ ] **Step 2: Verify failure.**
- [ ] **Step 3: Implement** — production timer via `Task`/`AsyncTimerSequence`-style loop on the main actor, cancelled on disarm; app-lifecycle: session marked `.appTerminated` if a stale un-ended session is found at launch (then re-arm evaluation runs).
- [ ] **Step 4: Green** — coordinator suite + full CNS suites.
- [ ] **Step 5: Commit** — `feat: CNSMonitoringCoordinator — activation, tick loop, sessions, device fallback`

---

### Task 7: Minimal monitoring UI, app wiring, docs, final verification

**Files:**
- Create: `AnxietyWatch/Views/Settings/CNSMonitoringView.swift`
- Modify: `AnxietyWatch/Views/Settings/SettingsView.swift` (nav link near the EMAY row), `AnxietyWatch/App/AnxietyWatchApp.swift` (if not fully wired in Task 6)
- Modify: `README.md`, `docs/FEATURES.md` (one bullet each: monitoring infrastructure exists, alerting lands in Phase 3), `docs/superpowers/specs/2026-07-09-cns-depression-klaxon-design.md` (append an "Phase 2 implementation notes" block recording the Scope Decisions above, esp. the sparse-source deferral and minimum-bar definition)
- Test: manual smoke + full suites

**Steps:**
- [ ] **Step 1:** `CNSMonitoringView` — List: Arm toggle ("Monitor tonight"), "Monitor me now" button (adHoc), companion toggle with the §6 warning footer ("If they leave, re-mark alone — thresholds re-tighten."), status section (statusLine, current tier text, reporting sources, active triggers + window expiry countdown when doseWindow active), per-device fallback pickers (klaxon/gentle/notify — writes `CNSDeviceFallbackConfig`). Plain SwiftUI, no styling ambitions (Phase 3 redesigns).
- [ ] **Step 2:** Settings nav link; verify EMAY continuous-mode interplay documented in a footer (monitoring auto-starts the EMAY session via the coordinator when armed — reuse `service.start()` semantics; never fight the user's continuous-mode toggle).
- [ ] **Step 3:** Docs edits per file list.
- [ ] **Step 4:** Full iOS suite green, zero warnings; SwiftLint clean; repo grep: every new constant referenced from tests at least once (`grep -rn 'CNSMonitoringConstants\.' AnxietyWatchTests/` non-empty per constant).
- [ ] **Step 5:** Simulator smoke: build, launch, Settings → CNS Monitoring renders; arm ad-hoc; status shows "can't assess" + min-bar line (no BLE in sim); disarm ends session. Screenshot.
- [ ] **Step 6: Commit** — `feat: minimal CNS monitoring surface + wiring (Phase 2 complete)`

---

## Self-Review Notes

- **Spec coverage:** §14.1 windows/stacking ✔ T1+T2; session model + rolling samples ✔ T3; adapters with §14.2 quality threading ✔ T4 (PI nil for EMAY documented — real device exposes none; gate PI rules inert, recency/agreement still apply); §7 matrix + per-device fallback ✔ T5+T6; §6 manual/adHoc/companion + re-mark warning + min-bar guardrail ✔ T6+T7; §14.3 default triggers ✔ T6; "never silent stop" ✔ T6 contract 6; EMAY promotion ✔ already-done (decision 9).
- **Deliberately deferred (documented):** auto-sleep nudge, sparse-source gate, klaxon/haptic execution, alone-mode fast escalation, 1-hour view rendering — all Phase 3, recorded in the spec appendix (T7 Step 3).
- **Type consistency:** `CNSDepressantClass` raw String ↔ `MedicationDefinition.cnsDepressantClass: String?` ↔ `LoggedCNSDose.drugClass`; `ActivationTrigger` raws ↔ `MonitoringSession.activationTriggers: [String]`; `CNSAlertTier.rawValue: Int` ↔ `peakTier`/`tier` fields; adapter outputs are Phase 1's exact `CNSSignalSample`.
- **Ordering:** T1→T2 (classes before gate), T3 independent after T1, T4/T5 independent, T6 needs T1-T5, T7 last. Every task leaves the full suite green.
