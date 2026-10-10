# CNS-Depression Klaxon — Phase 1: Detection Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure, fully unit-testable CNS-depression risk detection engine — quality gates, baseline-relative severity scoring, cross-sensor fusion, and the hysteretic alert-tier state machine — per `docs/superpowers/specs/2026-07-09-cns-depression-klaxon-design.md` §3, §5, §14.2, §14.4.

**Architecture:** Pure value types and stateless/mutating-struct logic under `AnxietyWatch/Services/CNSRisk/` — no CoreBluetooth, no SwiftData, no SwiftUI, no `Date.now` inside logic. Sensor adapters (Phase 2) will normalize readings into `CNSSignalSample`; the alerting pipeline (Phase 3) will consume `CNSAlertTier` transitions. A `CNSDetectionPipeline` composes gate → scorer → fusion → tier machine and is the single entry point later phases call.

**Tech Stack:** Swift 5.9+, Swift Testing (`@Test`/`#expect`), no external dependencies.

## Phasing context

- **This plan (Phase 1):** detection engine + synthetic-trace replay tests. No user-visible change; deliverable is a reviewed, tested engine.
- **Phase 2 (separate plan, after this merges):** activation gating (dose windows §14.1), monitoring-session data model, real sensor adapters (EMAY/Polar/HealthKit), EMAY service promotion to app-scoped environment, device-state matrix & per-device fallback.
- **Phase 3 (separate plan):** `KlaxonAlarmService`, watch haptics, klaxon audio + slide-to-dismiss, settings UI, dashboard indicator, 1-hour detail view, Critical Alerts entitlement path.

## Global Constraints

- **Swift Testing only** (`import Testing`, `@Test`, `#expect`) — never XCTest.
- **Float comparisons:** never `#expect(x == y)` on `Double` — use `abs(actual - expected) < 0.001`.
- **Fixed reference dates** in all tests — never `Date.now` / `Date()` in assertions. Use `Date(timeIntervalSince1970: 1_750_000_000)` as `t0`.
- **Never coerce invalid/missing sensor data to a value** (spec §5.1, §11). Invalid contributes *nothing*; genuine extremes are preserved.
- **Asymmetry rule (spec §14.2):** reassure only on fully-passing data; a low-quality window surfaces as "can't assess," never "OK".
- **SwiftLint:** 150-char warn / 200 error; zero warnings (CI runs `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`).
- **Magic numbers:** every threshold lives in `CNSThresholds` (single source of truth); tests reference the constants, not re-typed literals.
- **Public repo:** no personal medical assertions, no PII, in code/comments/commits.
- **Naming:** Swift API design guidelines; allowed abbreviations: HR, HRV, RR (context-disambiguated), BP, SpO2, CNS, PI (perfusion index — comment at first use per file).
- **New Swift files auto-register** with the target (synchronized pbxproj groups) — do NOT edit `project.pbxproj`.
- **Branch:** all work on `feat/klaxon-phase1-detection-engine` off `main`. Never commit to `main`.
- **Test run command (per-suite):** `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/<SuiteName>` (or XcodeBuildMCP `test_sim` with the same `-only-testing` extra arg — session defaults are configured).

## Spec erratum (documented deviation)

Spec §3 writes the SpO₂ early-warning trigger as “sustained below **max**(88%, personal-nadir − N)”. For a sleep-apnea user with a personal nadir of 84%, `max(88, 84 − 3) = 88` — a trigger *above* their normal nightly dips, which recreates the exact nightly-false-alarm failure the spec’s own “confound” section (§3) forbids. The intended semantics must be **min**: `min(88, nadir − 3)` caps the trigger at 88% for healthy baselines and pushes it *below* the personal nadir for apnea-affected baselines. Phase 1 implements `min` (as `CNSThresholds.spo2Onset(nadirBaseline:)`); Task 9 records the erratum in the spec file itself.

---

## File Structure

| File | Responsibility |
|---|---|
| `AnxietyWatch/Services/CNSRisk/CNSSignal.swift` (create) | Core value types: signal kinds, sources, samples, per-signal assessments, composite risk assessment, alert tier |
| `AnxietyWatch/Services/CNSRisk/CNSThresholds.swift` (create) | Every tunable constant: onsets/floors, fidelities, fusion weights, tier thresholds, sustain durations |
| `AnxietyWatch/Services/CNSRisk/CNSQualityGate.swift` (create) | §14.2 rolling-60 s per-(source,kind) window verdict: coverage/contiguity, perfusion, artifact rules |
| `AnxietyWatch/Services/CNSRisk/CNSSeverityScorer.swift` (create) | §5.1 baseline-relative severity (0–1) + confidence (0–1) per signal window |
| `AnxietyWatch/Services/CNSRisk/CNSFusionEngine.swift` (create) | §5.2 cross-sensor fusion → composite risk score or `.insufficientData`; lone-sensor damping |
| `AnxietyWatch/Services/CNSRisk/CNSAlertTierMachine.swift` (create) | §5.3 hysteretic `clear → watch → confirm → klaxon` state machine; §14.4 alone/companion delta; can't-assess hold |
| `AnxietyWatch/Services/CNSRisk/CNSDetectionPipeline.swift` (create) | Composes gate → scorer → fusion → tier; the single entry point Phase 2 calls |
| `AnxietyWatchTests/CNSQualityGateTests.swift` (create) | Gate unit tests |
| `AnxietyWatchTests/CNSSeverityScorerTests.swift` (create) | Severity/confidence unit tests |
| `AnxietyWatchTests/CNSFusionEngineTests.swift` (create) | Fusion unit tests |
| `AnxietyWatchTests/CNSAlertTierMachineTests.swift` (create) | Tier-machine unit tests |
| `AnxietyWatchTests/SyntheticTraceFactory.swift` (create) | §12 synthetic-trace replay harness (test-target helper) |
| `AnxietyWatchTests/CNSDetectionPipelineTests.swift` (create) | End-to-end replay: declining traces across sensor combinations |
| `docs/superpowers/specs/2026-07-09-cns-depression-klaxon-design.md` (modify, Task 9) | Record the min/max erratum |

---

### Task 1: Core signal types and thresholds

**Files:**
- Create: `AnxietyWatch/Services/CNSRisk/CNSSignal.swift`
- Create: `AnxietyWatch/Services/CNSRisk/CNSThresholds.swift`
- Test: `AnxietyWatchTests/CNSSeverityScorerTests.swift` (types + `spo2Onset` behavior; scorer tests extend this file in Task 4)

**Interfaces:**
- Consumes: nothing (foundation task).
- Produces (later tasks rely on these exact names):
  - `enum CNSSignalKind: CaseIterable, Sendable { case spo2, respiratoryRate, heartRate, hrv }`
  - `enum CNSSignalSource: CaseIterable, Sendable { case emayOximeter, polarH10, appleWatch }`
  - `struct CNSSignalSample: Equatable, Sendable` — `kind`, `source`, `value: Double`, `timestamp: Date`, `perfusionIndex: Double?`, `isArtifact: Bool` (memberwise init with `perfusionIndex: Double? = nil, isArtifact: Bool = false` defaults)
  - `struct CNSBaselines: Equatable, Sendable` — `spo2Nadir: Double?`, `restingHeartRate: Double?`, `hrvMean: Double?`, `respiratoryRateMean: Double?`; `static let none`
  - `struct CNSSignalAssessment: Equatable, Sendable` — `kind`, `source`, `severity: Double`, `confidence: Double`
  - `enum CNSRiskAssessment: Equatable, Sendable { case insufficientData; case assessed(riskScore: Double, contributions: [CNSSignalAssessment]) }`
  - `enum CNSAlertTier: Int, Comparable, CaseIterable, Sendable { case clear = 0, watch, confirm, klaxon }`
  - `struct CNSThresholds: Sendable` with `static let standard` and `func spo2Onset(nadirBaseline: Double?) -> Double`

- [x] **Step 1: Write the failing tests**

Create `AnxietyWatchTests/CNSSeverityScorerTests.swift`:

```swift
import Foundation
import Testing

@testable import AnxietyWatch

/// Covers `CNSThresholds` + the pure severity/confidence scoring in
/// `CNSSeverityScorer` (spec §3, §5.1, §14.2). All values baseline-relative;
/// every constant referenced via `CNSThresholds.standard` — no re-typed literals.
struct CNSSeverityScorerTests {
    private let thresholds = CNSThresholds.standard

    @Test("Alert tiers order clear < watch < confirm < klaxon")
    func tierOrdering() {
        #expect(CNSAlertTier.clear < .watch)
        #expect(CNSAlertTier.watch < .confirm)
        #expect(CNSAlertTier.confirm < .klaxon)
    }

    @Test("SpO2 onset is min(default, nadir - margin) — spec-erratum semantics")
    func spo2OnsetRespectsApneaBaseline() {
        // No baseline → the 88% default.
        #expect(abs(thresholds.spo2Onset(nadirBaseline: nil) - thresholds.spo2OnsetDefault) < 0.001)
        // Healthy nadir (96): default caps the onset at 88 — nadir − 3 = 93 would over-trigger.
        #expect(abs(thresholds.spo2Onset(nadirBaseline: 96) - thresholds.spo2OnsetDefault) < 0.001)
        // Apnea-affected nadir (84): onset drops BELOW the personal nadir (81),
        // so normal nightly dips never trigger (the spec's central confound).
        #expect(abs(thresholds.spo2Onset(nadirBaseline: 84) - 81) < 0.001)
    }
}
```

- [x] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/CNSSeverityScorerTests`
Expected: BUILD FAILURE — `cannot find 'CNSThresholds' in scope` (compile error counts as the failing state for type-creation tasks).

- [x] **Step 3: Create the types**

Create `AnxietyWatch/Services/CNSRisk/CNSSignal.swift`:

```swift
import Foundation

/// Which physiological signal a sample carries. SpO₂ and respiratory rate are
/// the primary CNS-depression signals (opioid → rate, benzo → depth/SpO₂);
/// heart rate and HRV corroborate but never escalate alone (spec §3, §5.2).
enum CNSSignalKind: CaseIterable, Sendable {
    case spo2             // percent, 0–100 scale (NOT a 0–1 fraction)
    case respiratoryRate  // breaths per minute
    case heartRate        // beats per minute
    case hrv              // ms (RMSSD-family; compared as a fraction of baseline)
}

/// Which physical sensor produced a sample. Fidelity per (kind, source) lives
/// in `CNSThresholds` — e.g. Apple Watch SpO₂ is periodic spot-checks, not
/// continuous, so it scores lower confidence than the EMAY stream (spec §4).
enum CNSSignalSource: CaseIterable, Sendable {
    case emayOximeter
    case polarH10
    case appleWatch
}

/// One normalized reading. Phase 2 sensor adapters construct these; nothing in
/// the engine ever touches a raw BLE frame or HealthKit sample.
struct CNSSignalSample: Equatable, Sendable {
    let kind: CNSSignalKind
    let source: CNSSignalSource
    let value: Double
    let timestamp: Date
    /// Perfusion index where the source exposes it (oximeters). nil = source
    /// has no PI channel (Apple Watch, Polar) — the gate then skips PI rules.
    let perfusionIndex: Double?
    /// Upstream artifact/ectopic flag (e.g. RR-interval artifact detection).
    let isArtifact: Bool

    init(
        kind: CNSSignalKind,
        source: CNSSignalSource,
        value: Double,
        timestamp: Date,
        perfusionIndex: Double? = nil,
        isArtifact: Bool = false
    ) {
        self.kind = kind
        self.source = source
        self.value = value
        self.timestamp = timestamp
        self.perfusionIndex = perfusionIndex
        self.isArtifact = isArtifact
    }
}

/// Personal-baseline inputs (spec §3: deviation-from-personal-baseline, never
/// population-absolute). Phase 2 populates these from `BaselineCalculator` /
/// `HealthSnapshot`; nil = no baseline yet → scorer falls back to conservative
/// defaults at reduced confidence.
struct CNSBaselines: Equatable, Sendable {
    var spo2Nadir: Double?
    var restingHeartRate: Double?
    var hrvMean: Double?
    var respiratoryRateMean: Double?

    static let none = CNSBaselines(
        spo2Nadir: nil, restingHeartRate: nil, hrvMean: nil, respiratoryRateMean: nil
    )
}

/// Per-signal scoring output (spec §5.1): how far toward danger (severity)
/// and how much to trust it (confidence). Both 0–1.
struct CNSSignalAssessment: Equatable, Sendable {
    let kind: CNSSignalKind
    let source: CNSSignalSource
    let severity: Double
    let confidence: Double
}

/// Composite fusion output (spec §5.2). `.insufficientData` is an explicit
/// first-class state — the engine never fabricates a "safe" score from
/// nothing (spec §11: false reassurance is the worst outcome).
enum CNSRiskAssessment: Equatable, Sendable {
    case insufficientData
    case assessed(riskScore: Double, contributions: [CNSSignalAssessment])
}

/// Alert escalation tiers (spec §5.3). Raw values encode the ordering.
enum CNSAlertTier: Int, Comparable, CaseIterable, Sendable {
    case clear = 0
    case watch
    case confirm
    case klaxon

    static func < (lhs: CNSAlertTier, rhs: CNSAlertTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
```

Create `AnxietyWatch/Services/CNSRisk/CNSThresholds.swift`:

```swift
import Foundation

/// Every tunable constant in the CNS-depression detection engine, in one
/// place (spec §3 "working thresholds", §14.2 quality gates, §14.4 companion
/// delta). Values are design inputs over population data — tunable envelopes,
/// not medical advice. Tests reference these members; never re-type a literal.
struct CNSThresholds: Sendable {

    // MARK: - SpO₂ (percent, 0–100)

    /// Trigger ceiling for users without an apnea-lowered baseline.
    var spo2OnsetDefault: Double = 88
    /// Subtracted from the personal SpO₂-nadir baseline (spec §3, N).
    var spo2NadirMargin: Double = 3
    /// PRODIGY terminal floor — severity saturates at 1.0 here (spec §3).
    var spo2Floor: Double = 85

    /// Early-warning onset: severity becomes nonzero below this value.
    /// `min`, NOT the spec's literal `max` — see the plan's "Spec erratum"
    /// section: `max` would put the trigger ABOVE an apnea user's normal
    /// nightly dips and alarm every night (the spec's own forbidden failure).
    func spo2Onset(nadirBaseline: Double?) -> Double {
        guard let nadir = nadirBaseline else { return spo2OnsetDefault }
        return min(spo2OnsetDefault, nadir - spo2NadirMargin)
    }

    // MARK: - Respiratory rate (breaths/min)

    /// Bradypnea early-warning onset (spec §3: sustained < ~8–10/min).
    var respiratoryRateOnset: Double = 10
    /// PRODIGY terminal floor (RR ≤ 5).
    var respiratoryRateFloor: Double = 5

    // MARK: - Heart rate (bpm) — corroborating only

    /// Subtracted from the personal resting-HR baseline for the bradycardia
    /// onset; without a baseline, `heartRateOnsetDefault` applies.
    var heartRateBaselineMargin: Double = 15
    var heartRateOnsetDefault: Double = 50
    /// Severity saturates at profound bradycardia.
    var heartRateFloor: Double = 40

    // MARK: - HRV — corroborating only, as a fraction of the personal baseline mean

    /// Severity becomes nonzero below this fraction of baseline.
    var hrvOnsetFraction: Double = 0.6
    /// Severity saturates at this fraction (acute collapse).
    var hrvFloorFraction: Double = 0.3

    // MARK: - Quality gate (spec §14.2)

    var gateWindowSeconds: TimeInterval = 60
    /// Contiguous good-quality coverage required inside the window.
    var gateMinContiguousGoodSeconds: TimeInterval = 30
    /// Max gap between consecutive samples that still counts as contiguous
    /// (sources stream ~1 Hz; a 3 s hole breaks the run).
    var gateMaxContiguousGapSeconds: TimeInterval = 3
    /// PI below this → the value can't be trusted for reassurance (SpO₂
    /// overestimates at low perfusion — the false-reassurance case).
    var perfusionSoftFloor: Double = 0.6
    /// PI below this → hard reject the sample entirely.
    var perfusionHardFloor: Double = 0.4
    /// More than this fraction of artifact samples → window indeterminate.
    var maxArtifactFraction: Double = 0.05

    // MARK: - Confidence

    /// Multiplier when the relevant personal baseline is missing.
    var missingBaselineConfidenceFactor: Double = 0.8
    /// Per-(kind, source) fidelity: how much a passing window from this
    /// source is worth (spec §4 sensor-capability table). 0 = the source
    /// does not produce this signal.
    func sourceFidelity(kind: CNSSignalKind, source: CNSSignalSource) -> Double {
        switch (kind, source) {
        case (.spo2, .emayOximeter): return 0.9   // continuous, verified stream
        case (.spo2, .appleWatch): return 0.5     // periodic spot-checks only
        case (.spo2, .polarH10): return 0
        case (.respiratoryRate, .appleWatch): return 0.6  // sleep-session estimate
        case (.respiratoryRate, .emayOximeter): return 0
        case (.respiratoryRate, .polarH10): return 0      // derived RR is a future phase
        case (.heartRate, .polarH10): return 0.95
        case (.heartRate, .emayOximeter): return 0.8      // pulse from the oximeter
        case (.heartRate, .appleWatch): return 0.7
        case (.hrv, .polarH10): return 0.9
        case (.hrv, .appleWatch): return 0.6
        case (.hrv, .emayOximeter): return 0
        }
    }

    // MARK: - Fusion (spec §5.2)

    /// Below this best-available confidence the composite is `.insufficientData`.
    var minimumAssessableConfidence: Double = 0.2
    /// Confidence soft-scales a primary signal's severity between this floor
    /// and 1.0 (score = severity × (floor + (1 − floor) × confidence)) instead
    /// of multiplying directly — a fully-saturated severity from a
    /// moderate-confidence continuous stream must still be able to reach the
    /// klaxon threshold (an EMAY-only night with no baseline yet is the
    /// primary overdose scenario, at confidence 0.72).
    var confidenceSoftScaleFloor: Double = 0.5
    /// Per-corroborating-signal boost cap and scale.
    var corroborationScale: Double = 0.3
    var corroborationPerSignalCap: Double = 0.15
    /// Bonus when ≥ 2 distinct sources are independently elevated.
    var multiSourceBonus: Double = 0.1
    /// "Elevated" for corroboration/multi-source purposes.
    var elevatedSeverityFloor: Double = 0.5
    var elevatedConfidenceFloor: Double = 0.5
    /// A single source screaming alone is capped below the confirm tier
    /// unless extreme AND high-confidence (spec §5.2).
    var loneSourceRiskCap: Double = 0.55
    var loneSourceOverrideSeverity: Double = 0.9
    /// 0.7, not higher: the highest-fidelity continuous source (EMAY, 0.9)
    /// without a personal baseline lands at 0.9 × 1.0 × 0.8 = 0.72 confidence,
    /// and a saturated lone EMAY MUST be able to escalate (spec §5.2's
    /// "extreme AND strict validity" single-sensor path).
    var loneSourceOverrideConfidence: Double = 0.7
    /// Severity at/above which an assessment counts toward lone-source logic.
    var contributingSeverityFloor: Double = 0.2

    // MARK: - Tiers (spec §5.3, §14.4)

    var watchThreshold: Double = 0.3
    var confirmThreshold: Double = 0.6
    var klaxonThreshold: Double = 0.85
    /// Alone-mode lowers every tier threshold by this much (fires earlier
    /// while the user is still rousable — spec §14.4; delta deliberately
    /// modest). Companion-present uses the base thresholds.
    var aloneModeThresholdDelta: Double = 0.05
    /// Sustain required to RISE into watch/confirm (spec §3: ≥ ~60–90 s).
    var riseSustainSeconds: TimeInterval = 60
    /// Sustain to escalate confirm → klaxon (shorter: danger already confirmed).
    var klaxonRiseSustainSeconds: TimeInterval = 30
    /// Score must sit below (threshold − hysteresis) this long to FALL.
    var clearSustainSeconds: TimeInterval = 120
    var clearHysteresis: Double = 0.1

    static let standard = CNSThresholds()
}
```

- [x] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/CNSSeverityScorerTests`
Expected: PASS (2 tests).

- [x] **Step 5: Commit**

```bash
git add AnxietyWatch/Services/CNSRisk/CNSSignal.swift AnxietyWatch/Services/CNSRisk/CNSThresholds.swift AnxietyWatchTests/CNSSeverityScorerTests.swift
git commit -m "feat(klaxon): CNS detection engine core types and thresholds"
```

---

### Task 2: Quality gate — coverage and contiguity

**Files:**
- Create: `AnxietyWatch/Services/CNSRisk/CNSQualityGate.swift`
- Test: Create `AnxietyWatchTests/CNSQualityGateTests.swift`

**Interfaces:**
- Consumes: `CNSSignalSample`, `CNSThresholds` (Task 1).
- Produces:
  - `enum CNSWindowQuality: Equatable, Sendable { case pass, indeterminate }`
  - `struct CNSWindowVerdict: Equatable, Sendable { let quality: CNSWindowQuality; let goodCoverageFraction: Double }`
  - `enum CNSQualityGate` with:
    - `static func goodSamples(_ samples: [CNSSignalSample], thresholds: CNSThresholds) -> [CNSSignalSample]`
    - `static func evaluate(samples: [CNSSignalSample], at now: Date, thresholds: CNSThresholds) -> CNSWindowVerdict`

- [x] **Step 1: Write the failing tests**

Create `AnxietyWatchTests/CNSQualityGateTests.swift`:

```swift
import Foundation
import Testing

@testable import AnxietyWatch

/// Covers the §14.2 rolling-window quality gate: contiguous-coverage,
/// perfusion, and artifact rules. Samples are generated at 1 Hz to mirror
/// the EMAY stream cadence.
struct CNSQualityGateTests {
    private let thresholds = CNSThresholds.standard
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    /// 1 Hz SpO₂ samples covering `range` (seconds before `now` = t0 + 60).
    private func samples(
        secondsAgo range: ClosedRange<Int>,
        value: Double = 95,
        perfusionIndex: Double? = 1.2,
        isArtifact: Bool = false
    ) -> [CNSSignalSample] {
        range.map { ago in
            CNSSignalSample(
                kind: .spo2, source: .emayOximeter, value: value,
                timestamp: t0.addingTimeInterval(60 - Double(ago)),
                perfusionIndex: perfusionIndex, isArtifact: isArtifact
            )
        }
    }

    private var now: Date { t0.addingTimeInterval(60) }

    @Test("A full 60s of good 1Hz samples passes with full coverage")
    func fullWindowPasses() {
        let verdict = CNSQualityGate.evaluate(
            samples: samples(secondsAgo: 0...59), at: now, thresholds: thresholds
        )
        #expect(verdict.quality == .pass)
        #expect(verdict.goodCoverageFraction > 0.9)
    }

    @Test("35s contiguous good run passes the 30s coverage bar")
    func contiguousRunAboveBarPasses() {
        let verdict = CNSQualityGate.evaluate(
            samples: samples(secondsAgo: 0...34), at: now, thresholds: thresholds
        )
        #expect(verdict.quality == .pass)
    }

    @Test("40s of good data split into scattered 10s fragments is indeterminate")
    func scatteredFragmentsFail() {
        // Four 10-second runs separated by 5-plus-second holes: total coverage
        // 40s but no contiguous run reaches 30s (spec: "not scattered fragments").
        let fragments = samples(secondsAgo: 0...9) + samples(secondsAgo: 15...24)
            + samples(secondsAgo: 30...39) + samples(secondsAgo: 45...54)
        let verdict = CNSQualityGate.evaluate(
            samples: fragments, at: now, thresholds: thresholds
        )
        #expect(verdict.quality == .indeterminate)
    }

    @Test("Empty window is indeterminate with zero coverage")
    func emptyWindowIndeterminate() {
        let verdict = CNSQualityGate.evaluate(samples: [], at: now, thresholds: thresholds)
        #expect(verdict.quality == .indeterminate)
        #expect(abs(verdict.goodCoverageFraction) < 0.001)
    }

    @Test("Samples older than the window are ignored")
    func staleSamplesExcluded() {
        // A perfect run that ended 2 minutes ago must not pass the gate now.
        let stale = samples(secondsAgo: 120...179)
        let verdict = CNSQualityGate.evaluate(samples: stale, at: now, thresholds: thresholds)
        #expect(verdict.quality == .indeterminate)
    }
}
```

- [x] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/CNSQualityGateTests`
Expected: BUILD FAILURE — `cannot find 'CNSQualityGate' in scope`.

- [x] **Step 3: Implement the gate (coverage rules only; perfusion/artifact land in Task 3)**

Create `AnxietyWatch/Services/CNSRisk/CNSQualityGate.swift`:

```swift
import Foundation

/// Verdict for one rolling window of one (kind, source) stream.
enum CNSWindowQuality: Equatable, Sendable {
    /// Enough contiguous good-quality data to score.
    case pass
    /// Can't assess — never treated as "OK" and never as danger (spec §14.2
    /// asymmetry rule). The tier machine holds, the UI says "can't assess".
    case indeterminate
}

struct CNSWindowVerdict: Equatable, Sendable {
    let quality: CNSWindowQuality
    /// Fraction of the window covered by good samples (density input to
    /// the scorer's confidence).
    let goodCoverageFraction: Double
}

/// The §14.2 per-source rolling-window data-quality gate. Pure functions —
/// callers pass `now` explicitly (no hidden clock).
enum CNSQualityGate {

    /// The samples that count as "good": non-artifact and, where the source
    /// exposes a perfusion index, PI at or above the soft floor. This single
    /// filter is shared with the scorer so "what passed the gate" and "what
    /// gets scored" can never diverge.
    static func goodSamples(
        _ samples: [CNSSignalSample], thresholds: CNSThresholds
    ) -> [CNSSignalSample] {
        samples.filter { sample in
            if sample.isArtifact { return false }
            if let pi = sample.perfusionIndex, pi < thresholds.perfusionSoftFloor { return false }
            return true
        }
    }

    static func evaluate(
        samples: [CNSSignalSample], at now: Date, thresholds: CNSThresholds
    ) -> CNSWindowVerdict {
        let windowStart = now.addingTimeInterval(-thresholds.gateWindowSeconds)
        let inWindow = samples
            .filter { $0.timestamp > windowStart && $0.timestamp <= now }
            .sorted { $0.timestamp < $1.timestamp }
        guard !inWindow.isEmpty else {
            return CNSWindowVerdict(quality: .indeterminate, goodCoverageFraction: 0)
        }

        let good = goodSamples(inWindow, thresholds: thresholds)
        let coverage = min(
            Double(good.count) / thresholds.gateWindowSeconds, 1.0
        )

        guard longestContiguousRunSeconds(of: good, thresholds: thresholds)
            >= thresholds.gateMinContiguousGoodSeconds else {
            return CNSWindowVerdict(quality: .indeterminate, goodCoverageFraction: coverage)
        }
        return CNSWindowVerdict(quality: .pass, goodCoverageFraction: coverage)
    }

    /// Length of the longest run of good samples whose inter-sample gaps all
    /// stay within `gateMaxContiguousGapSeconds`.
    private static func longestContiguousRunSeconds(
        of sortedGood: [CNSSignalSample], thresholds: CNSThresholds
    ) -> TimeInterval {
        guard let first = sortedGood.first else { return 0 }
        var longest: TimeInterval = 0
        var runStart = first.timestamp
        var previous = first.timestamp
        for sample in sortedGood.dropFirst() {
            if sample.timestamp.timeIntervalSince(previous) > thresholds.gateMaxContiguousGapSeconds {
                longest = max(longest, previous.timeIntervalSince(runStart))
                runStart = sample.timestamp
            }
            previous = sample.timestamp
        }
        return max(longest, previous.timeIntervalSince(runStart))
    }
}
```

- [x] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/CNSQualityGateTests`
Expected: PASS (5 tests).

- [x] **Step 5: Commit**

```bash
git add AnxietyWatch/Services/CNSRisk/CNSQualityGate.swift AnxietyWatchTests/CNSQualityGateTests.swift
git commit -m "feat(klaxon): quality gate coverage and contiguity rules"
```

---

### Task 3: Quality gate — perfusion and artifact rules

**Files:**
- Modify: `AnxietyWatch/Services/CNSRisk/CNSQualityGate.swift` (add artifact-fraction rule to `evaluate`)
- Test: Modify `AnxietyWatchTests/CNSQualityGateTests.swift` (append tests)

**Interfaces:**
- Consumes/Produces: same as Task 2 — `evaluate` gains the artifact rule; signature unchanged.

- [x] **Step 1: Write the failing tests**

Append inside `struct CNSQualityGateTests`:

```swift
    @Test("Low-perfusion samples (PI below soft floor) don't count as good")
    func lowPerfusionExcluded() {
        // 60s stream but PI 0.5 throughout: SpO2 overestimates at low
        // perfusion — trusting it is the false-reassurance case.
        let verdict = CNSQualityGate.evaluate(
            samples: samples(secondsAgo: 0...59, perfusionIndex: 0.5),
            at: now, thresholds: thresholds
        )
        #expect(verdict.quality == .indeterminate)
    }

    @Test("Sources without a PI channel are not PI-gated")
    func noPerfusionChannelSkipsPIRules() {
        let watchSamples = (0...59).map { ago in
            CNSSignalSample(
                kind: .heartRate, source: .appleWatch, value: 62,
                timestamp: t0.addingTimeInterval(60 - Double(ago))
            )
        }
        let verdict = CNSQualityGate.evaluate(
            samples: watchSamples, at: now, thresholds: thresholds
        )
        #expect(verdict.quality == .pass)
    }

    @Test("More than 5% artifact samples makes the window indeterminate")
    func artifactFractionRule() {
        // 56 good + 4 artifact = 6.7% artifacts within the window's samples.
        let mixed = samples(secondsAgo: 0...55) + samples(secondsAgo: 56...59, isArtifact: true)
        let verdict = CNSQualityGate.evaluate(samples: mixed, at: now, thresholds: thresholds)
        #expect(verdict.quality == .indeterminate)
    }

    @Test("At most 5% artifacts still passes")
    func smallArtifactFractionPasses() {
        // 58 good + 2 artifact = 3.3%.
        let mixed = samples(secondsAgo: 0...57) + samples(secondsAgo: 58...59, isArtifact: true)
        let verdict = CNSQualityGate.evaluate(samples: mixed, at: now, thresholds: thresholds)
        #expect(verdict.quality == .pass)
    }
```

- [x] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/CNSQualityGateTests`
Expected: FAIL — `artifactFractionRule` (evaluate has no artifact-fraction rule yet); `lowPerfusionExcluded`, `noPerfusionChannelSkipsPIRules`, `smallArtifactFractionPasses` already pass via `goodSamples`.

- [x] **Step 3: Add the artifact-fraction rule**

In `CNSQualityGate.evaluate`, after the `guard !inWindow.isEmpty` block, insert:

```swift
        // §14.2: > maxArtifactFraction artifact/ectopic samples in the window
        // → indeterminate, regardless of how much clean coverage remains.
        let artifactCount = inWindow.filter(\.isArtifact).count
        let artifactFraction = Double(artifactCount) / Double(inWindow.count)
        let good = goodSamples(inWindow, thresholds: thresholds)
        let coverage = min(Double(good.count) / thresholds.gateWindowSeconds, 1.0)
        guard artifactFraction <= thresholds.maxArtifactFraction else {
            return CNSWindowVerdict(quality: .indeterminate, goodCoverageFraction: coverage)
        }
```

…and delete the now-duplicated original `let good` / `let coverage` lines below it (the rule computes them first so the verdict can still report coverage).

- [x] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/CNSQualityGateTests`
Expected: PASS (9 tests).

- [x] **Step 5: Commit**

```bash
git add AnxietyWatch/Services/CNSRisk/CNSQualityGate.swift AnxietyWatchTests/CNSQualityGateTests.swift
git commit -m "feat(klaxon): quality gate perfusion and artifact rules"
```

---

### Task 4: Severity scoring — SpO₂ and respiratory rate

**Files:**
- Create: `AnxietyWatch/Services/CNSRisk/CNSSeverityScorer.swift`
- Test: Modify `AnxietyWatchTests/CNSSeverityScorerTests.swift` (append)

**Interfaces:**
- Consumes: `CNSSignalSample`, `CNSBaselines`, `CNSThresholds`, `CNSWindowVerdict`, `CNSQualityGate.goodSamples` (Tasks 1–3).
- Produces:
  - `enum CNSSeverityScorer` with:
    - `static func rampSeverity(value: Double, onset: Double, floor: Double) -> Double` (lower-is-worse linear ramp, clamped 0…1)
    - `static func assess(kind: CNSSignalKind, source: CNSSignalSource, samples: [CNSSignalSample], verdict: CNSWindowVerdict, baselines: CNSBaselines, thresholds: CNSThresholds) -> CNSSignalAssessment?` — nil when the verdict is `.indeterminate` or the source has zero fidelity for the kind. Representative value = median of good samples.

- [x] **Step 1: Write the failing tests**

Append inside `struct CNSSeverityScorerTests`:

```swift
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    private func spo2Samples(value: Double) -> [CNSSignalSample] {
        (0...59).map { ago in
            CNSSignalSample(
                kind: .spo2, source: .emayOximeter, value: value,
                timestamp: t0.addingTimeInterval(60 - Double(ago)), perfusionIndex: 1.2
            )
        }
    }

    private var passingVerdict: CNSWindowVerdict {
        CNSWindowVerdict(quality: .pass, goodCoverageFraction: 1.0)
    }

    @Test("Ramp: zero at onset, one at floor, linear between, clamped outside")
    func rampBehavior() {
        #expect(abs(CNSSeverityScorer.rampSeverity(value: 88, onset: 88, floor: 85)) < 0.001)
        #expect(abs(CNSSeverityScorer.rampSeverity(value: 85, onset: 88, floor: 85) - 1.0) < 0.001)
        #expect(abs(CNSSeverityScorer.rampSeverity(value: 86.5, onset: 88, floor: 85) - 0.5) < 0.001)
        #expect(abs(CNSSeverityScorer.rampSeverity(value: 95, onset: 88, floor: 85)) < 0.001)
        #expect(abs(CNSSeverityScorer.rampSeverity(value: 40, onset: 88, floor: 85) - 1.0) < 0.001)
    }

    @Test("SpO2 at a healthy 95 with no baseline scores zero severity")
    func healthySpO2ScoresZero() throws {
        let assessment = CNSSeverityScorer.assess(
            kind: .spo2, source: .emayOximeter, samples: spo2Samples(value: 95),
            verdict: passingVerdict, baselines: .none, thresholds: thresholds
        )
        let unwrapped = try #require(assessment)
        #expect(abs(unwrapped.severity) < 0.001)
    }

    @Test("SpO2 at the PRODIGY floor saturates severity at 1.0")
    func floorSpO2Saturates() throws {
        let assessment = CNSSeverityScorer.assess(
            kind: .spo2, source: .emayOximeter, samples: spo2Samples(value: 85),
            verdict: passingVerdict, baselines: .none, thresholds: thresholds
        )
        let unwrapped = try #require(assessment)
        #expect(abs(unwrapped.severity - 1.0) < 0.001)
    }

    @Test("Apnea baseline lowers the SpO2 onset so a normal dip scores zero")
    func apneaBaselineSuppressesNormalDips() throws {
        // Personal nadir 84 → onset 81. A dip to 86 is normal for this user.
        let baselines = CNSBaselines(
            spo2Nadir: 84, restingHeartRate: nil, hrvMean: nil, respiratoryRateMean: nil
        )
        let assessment = CNSSeverityScorer.assess(
            kind: .spo2, source: .emayOximeter, samples: spo2Samples(value: 86),
            verdict: passingVerdict, baselines: baselines, thresholds: thresholds
        )
        let unwrapped = try #require(assessment)
        #expect(abs(unwrapped.severity) < 0.001)
    }

    @Test("Respiratory rate ramps between onset 10 and floor 5")
    func respiratoryRateRamp() throws {
        let samples = (0...59).map { ago in
            CNSSignalSample(
                kind: .respiratoryRate, source: .appleWatch, value: 7.5,
                timestamp: t0.addingTimeInterval(60 - Double(ago))
            )
        }
        let assessment = CNSSeverityScorer.assess(
            kind: .respiratoryRate, source: .appleWatch, samples: samples,
            verdict: passingVerdict, baselines: .none, thresholds: thresholds
        )
        let unwrapped = try #require(assessment)
        #expect(abs(unwrapped.severity - 0.5) < 0.001)
    }

    @Test("An indeterminate verdict yields no assessment — never a score")
    func indeterminateYieldsNil() {
        let verdict = CNSWindowVerdict(quality: .indeterminate, goodCoverageFraction: 0.2)
        let assessment = CNSSeverityScorer.assess(
            kind: .spo2, source: .emayOximeter, samples: spo2Samples(value: 70),
            verdict: verdict, baselines: .none, thresholds: thresholds
        )
        #expect(assessment == nil)
    }

    @Test("Zero-fidelity (kind, source) pairs yield no assessment")
    func zeroFidelityYieldsNil() {
        // Polar H10 has no SpO2 channel; a sample claiming otherwise is a bug
        // upstream and must not be scored.
        let bogus = (0...59).map { ago in
            CNSSignalSample(
                kind: .spo2, source: .polarH10, value: 70,
                timestamp: t0.addingTimeInterval(60 - Double(ago))
            )
        }
        let assessment = CNSSeverityScorer.assess(
            kind: .spo2, source: .polarH10, samples: bogus,
            verdict: passingVerdict, baselines: .none, thresholds: thresholds
        )
        #expect(assessment == nil)
    }
```

(Every test that unwraps uses the `throws` + `try #require(...)` form — never `try!`.)

- [x] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/CNSSeverityScorerTests`
Expected: BUILD FAILURE — `cannot find 'CNSSeverityScorer' in scope`.

- [x] **Step 3: Implement the scorer (SpO₂ + RR paths; HR/HRV land in Task 5)**

Create `AnxietyWatch/Services/CNSRisk/CNSSeverityScorer.swift`:

```swift
import Foundation

/// §5.1 per-signal scoring: severity (how far toward danger, 0–1,
/// baseline-relative) and confidence (how much to trust it, 0–1). Pure —
/// no clock, no I/O. Returns nil rather than scoring anything it can't
/// score honestly (indeterminate window, impossible (kind, source) pair).
enum CNSSeverityScorer {

    /// Linear lower-is-worse ramp: 0 at `onset`, 1 at `floor`, clamped.
    static func rampSeverity(value: Double, onset: Double, floor: Double) -> Double {
        guard onset > floor else { return value <= floor ? 1 : 0 }
        return min(max((onset - value) / (onset - floor), 0), 1)
    }

    static func assess(
        kind: CNSSignalKind,
        source: CNSSignalSource,
        samples: [CNSSignalSample],
        verdict: CNSWindowVerdict,
        baselines: CNSBaselines,
        thresholds: CNSThresholds
    ) -> CNSSignalAssessment? {
        guard verdict.quality == .pass else { return nil }
        let fidelity = thresholds.sourceFidelity(kind: kind, source: source)
        guard fidelity > 0 else { return nil }
        let good = CNSQualityGate.goodSamples(samples, thresholds: thresholds)
            .filter { $0.kind == kind && $0.source == source }
        guard let representative = median(of: good.map(\.value)) else { return nil }

        guard let (severity, baselineAvailable) = severity(
            kind: kind, value: representative, baselines: baselines, thresholds: thresholds
        ) else { return nil }

        let baselineFactor = baselineAvailable ? 1.0 : thresholds.missingBaselineConfidenceFactor
        // Coverage already cleared the 30s contiguous bar; map the density
        // range [0.5, 1.0] so a barely-passing window still carries weight.
        let densityFactor = max(verdict.goodCoverageFraction, 0.5)
        let confidence = fidelity * densityFactor * baselineFactor
        return CNSSignalAssessment(
            kind: kind, source: source, severity: severity, confidence: confidence
        )
    }

    /// Returns (severity, whether a personal baseline informed it), or nil
    /// when the kind can't be scored yet.
    private static func severity(
        kind: CNSSignalKind,
        value: Double,
        baselines: CNSBaselines,
        thresholds: CNSThresholds
    ) -> (Double, Bool)? {
        switch kind {
        case .spo2:
            let onset = thresholds.spo2Onset(nadirBaseline: baselines.spo2Nadir)
            return (
                rampSeverity(value: value, onset: onset, floor: thresholds.spo2Floor),
                baselines.spo2Nadir != nil
            )
        case .respiratoryRate:
            return (
                rampSeverity(
                    value: value,
                    onset: thresholds.respiratoryRateOnset,
                    floor: thresholds.respiratoryRateFloor
                ),
                baselines.respiratoryRateMean != nil
            )
        case .heartRate, .hrv:
            return nil  // Task 5
        }
    }

    private static func median(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
```

- [x] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/CNSSeverityScorerTests`
Expected: PASS (9 tests).

- [x] **Step 5: Commit**

```bash
git add AnxietyWatch/Services/CNSRisk/CNSSeverityScorer.swift AnxietyWatchTests/CNSSeverityScorerTests.swift
git commit -m "feat(klaxon): baseline-relative severity scoring for SpO2 and respiratory rate"
```

---

### Task 5: Severity scoring — heart rate and HRV

**Files:**
- Modify: `AnxietyWatch/Services/CNSRisk/CNSSeverityScorer.swift` (fill the `.heartRate` / `.hrv` cases)
- Test: Modify `AnxietyWatchTests/CNSSeverityScorerTests.swift` (append)

**Interfaces:**
- Consumes/Produces: same as Task 4; `severity(kind:value:baselines:thresholds:)` handles all four kinds after this task.

- [x] **Step 1: Write the failing tests**

Append inside `struct CNSSeverityScorerTests`:

```swift
    private func hrSamples(value: Double, source: CNSSignalSource = .polarH10) -> [CNSSignalSample] {
        (0...59).map { ago in
            CNSSignalSample(
                kind: .heartRate, source: source, value: value,
                timestamp: t0.addingTimeInterval(60 - Double(ago))
            )
        }
    }

    @Test("HR onset is baseline-relative: restingHR 62 puts onset at 47")
    func heartRateBaselineRelativeOnset() throws {
        let baselines = CNSBaselines(
            spo2Nadir: nil, restingHeartRate: 62, hrvMean: nil, respiratoryRateMean: nil
        )
        // Onset = 62 − 15 = 47, floor = 40. Value 43.5 → severity 0.5.
        let assessment = CNSSeverityScorer.assess(
            kind: .heartRate, source: .polarH10, samples: hrSamples(value: 43.5),
            verdict: passingVerdict, baselines: baselines, thresholds: thresholds
        )
        let unwrapped = try #require(assessment)
        #expect(abs(unwrapped.severity - 0.5) < 0.001)
    }

    @Test("HR without a baseline uses the default onset at reduced confidence")
    func heartRateDefaultOnset() throws {
        // Onset 50, floor 40. Value 45 → severity 0.5. Confidence carries the
        // missing-baseline factor: 0.95 fidelity x 1.0 density x 0.8.
        let assessment = CNSSeverityScorer.assess(
            kind: .heartRate, source: .polarH10, samples: hrSamples(value: 45),
            verdict: passingVerdict, baselines: .none, thresholds: thresholds
        )
        let unwrapped = try #require(assessment)
        #expect(abs(unwrapped.severity - 0.5) < 0.001)
        #expect(abs(unwrapped.confidence - 0.95 * 1.0 * 0.8) < 0.001)
    }

    @Test("An HR onset that a low baseline pushes below the floor never divides by zero")
    func heartRateOnsetClampedAboveFloor() throws {
        // restingHR 50 → naive onset 35, below the 40 floor. Severity must be
        // a clean step (0 above floor, 1 at/below), not NaN.
        let baselines = CNSBaselines(
            spo2Nadir: nil, restingHeartRate: 50, hrvMean: nil, respiratoryRateMean: nil
        )
        let above = CNSSeverityScorer.assess(
            kind: .heartRate, source: .polarH10, samples: hrSamples(value: 42),
            verdict: passingVerdict, baselines: baselines, thresholds: thresholds
        )
        let unwrappedAbove = try #require(above)
        #expect(abs(unwrappedAbove.severity) < 0.001)
        let at = CNSSeverityScorer.assess(
            kind: .heartRate, source: .polarH10, samples: hrSamples(value: 40),
            verdict: passingVerdict, baselines: baselines, thresholds: thresholds
        )
        let unwrappedAt = try #require(at)
        #expect(abs(unwrappedAt.severity - 1.0) < 0.001)
    }

    @Test("HRV severity is a fraction-of-baseline collapse ramp")
    func hrvCollapseRamp() throws {
        let baselines = CNSBaselines(
            spo2Nadir: nil, restingHeartRate: nil, hrvMean: 40, respiratoryRateMean: nil
        )
        // 45% of baseline (18ms of 40ms): halfway between onset 0.6 and floor 0.3.
        let samples = (0...59).map { ago in
            CNSSignalSample(
                kind: .hrv, source: .polarH10, value: 18,
                timestamp: t0.addingTimeInterval(60 - Double(ago))
            )
        }
        let assessment = CNSSeverityScorer.assess(
            kind: .hrv, source: .polarH10, samples: samples,
            verdict: passingVerdict, baselines: baselines, thresholds: thresholds
        )
        let unwrapped = try #require(assessment)
        #expect(abs(unwrapped.severity - 0.5) < 0.001)
    }

    @Test("HRV without a baseline yields no assessment — a fraction of nothing is meaningless")
    func hrvWithoutBaselineYieldsNil() {
        let samples = (0...59).map { ago in
            CNSSignalSample(
                kind: .hrv, source: .polarH10, value: 18,
                timestamp: t0.addingTimeInterval(60 - Double(ago))
            )
        }
        let assessment = CNSSeverityScorer.assess(
            kind: .hrv, source: .polarH10, samples: samples,
            verdict: passingVerdict, baselines: .none, thresholds: thresholds
        )
        #expect(assessment == nil)
    }
```

- [x] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/CNSSeverityScorerTests`
Expected: FAIL — the five new tests (the `.heartRate`/`.hrv` cases return nil).

- [x] **Step 3: Fill the HR/HRV cases**

In `CNSSeverityScorer.severity(kind:value:baselines:thresholds:)`, replace `case .heartRate, .hrv: return nil` with:

```swift
        case .heartRate:
            let baselineOnset = baselines.restingHeartRate.map { $0 - thresholds.heartRateBaselineMargin }
            // Clamp so a low personal baseline can't push the onset below the
            // saturation floor (rampSeverity guards the degenerate case too).
            let onset = max(
                baselineOnset ?? thresholds.heartRateOnsetDefault,
                thresholds.heartRateFloor
            )
            return (
                rampSeverity(value: value, onset: onset, floor: thresholds.heartRateFloor),
                baselines.restingHeartRate != nil
            )
        case .hrv:
            // Severity is a collapse ramp on the fraction of the personal
            // baseline mean. Without a baseline there is nothing to compare
            // against — never score (a raw ms number is not interpretable).
            guard let baselineMean = baselines.hrvMean, baselineMean > 0 else { return nil }
            let fraction = value / baselineMean
            return (
                rampSeverity(
                    value: fraction,
                    onset: thresholds.hrvOnsetFraction,
                    floor: thresholds.hrvFloorFraction
                ),
                true
            )
```

- [x] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/CNSSeverityScorerTests`
Expected: PASS (14 tests).

- [x] **Step 5: Commit**

```bash
git add AnxietyWatch/Services/CNSRisk/CNSSeverityScorer.swift AnxietyWatchTests/CNSSeverityScorerTests.swift
git commit -m "feat(klaxon): corroborating severity scoring for heart rate and HRV"
```

---

### Task 6: Fusion engine

**Files:**
- Create: `AnxietyWatch/Services/CNSRisk/CNSFusionEngine.swift`
- Test: Create `AnxietyWatchTests/CNSFusionEngineTests.swift`

**Interfaces:**
- Consumes: `CNSSignalAssessment`, `CNSRiskAssessment`, `CNSThresholds` (Task 1).
- Produces:
  - `struct CNSFusionEngine` with `let thresholds: CNSThresholds` and `func fuse(_ assessments: [CNSSignalAssessment]) -> CNSRiskAssessment`.
  - Fusion contract (Phase 2/3 rely on this): primary signals (SpO₂, respiratory rate) drive the score; HR/HRV can only boost; a lone source is capped below the confirm threshold unless extreme and high-confidence; empty/low-confidence input → `.insufficientData`.

- [x] **Step 1: Write the failing tests**

Create `AnxietyWatchTests/CNSFusionEngineTests.swift`:

```swift
import Foundation
import Testing

@testable import AnxietyWatch

/// Covers §5.2 cross-sensor fusion: primary/corroborating weighting,
/// multi-source compounding, lone-sensor damping, insufficient-data.
struct CNSFusionEngineTests {
    private let thresholds = CNSThresholds.standard
    private var engine: CNSFusionEngine { CNSFusionEngine(thresholds: thresholds) }

    private func assessment(
        kind: CNSSignalKind, source: CNSSignalSource,
        severity: Double, confidence: Double
    ) -> CNSSignalAssessment {
        CNSSignalAssessment(kind: kind, source: source, severity: severity, confidence: confidence)
    }

    @Test("No assessments means insufficient data — never a zero score")
    func emptyIsInsufficient() {
        #expect(engine.fuse([]) == .insufficientData)
    }

    @Test("Only sub-minimum-confidence assessments means insufficient data")
    func allLowConfidenceIsInsufficient() {
        let weak = assessment(kind: .spo2, source: .appleWatch, severity: 0.4, confidence: 0.1)
        #expect(engine.fuse([weak]) == .insufficientData)
    }

    @Test("Healthy signals fuse to a near-zero assessed score, not insufficient")
    func healthyAssessedZero() throws {
        let calm = [
            assessment(kind: .spo2, source: .emayOximeter, severity: 0, confidence: 0.9),
            assessment(kind: .heartRate, source: .polarH10, severity: 0, confidence: 0.95)
        ]
        guard case .assessed(let score, _) = engine.fuse(calm) else {
            Issue.record("expected .assessed"); return
        }
        #expect(abs(score) < 0.001)
    }

    @Test("A lone source is capped below the confirm threshold")
    func loneSourceCapped() {
        // EMAY alone at severity 0.8 (high but not the >=0.9 extreme override):
        // likely off-finger artifact when nothing corroborates (spec 5.2).
        let lone = [
            assessment(kind: .spo2, source: .emayOximeter, severity: 0.8, confidence: 0.9)
        ]
        guard case .assessed(let score, _) = engine.fuse(lone) else {
            Issue.record("expected .assessed"); return
        }
        #expect(score < thresholds.confirmThreshold)
        #expect(abs(score - thresholds.loneSourceRiskCap) < 0.001)
    }

    @Test("A lone source that is extreme AND high-confidence escapes the cap")
    func loneSourceExtremeOverride() {
        let extreme = [
            assessment(kind: .spo2, source: .emayOximeter, severity: 0.95, confidence: 0.9)
        ]
        guard case .assessed(let score, _) = engine.fuse(extreme) else {
            Issue.record("expected .assessed"); return
        }
        #expect(score > thresholds.confirmThreshold)
    }

    @Test("Two independently elevated sources compound past the lone-source cap")
    func multiSourceCompounds() {
        let corroborated = [
            assessment(kind: .spo2, source: .emayOximeter, severity: 0.8, confidence: 0.9),
            assessment(kind: .respiratoryRate, source: .appleWatch, severity: 0.7, confidence: 0.6)
        ]
        guard case .assessed(let score, _) = engine.fuse(corroborated) else {
            Issue.record("expected .assessed"); return
        }
        #expect(score > thresholds.confirmThreshold)
    }

    @Test("Corroborating-only signals (HR + HRV) cannot reach the confirm tier")
    func corroboratingOnlyStaysBelowConfirm() {
        // The benzo-without-oximeter case: HR/HRV raise watchfulness only.
        let corroboratingOnly = [
            assessment(kind: .heartRate, source: .polarH10, severity: 1.0, confidence: 0.95),
            assessment(kind: .hrv, source: .polarH10, severity: 1.0, confidence: 0.9)
        ]
        guard case .assessed(let score, _) = engine.fuse(corroboratingOnly) else {
            Issue.record("expected .assessed"); return
        }
        #expect(score < thresholds.confirmThreshold)
        #expect(score > 0)
    }

    @Test("Contributions are echoed back for UI attribution")
    func contributionsEchoed() {
        let inputs = [
            assessment(kind: .spo2, source: .emayOximeter, severity: 0.5, confidence: 0.9)
        ]
        guard case .assessed(_, let contributions) = engine.fuse(inputs) else {
            Issue.record("expected .assessed"); return
        }
        #expect(contributions == inputs)
    }
}
```

- [x] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/CNSFusionEngineTests`
Expected: BUILD FAILURE — `cannot find 'CNSFusionEngine' in scope`.

- [x] **Step 3: Implement fusion**

Create `AnxietyWatch/Services/CNSRisk/CNSFusionEngine.swift`:

```swift
import Foundation

/// §5.2 cross-sensor fusion. Deliberately not over-aggressive: primary
/// signals (SpO₂, respiratory rate) drive the score, corroborating signals
/// (HR, HRV) can only boost, a lone screaming sensor is damped, and no data
/// is an explicit state — never a fabricated zero.
struct CNSFusionEngine {
    let thresholds: CNSThresholds

    func fuse(_ assessments: [CNSSignalAssessment]) -> CNSRiskAssessment {
        let usable = assessments.filter { $0.confidence >= thresholds.minimumAssessableConfidence }
        guard !usable.isEmpty else { return .insufficientData }

        let primary = usable.filter { $0.kind == .spo2 || $0.kind == .respiratoryRate }
        let corroborating = usable.filter { $0.kind == .heartRate || $0.kind == .hrv }

        // Confidence soft-scales primary severity (floor 0.5 → 1.0) rather
        // than multiplying directly, so a saturated severity from a
        // moderate-confidence continuous stream can still cross the klaxon
        // threshold. See `confidenceSoftScaleFloor` doc comment.
        let scale = thresholds.confidenceSoftScaleFloor
        let primaryScore = primary
            .map { $0.severity * (scale + (1 - scale) * $0.confidence) }
            .max() ?? 0

        let corroborationBoost = corroborating
            .map { min($0.severity * $0.confidence * thresholds.corroborationScale, thresholds.corroborationPerSignalCap) }
            .reduce(0, +)

        let elevated = usable.filter {
            $0.severity >= thresholds.elevatedSeverityFloor
                && $0.confidence >= thresholds.elevatedConfidenceFloor
        }
        let elevatedSources = Set(elevated.map(\.source))
        let multiSourceBonus = elevatedSources.count >= 2 ? thresholds.multiSourceBonus : 0

        var score = min(max(primaryScore + corroborationBoost + multiSourceBonus, 0), 1)

        // Lone-sensor damping: if every contributing (severity above the
        // contributing floor) assessment comes from ONE source, cap below the
        // confirm tier unless the strongest is extreme AND high-confidence.
        let contributing = usable.filter { $0.severity >= thresholds.contributingSeverityFloor }
        let contributingSources = Set(contributing.map(\.source))
        if contributingSources.count == 1, let strongest = contributing.max(by: { $0.severity < $1.severity }) {
            let extremeOverride = strongest.severity >= thresholds.loneSourceOverrideSeverity
                && strongest.confidence >= thresholds.loneSourceOverrideConfidence
            if !extremeOverride {
                score = min(score, thresholds.loneSourceRiskCap)
            }
        }

        return .assessed(riskScore: score, contributions: assessments)
    }
}
```

- [x] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/CNSFusionEngineTests`
Expected: PASS (8 tests). Hand-check for `loneSourceCapped`: primary = 0.8 × (0.5 + 0.5 × 0.9) = 0.76, which exceeds the 0.55 cap, so `min` must produce exactly `loneSourceRiskCap`.

- [x] **Step 5: Commit**

```bash
git add AnxietyWatch/Services/CNSRisk/CNSFusionEngine.swift AnxietyWatchTests/CNSFusionEngineTests.swift
git commit -m "feat(klaxon): cross-sensor fusion with lone-source damping"
```

---

### Task 7: Alert tier state machine

**Files:**
- Create: `AnxietyWatch/Services/CNSRisk/CNSAlertTierMachine.swift`
- Test: Create `AnxietyWatchTests/CNSAlertTierMachineTests.swift`

**Interfaces:**
- Consumes: `CNSRiskAssessment`, `CNSAlertTier`, `CNSThresholds` (Task 1).
- Produces:
  - `struct CNSAlertTierMachine` (value type; Phase 2's monitor holds one per session):
    - `init(thresholds: CNSThresholds, companionPresent: Bool)`
    - `private(set) var tier: CNSAlertTier` (starts `.clear`)
    - `private(set) var canAssess: Bool` (starts `true`)
    - `mutating func ingest(_ assessment: CNSRiskAssessment, at now: Date) -> CNSAlertTier`
  - Contract: rising requires the score to hold at/above a tier's (mode-adjusted) threshold for the sustain duration; falling requires the score to hold below `threshold − clearHysteresis` for `clearSustainSeconds`; `.insufficientData` sets `canAssess = false`, holds the tier, and resets any progress toward *clearing* (asymmetry rule) while leaving rise progress intact.

- [x] **Step 1: Write the failing tests**

Create `AnxietyWatchTests/CNSAlertTierMachineTests.swift`:

```swift
import Foundation
import Testing

@testable import AnxietyWatch

/// Covers the §5.3 hysteretic tier machine: sustained-rise, decisive-fall,
/// can't-assess hold, and the §14.4 alone-mode threshold delta.
struct CNSAlertTierMachineTests {
    private let thresholds = CNSThresholds.standard
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    private func machine(companionPresent: Bool = false) -> CNSAlertTierMachine {
        CNSAlertTierMachine(thresholds: thresholds, companionPresent: companionPresent)
    }

    /// Feed a constant score once per second for `seconds`, returning the tier
    /// after the last ingest.
    private func feed(
        _ machine: inout CNSAlertTierMachine, score: Double,
        seconds: Int, startingAt offset: TimeInterval = 0
    ) -> CNSAlertTier {
        var tier = machine.tier
        for second in 0..<seconds {
            tier = machine.ingest(
                .assessed(riskScore: score, contributions: []),
                at: t0.addingTimeInterval(offset + Double(second))
            )
        }
        return tier
    }

    @Test("A momentary spike does not change the tier")
    func momentarySpikeIgnored() {
        var m = machine()
        let tier = feed(&m, score: 0.7, seconds: 5)
        #expect(tier == .clear)
    }

    @Test("A sustained elevated score rises to the matching tier after the sustain window")
    func sustainedRise() {
        var m = machine()
        // 0.5 sits between watch (0.3 - 0.05 alone delta = 0.25) and confirm.
        let tier = feed(&m, score: 0.5, seconds: 70)
        #expect(tier == .watch)
    }

    @Test("Klaxon escalates tier-by-tier: two 60s sustains, then a 30s one")
    func klaxonEscalatesThroughConfirm() {
        var m = machine()
        // Escalation is chained, never skipped: watch at ~t=60, confirm
        // candidate starts fresh at t=61 and lands at ~t=121.
        _ = feed(&m, score: 0.95, seconds: 125)
        #expect(m.tier == .confirm)
        // Klaxon candidate began right after confirm (~t=122); its shorter
        // 30s sustain completes around t=152.
        let tier = feed(&m, score: 0.95, seconds: 35, startingAt: 125)
        #expect(tier == .klaxon)
    }

    @Test("Clearing requires sustained decisively-low scores")
    func decisiveClear() {
        var m = machine()
        _ = feed(&m, score: 0.5, seconds: 70)            // -> watch
        #expect(m.tier == .watch)
        // 0.28 is below watch(alone)=0.25 + hysteresis? No: clearing needs
        // score < threshold - hysteresis = 0.25 - 0.1 = 0.15. 0.2 must NOT clear.
        _ = feed(&m, score: 0.2, seconds: 130, startingAt: 70)
        #expect(m.tier == .watch)
        let tier = feed(&m, score: 0.1, seconds: 130, startingAt: 200)
        #expect(tier == .clear)
    }

    @Test("Insufficient data holds the tier and flags can't-assess")
    func insufficientDataHolds() {
        var m = machine()
        _ = feed(&m, score: 0.5, seconds: 70)            // -> watch
        let tier = m.ingest(.insufficientData, at: t0.addingTimeInterval(71))
        #expect(tier == .watch)
        #expect(m.canAssess == false)
        // Recovering data restores assessability.
        _ = m.ingest(.assessed(riskScore: 0.5, contributions: []), at: t0.addingTimeInterval(72))
        #expect(m.canAssess == true)
    }

    @Test("A data gap resets progress toward clearing — never clear on silence")
    func gapResetsClearProgress() {
        var m = machine()
        _ = feed(&m, score: 0.5, seconds: 70)            // -> watch
        // 100s of decisively-low scores (not yet the 120s needed)...
        _ = feed(&m, score: 0.1, seconds: 100, startingAt: 70)
        #expect(m.tier == .watch)
        // ...then a data gap. The partial clear progress must be discarded.
        _ = m.ingest(.insufficientData, at: t0.addingTimeInterval(170))
        // 30 more seconds of low scores would have finished the original 120s
        // window, but the reset means it must NOT clear yet.
        _ = feed(&m, score: 0.1, seconds: 30, startingAt: 171)
        #expect(m.tier == .watch)
        // A full uninterrupted clear window does clear.
        let tier = feed(&m, score: 0.1, seconds: 121, startingAt: 201)
        #expect(tier == .clear)
    }

    @Test("Companion-present raises effective thresholds by the alone delta")
    func companionDelta() {
        // 0.28 is above the alone watch threshold (0.25) but below the
        // companion one (0.3): rises alone, stays clear with a companion.
        var alone = machine(companionPresent: false)
        #expect(feed(&alone, score: 0.28, seconds: 70) == .watch)
        var accompanied = machine(companionPresent: true)
        #expect(feed(&accompanied, score: 0.28, seconds: 70) == .clear)
    }
}
```

- [x] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/CNSAlertTierMachineTests`
Expected: BUILD FAILURE — `cannot find 'CNSAlertTierMachine' in scope`.

- [x] **Step 3: Implement the tier machine**

Create `AnxietyWatch/Services/CNSRisk/CNSAlertTierMachine.swift`:

```swift
import Foundation

/// §5.3 hysteretic escalation state machine: `clear → watch → confirm →
/// klaxon`. Rising demands sustained elevation; falling demands sustained,
/// decisively-lower scores; missing data can never clear an alert (spec
/// §14.2 asymmetry, §11 fail-safe bias). Pure value type — callers pass
/// `now`; there is no hidden clock.
struct CNSAlertTierMachine {
    private let thresholds: CNSThresholds
    private let companionPresent: Bool

    private(set) var tier: CNSAlertTier = .clear
    private(set) var canAssess = true

    /// When the score first met the next tier's threshold (nil = no rise
    /// in progress).
    private var riseCandidateSince: Date?
    private var riseCandidateTier: CNSAlertTier?
    /// When the score first fell decisively below the current tier's
    /// threshold (nil = no clear in progress).
    private var clearCandidateSince: Date?

    init(thresholds: CNSThresholds, companionPresent: Bool) {
        self.thresholds = thresholds
        self.companionPresent = companionPresent
    }

    /// Threshold to ENTER a tier, adjusted for §14.4: alone fires earlier
    /// (lower thresholds); companion-present uses the base values.
    private func entryThreshold(for tier: CNSAlertTier) -> Double {
        let base: Double
        switch tier {
        case .clear: base = 0
        case .watch: base = thresholds.watchThreshold
        case .confirm: base = thresholds.confirmThreshold
        case .klaxon: base = thresholds.klaxonThreshold
        }
        return companionPresent ? base : base - thresholds.aloneModeThresholdDelta
    }

    private func sustainSeconds(toEnter tier: CNSAlertTier) -> TimeInterval {
        tier == .klaxon ? thresholds.klaxonRiseSustainSeconds : thresholds.riseSustainSeconds
    }

    @discardableResult
    mutating func ingest(_ assessment: CNSRiskAssessment, at now: Date) -> CNSAlertTier {
        guard case .assessed(let score, _) = assessment else {
            // No data: hold the tier, surface can't-assess, and discard any
            // progress toward clearing — silence must never read as safety.
            canAssess = false
            clearCandidateSince = nil
            return tier
        }
        canAssess = true

        advanceRise(score: score, at: now)
        advanceClear(score: score, at: now)
        return tier
    }

    private mutating func advanceRise(score: Double, at now: Date) {
        guard let next = CNSAlertTier(rawValue: tier.rawValue + 1) else {
            riseCandidateSince = nil
            riseCandidateTier = nil
            return
        }
        guard score >= entryThreshold(for: next) else {
            riseCandidateSince = nil
            riseCandidateTier = nil
            return
        }
        if riseCandidateTier != next {
            riseCandidateTier = next
            riseCandidateSince = now
            return
        }
        if let since = riseCandidateSince,
           now.timeIntervalSince(since) >= sustainSeconds(toEnter: next) {
            tier = next
            clearCandidateSince = nil
            // Chain-escalation continues from a fresh candidate window.
            riseCandidateSince = nil
            riseCandidateTier = nil
        }
    }

    private mutating func advanceClear(score: Double, at now: Date) {
        guard tier > .clear else {
            clearCandidateSince = nil
            return
        }
        let decisiveCeiling = entryThreshold(for: tier) - thresholds.clearHysteresis
        guard score < decisiveCeiling else {
            clearCandidateSince = nil
            return
        }
        if clearCandidateSince == nil {
            clearCandidateSince = now
            return
        }
        if let since = clearCandidateSince,
           now.timeIntervalSince(since) >= thresholds.clearSustainSeconds,
           let lower = CNSAlertTier(rawValue: tier.rawValue - 1) {
            tier = lower
            clearCandidateSince = nil
        }
    }
}
```

- [x] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/CNSAlertTierMachineTests`
Expected: PASS (7 tests). Walk `decisiveClear` by hand if it fails: watch entry threshold alone = 0.25; decisive ceiling = 0.15; 0.2 must hold, 0.1 must clear after 120 s.

- [x] **Step 5: Commit**

```bash
git add AnxietyWatch/Services/CNSRisk/CNSAlertTierMachine.swift AnxietyWatchTests/CNSAlertTierMachineTests.swift
git commit -m "feat(klaxon): hysteretic alert tier state machine"
```

---

### Task 8: Detection pipeline + synthetic-trace replay

**Files:**
- Create: `AnxietyWatch/Services/CNSRisk/CNSDetectionPipeline.swift`
- Create: `AnxietyWatchTests/SyntheticTraceFactory.swift`
- Test: Create `AnxietyWatchTests/CNSDetectionPipelineTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–7.
- Produces (Phase 2's `CNSRiskMonitor` calls exactly this):
  - `struct CNSDetectionPipeline`:
    - `init(thresholds: CNSThresholds, companionPresent: Bool)`
    - `mutating func process(samples: [CNSSignalSample], baselines: CNSBaselines, at now: Date) -> (assessment: CNSRiskAssessment, tier: CNSAlertTier)` — `samples` is the rolling buffer of recent samples (any age; the gate windows them); grouping by (kind, source) happens inside.
    - `var tier: CNSAlertTier { get }`, `var canAssess: Bool { get }`
  - `enum SyntheticTraceFactory` (test target): `static func constant(...)`, `static func decliningRamp(...)` — see Step 1.

- [x] **Step 1: Write the trace factory and the failing tests**

Create `AnxietyWatchTests/SyntheticTraceFactory.swift`:

```swift
import Foundation

@testable import AnxietyWatch

/// §12 synthetic-trace replay harness: builds physiologically-shaped sample
/// streams (steady, declining) so the full detection pipeline can be
/// exercised end-to-end without a real overdose. Test-target only.
enum SyntheticTraceFactory {

    /// 1 Hz constant-value stream over [start, start + duration).
    static func constant(
        kind: CNSSignalKind, source: CNSSignalSource, value: Double,
        start: Date, duration: TimeInterval, perfusionIndex: Double? = nil
    ) -> [CNSSignalSample] {
        stride(from: 0, to: duration, by: 1).map { offset in
            CNSSignalSample(
                kind: kind, source: source, value: value,
                timestamp: start.addingTimeInterval(offset),
                perfusionIndex: perfusionIndex
            )
        }
    }

    /// 1 Hz stream declining linearly from `from` to `to` over the duration —
    /// the canonical CNS-depression onset shape.
    static func decliningRamp(
        kind: CNSSignalKind, source: CNSSignalSource,
        from: Double, to: Double,
        start: Date, duration: TimeInterval, perfusionIndex: Double? = nil
    ) -> [CNSSignalSample] {
        stride(from: 0, to: duration, by: 1).map { offset in
            let progress = offset / duration
            return CNSSignalSample(
                kind: kind, source: source,
                value: from + (to - from) * progress,
                timestamp: start.addingTimeInterval(offset),
                perfusionIndex: perfusionIndex
            )
        }
    }
}
```

Create `AnxietyWatchTests/CNSDetectionPipelineTests.swift`:

```swift
import Foundation
import Testing

@testable import AnxietyWatch

/// End-to-end §12 replay: synthetic traces through gate → scorer → fusion →
/// tier machine across the sensor combinations the spec's device matrix
/// cares about. The pipeline is fed once per simulated second, mirroring how
/// Phase 2's monitor will drive it.
struct CNSDetectionPipelineTests {
    private let thresholds = CNSThresholds.standard
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    /// Drive the pipeline second-by-second over `samples`, returning the
    /// history of (time offset, tier). `baselines` defaults to none.
    private func replay(
        samples: [CNSSignalSample],
        seconds: Int,
        baselines: CNSBaselines = .none,
        companionPresent: Bool = false
    ) -> (pipeline: CNSDetectionPipeline, tierAtEnd: CNSAlertTier, firstKlaxonSecond: Int?) {
        var pipeline = CNSDetectionPipeline(
            thresholds: thresholds, companionPresent: companionPresent
        )
        var firstKlaxon: Int?
        var tier = CNSAlertTier.clear
        for second in 0...seconds {
            let now = t0.addingTimeInterval(Double(second))
            let visible = samples.filter { $0.timestamp <= now }
            (_, tier) = pipeline.process(samples: visible, baselines: baselines, at: now)
            if tier == .klaxon && firstKlaxon == nil { firstKlaxon = second }
        }
        return (pipeline, tier, firstKlaxon)
    }

    @Test("EMAY-only decline into overdose territory reaches klaxon")
    func emayOnlyOverdoseReachesKlaxon() {
        // SpO2 falls 96 -> 82 over 10 minutes, then holds at 82 for 5 more.
        // Severe + sustained + high-confidence continuous stream: the
        // lone-source extreme override applies and the klaxon must fire.
        let start = t0
        let decline = SyntheticTraceFactory.decliningRamp(
            kind: .spo2, source: .emayOximeter, from: 96, to: 82,
            start: start, duration: 600, perfusionIndex: 1.2
        )
        let hold = SyntheticTraceFactory.constant(
            kind: .spo2, source: .emayOximeter, value: 82,
            start: start.addingTimeInterval(600), duration: 300, perfusionIndex: 1.2
        )
        let result = replay(samples: decline + hold, seconds: 900)
        #expect(result.tierAtEnd == .klaxon)
        #expect(result.firstKlaxonSecond != nil)
    }

    @Test("A normal apnea night with an apnea baseline never leaves clear")
    func apneaNightStaysClear() {
        // Dips to 87 are normal for a user whose nadir baseline is 84 —
        // the central-confound scenario that must NOT alarm (spec §3).
        let baselines = CNSBaselines(
            spo2Nadir: 84, restingHeartRate: nil, hrvMean: nil, respiratoryRateMean: nil
        )
        let dips = SyntheticTraceFactory.constant(
            kind: .spo2, source: .emayOximeter, value: 87,
            start: t0, duration: 900, perfusionIndex: 1.2
        )
        let result = replay(samples: dips, seconds: 900, baselines: baselines)
        #expect(result.tierAtEnd == .clear)
    }

    @Test("EMAY decline corroborated by Polar bradycardia escalates no later than EMAY alone")
    func corroborationEscalatesFaster() throws {
        // Both signals decline over 10 minutes, then hold in danger territory
        // for 5 more so every sustain window has room to complete.
        let spo2 = SyntheticTraceFactory.decliningRamp(
            kind: .spo2, source: .emayOximeter, from: 96, to: 84,
            start: t0, duration: 600, perfusionIndex: 1.2
        ) + SyntheticTraceFactory.constant(
            kind: .spo2, source: .emayOximeter, value: 84,
            start: t0.addingTimeInterval(600), duration: 300, perfusionIndex: 1.2
        )
        let bradycardia = SyntheticTraceFactory.decliningRamp(
            kind: .heartRate, source: .polarH10, from: 62, to: 40,
            start: t0, duration: 600
        ) + SyntheticTraceFactory.constant(
            kind: .heartRate, source: .polarH10, value: 40,
            start: t0.addingTimeInterval(600), duration: 300
        )
        let baselines = CNSBaselines(
            spo2Nadir: nil, restingHeartRate: 62, hrvMean: nil, respiratoryRateMean: nil
        )
        let aloneRun = replay(samples: spo2, seconds: 900, baselines: baselines)
        let corroboratedRun = replay(
            samples: spo2 + bradycardia, seconds: 900, baselines: baselines
        )
        // A saturated lone EMAY escalates via the extreme override; both runs
        // must klaxon, and corroboration must never be SLOWER.
        let aloneKlaxon = try #require(aloneRun.firstKlaxonSecond)
        let corroboratedKlaxon = try #require(corroboratedRun.firstKlaxonSecond)
        #expect(corroboratedKlaxon <= aloneKlaxon)
    }

    @Test("Off-finger stream (no-finger gap) becomes can't-assess, holding the tier")
    func offFingerHoldsTier() {
        // 5 minutes of decline plus 5 minutes holding at 86 (an elevated but
        // sub-extreme level), then the finger comes off: no new samples ever
        // again. The pipeline must freeze the tier and report
        // canAssess == false — never silently clear.
        let trace = SyntheticTraceFactory.decliningRamp(
            kind: .spo2, source: .emayOximeter, from: 96, to: 86,
            start: t0, duration: 300, perfusionIndex: 1.2
        ) + SyntheticTraceFactory.constant(
            kind: .spo2, source: .emayOximeter, value: 86,
            start: t0.addingTimeInterval(300), duration: 300, perfusionIndex: 1.2
        )
        var pipeline = CNSDetectionPipeline(thresholds: thresholds, companionPresent: false)
        var tier = CNSAlertTier.clear
        // Live phase, then well past the point where the last sample has aged
        // out of every 60s gate window (t = 700).
        for second in 0...700 {
            let now = t0.addingTimeInterval(Double(second))
            (_, tier) = pipeline.process(
                samples: trace.filter { $0.timestamp <= now }, baselines: .none, at: now
            )
        }
        #expect(pipeline.canAssess == false)   // data is long gone by t=700
        let tierAtGap = tier
        #expect(tierAtGap > .clear)            // the decline must have raised SOME tier
        // Three more minutes of silence: the tier must not move in either direction.
        for second in 701...880 {
            let now = t0.addingTimeInterval(Double(second))
            (_, tier) = pipeline.process(samples: trace, baselines: .none, at: now)
        }
        #expect(tier == tierAtGap)
        #expect(pipeline.canAssess == false)
    }

    @Test("Watch-only spot checks cannot reach klaxon (lone low-fidelity source)")
    func watchOnlySpotChecksStayDamped() {
        // One SpO2 spot-check per minute at a dangerous 84: sparse coverage
        // never passes the 30s-contiguous gate, so the honest answer is
        // can't-assess — not an alarm and not reassurance.
        let spotChecks = (0..<15).map { minute in
            CNSSignalSample(
                kind: .spo2, source: .appleWatch, value: 84,
                timestamp: t0.addingTimeInterval(Double(minute) * 60)
            )
        }
        let result = replay(samples: spotChecks, seconds: 900)
        #expect(result.tierAtEnd == .clear)
        #expect(result.pipeline.canAssess == false)
    }
}
```

- [x] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/CNSDetectionPipelineTests`
Expected: BUILD FAILURE — `cannot find 'CNSDetectionPipeline' in scope`.

- [x] **Step 3: Implement the pipeline**

Create `AnxietyWatch/Services/CNSRisk/CNSDetectionPipeline.swift`:

```swift
import Foundation

/// Composes the full §5 detection chain — quality gate → severity scorer →
/// fusion → tier machine — behind one call. Phase 2's `CNSRiskMonitor`
/// owns one instance per monitoring session and calls `process` on every
/// update tick with its rolling sample buffer.
struct CNSDetectionPipeline {
    private let thresholds: CNSThresholds
    private let fusion: CNSFusionEngine
    private var tierMachine: CNSAlertTierMachine

    var tier: CNSAlertTier { tierMachine.tier }
    var canAssess: Bool { tierMachine.canAssess }

    init(thresholds: CNSThresholds, companionPresent: Bool) {
        self.thresholds = thresholds
        self.fusion = CNSFusionEngine(thresholds: thresholds)
        self.tierMachine = CNSAlertTierMachine(
            thresholds: thresholds, companionPresent: companionPresent
        )
    }

    mutating func process(
        samples: [CNSSignalSample], baselines: CNSBaselines, at now: Date
    ) -> (assessment: CNSRiskAssessment, tier: CNSAlertTier) {
        // Group by (kind, source): the §14.2 gate is per-source because the
        // sensors expose different quality channels.
        let groups = Dictionary(grouping: samples) { StreamKey(kind: $0.kind, source: $0.source) }
        // Deterministic ordering (project rule: never render/emit dictionary
        // order) so contributions are stable across runs.
        let assessments: [CNSSignalAssessment] = groups
            .sorted { $0.key.sortIndex < $1.key.sortIndex }
            .compactMap { key, streamSamples in
                let verdict = CNSQualityGate.evaluate(
                    samples: streamSamples, at: now, thresholds: thresholds
                )
                return CNSSeverityScorer.assess(
                    kind: key.kind, source: key.source, samples: streamSamples,
                    verdict: verdict, baselines: baselines, thresholds: thresholds
                )
            }
        let assessment = fusion.fuse(assessments)
        let tier = tierMachine.ingest(assessment, at: now)
        return (assessment, tier)
    }

    private struct StreamKey: Hashable {
        let kind: CNSSignalKind
        let source: CNSSignalSource

        /// Stable ordering for deterministic contribution lists.
        var sortIndex: Int {
            let kindIndex = CNSSignalKind.allCases.firstIndex(of: kind) ?? 0
            let sourceIndex = CNSSignalSource.allCases.firstIndex(of: source) ?? 0
            return kindIndex * CNSSignalSource.allCases.count + sourceIndex
        }
    }
}
```

Note for the scorer interaction: `CNSSeverityScorer.assess` already filters its input to `(kind, source)`-matching good samples, so passing the per-group slice is correct and the double filter is harmless.

- [x] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/CNSDetectionPipelineTests`
Expected: PASS (5 tests). These are the plan's integration tests — if one fails, the constants interact wrongly; debug with the failing trace, do NOT loosen a test to pass.

- [x] **Step 5: Commit**

```bash
git add AnxietyWatch/Services/CNSRisk/CNSDetectionPipeline.swift AnxietyWatchTests/SyntheticTraceFactory.swift AnxietyWatchTests/CNSDetectionPipelineTests.swift
git commit -m "feat(klaxon): detection pipeline with synthetic-trace replay coverage"
```

---

### Task 9: Wrap-up — full suite, lint, spec erratum, plan status

**Files:**
- Modify: `docs/superpowers/specs/2026-07-09-cns-depression-klaxon-design.md` (erratum note)
- Modify: `docs/plans/klaxon-phase-1-detection-engine.md` (status)

**Interfaces:** none — verification and bookkeeping.

- [x] **Step 1: Run the complete iOS test suite**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests`
Expected: PASS — zero failures anywhere (fixing any failing test is in scope, per CLAUDE.md).

- [x] **Step 2: Run SwiftLint on the new files**

Run: `swiftlint lint --strict AnxietyWatch/Services/CNSRisk/ AnxietyWatchTests/`
Expected: zero violations. Fix any line-length (150) issues by splitting expressions.

- [x] **Step 3: Record the spec erratum**

In `docs/superpowers/specs/2026-07-09-cns-depression-klaxon-design.md`, in the §3 working-thresholds table, change the SpO₂ row's trigger from `sustained below max(88%, personal-nadir − N)` to `sustained below min(88%, personal-nadir − N)` and append this note directly under the table:

```markdown
> **Erratum (Phase 1, 2026-07-09):** the SpO₂ trigger originally read `max(88%, nadir − N)`;
> for an apnea-lowered nadir that puts the trigger *above* the user's normal nightly dips —
> the exact nightly-false-alarm failure §3's confound paragraph forbids. Implemented (and
> corrected here) as `min` — see `CNSThresholds.spo2Onset(nadirBaseline:)` and
> `docs/plans/klaxon-phase-1-detection-engine.md` § "Spec erratum".
```

- [x] **Step 4: Update this plan's status**

Tick every completed checkbox in `docs/plans/klaxon-phase-1-detection-engine.md` and add an `## Implementation notes (post-merge)` section at the end recording any deviations made during execution (per the CLAUDE.md phase-plan-docs rule).

- [x] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-07-09-cns-depression-klaxon-design.md docs/plans/klaxon-phase-1-detection-engine.md
git commit -m "docs(klaxon): record SpO2 min/max spec erratum and phase-1 plan status"
```

- [x] **Step 6: Pre-PR review, then push and open the PR**

Per CLAUDE.md this is substantive Swift: dispatch `swift-pre-pr-reviewer` AND `medical-data-accuracy-reviewer` on the branch diff (`main...HEAD`) before pushing (no SwiftUI changes → render-pitfall detector not required). Address Will Block findings; address Should Address findings or record the deferral reason in the PR description. Then:

```bash
git push -u origin feat/klaxon-phase1-detection-engine
gh pr create --base main --title "Klaxon Phase 1: CNS-depression detection engine" --body-file <body-file>
```

PR body must cover: what the engine is (spec §5 / §14.2 / §14.4 implemented as pure logic), the min/max erratum, the fusion contract, and that Phases 2–3 follow in separate plans.

---

## Self-review record

- **Spec coverage (Phase 1 scope):** §5.1 per-signal severity×confidence → Tasks 4–5. §5.2 fusion + lone-sensor damping → Task 6. §5.3 hysteretic tiers → Task 7. §14.2 quality gates (coverage/contiguity, PI floors, artifact fraction, asymmetry) → Tasks 2–3 + tier-machine hold + pipeline can't-assess. §14.4 companion delta → Task 7. §12 synthetic replay → Task 8. §3 baseline-relative thresholds + PRODIGY floors → Tasks 1, 4, 5. Deliberately deferred to Phase 2/3 (activation §6/§14.1, device matrix §7, alerting §8/§14.5, UI §9, architecture wiring §10): out of scope here by design.
- **Placeholder scan:** none — every step carries code or an exact command.
- **Type consistency:** names cross-checked — `CNSThresholds.standard`, `CNSQualityGate.evaluate(samples:at:thresholds:)`, `CNSSeverityScorer.assess(kind:source:samples:verdict:baselines:thresholds:)`, `CNSFusionEngine.fuse(_:)`, `CNSAlertTierMachine.ingest(_:at:)`, `CNSDetectionPipeline.process(samples:baselines:at:)` are used identically in all tasks.

---

## Implementation notes (post-merge)

Executed 2026-07-09 via subagent-driven development (fresh implementer per task, adversarial
task review after each, whole-branch review + the repo's mandatory pre-PR reviewers at the end).
All 9 tasks shipped. Five substantive deviations from the plan's original code, every one
review-driven — the plan text above is preserved verbatim as the historical record; the code
is the source of truth:

1. **`spo2Ramp(nadirBaseline:)` + `spo2RampWidth = 3` (Task 4 fix, Critical).** The plan's
   fixed `spo2Floor` (85) degenerated the ramp to a step whenever an apnea-lowered onset fell
   to/below it (nadir ≤ 88 → reading at the user's own nadir scored severity 1.0 → nightly
   false klaxon). The floor now scales down with the onset (`min(85, onset − 3)`).
2. **`heartRateRamp(restingBaseline:)` + `heartRateMinimumRampWidth = 5` (Task 5 fix,
   Critical).** Same defect class on the HR path: the plan's `max(onset, floor)` clamp
   inverted the ramp for resting baselines < 55. The plan's `heartRateOnsetClampedAboveFloor`
   test codified the defect and was replaced by `lowRestingHRScalesFloorDown`.
3. **Fusion caps (Task 6 fix, Critical — plan-level bug).** The plan's corroboration boost had
   only a per-signal cap; HR/HRV-only input from ≥ 2 sources could sum past confirm (0.7) and
   to klaxon (0.85 at 3 sources). Added `corroborationAggregateCap = 0.3`,
   `corroboratingOnlyRiskCap = 0.5` (structural guard when no primary signal is meaningfully
   elevated), and restricted the lone-source extreme override to primary kinds.
   `loneSourceRiskCap` later moved 0.55 → 0.5 (0.55 sat on the alone-mode confirm boundary by
   one floating-point ulp).
4. **Gap-aware rise sustain (Task 7 fix, Important).** `riseSustainMaxGapSeconds = 5` +
   `riseCandidateLastQualifyingAt`: two qualifying readings bracketing a ~29 s blackout could
   otherwise satisfy the 30 s klaxon sustain. Escalation now requires observed evidence;
   sub-5 s scheduling jitter still tolerated.
5. **Pipeline pre-windowing (Task 8 fix, load-bearing).** `CNSDetectionPipeline` trims each
   stream to the 60 s gate window before scoring (same boundary semantics as the gate).
   `CNSSeverityScorer` medians everything it is handed; over an unbounded rolling buffer the
   median lags a declining trend by half its length and suppresses escalation entirely. The
   scorer's doc comment now states the pre-windowed-input contract.

6. **Primary-informed tier evidence (whole-branch review C1).** Fusion now echoes only the
   contributions it actually counted (post confidence-filter), and the tier machine requires
   primary-informed (SpO₂/RR) evidence both to clear a raised tier and to reset rise progress —
   healthy corroborators (a chest strap reading fine while the oximeter is off) no longer
   launder a missing primary stream into "all clear". Corroborating-only scores can still rise
   to watch.
7. **`loneSourceOverrideConfidence` 0.7 → 0.35 (C2).** Contact quality is already adjudicated
   by the gate, so the override floor now sits below the worst-case confidence of a
   gate-passing EMAY window with no baseline (0.9 × ~0.52 min-passing density × 0.8 ≈ 0.37).
   The old 0.7 demanded ≥ 59/60 good samples per window — two dropped BLE packets per minute
   silenced the klaxon. Regression test: `lossyEmayStreamStillReachesKlaxon`.
8. **Clear-side sustain gap guard (I3).** The rise-side blackout guard now mirrors on the clear
   side: a qualifying low tick arriving > 5 s after the previous one restarts the 120 s clear
   window, so tick starvation (app suspension) can't complete a clear on two bracketing lows.
   Constant renamed `riseSustainMaxGapSeconds` → `sustainMaxGapSeconds` (covers both
   directions).
9. **Baseline plausibility ranges (medical review).** `spo2NadirPlausibleRange` (50–100) and
   `restingHeartRatePlausibleRange` (30–120): an implausible personal baseline (e.g. a
   fraction-scale 0.82 stored instead of 82) is treated as absent, not trusted — corruption
   previously pushed the ramp so low a life-threatening reading scored severity 0. Severity
   and confidence share one sanitizer (`sanitizedSpO2Nadir` / `sanitizedRestingHeartRate`) so
   they can't disagree.
10. **Documented deferrals.** RR trend-vs-baseline clause and RR personalization (Phase 2 —
    RR confidence now honestly carries the missing-baseline factor since `respiratoryRateMean`
    never informs Phase-1 severity); `perfusionHardFloor` two-tier PI scheme (Phase 2 —
    escalation-eligible low-PI lows; Phase 1 hard-excludes below the SOFT floor, strictly more
    conservative for reassurance); alone-mode "fast escalation" sustain shortening (Phase 2/3 —
    worst-case first-crossing-to-klaxon is 60+60+30 s plus ≥ 30 s gate warm-up, approaching the
    spec's 3–6 min injury window; tune alongside the confirmation-tier UX with real sensor
    cadences); sparse-cadence (Watch) gate design (Phase 2 — the gate's sample-count-as-seconds
    coverage assumes ~1 Hz streams).

Also folded in during review rounds: contiguity-span and window-edge boundary tests (Task 2),
the exact-5%-artifact boundary test, same-kind/different-source contamination test, and the
lone-EMAY 0.72-confidence klaxon-boundary regression test (the feature's core scenario).
`gateMaxContiguousGapSeconds = 3` is an implementation interpretation of §14.2's "not
scattered fragments" — not a spec-traced number; revisit if real EMAY cadence proves burstier.

Deferred to Phase 2 (unchanged from the plan's phasing): activation gating/dose windows,
monitoring-session model + sensor adapters, device-state matrix, EMAY service promotion to
app-scoped environment. Phase 3: KlaxonAlarmService, watch haptics, UI surfaces, Critical
Alerts entitlement path.

### Post-merge follow-up review (Task 12)

A follow-up review of the hardening commit (the whole-branch review + pre-PR reviewer pass
recorded above) came back clean — no additional correctness issues found. Three items are
carried forward to the Phase 2 design checklist rather than fixed here, because each is a
judgment call about intended behavior, not a bug:

1. **Corroborating-only watch ratchet.** A watch tier raised by HR/HRV alone can never clear
   without primary (SpO₂/respiratory-rate) evidence returning: `CNSAlertTierMachine.advanceClear`
   requires `primaryInformed` unconditionally, so a watch tier entered on corroborating signals
   alone — with the primary stream then going silent or indeterminate — sits at watch
   indefinitely. This is fail-safe (never a false "all clear"), but it needs a deliberate decision
   before Phase 2: either document it as intentional in the tier machine's doc comment, or add a
   `tierWasPrimaryInformed` flag so a corroborating-only rise can clear on its own terms once the
   corroborating signals return to baseline.
2. **RR confidence constants are invisibly coupled.** Respiratory-rate confidence is
   `sourceFidelity` (0.6, Apple Watch) `× missing-baseline factor` (0.8) = 0.48 whenever
   `respiratoryRateMean` is absent (true for all of Phase 1, since nothing populates it yet) —
   below `elevatedConfidenceFloor` (0.5). RR can therefore never satisfy `multiSourceBonus`'s
   "elevated" test in the real pipeline until Phase 2 wires a baseline. The two constants aren't
   linked by any assertion or comment today; a future change to either one could silently
   re-enable or re-disable RR's multi-source contribution without anyone noticing. Flag for a
   coupling test or comment once Phase 2 lands the RR baseline.
3. **Baseline provenance needs a robust percentile, and must exclude alarm nights.** The
   SpO₂-nadir baseline this engine consumes (`CNSBaselines.spo2Nadir`) should come from a robust
   percentile (e.g. 5th) of the personal history, not a literal minimum — one extreme genuine
   desaturation night would otherwise permanently lower the nadir and desensitize
   `spo2Onset`/`spo2Ramp` for every subsequent night. Nights where the detection engine itself
   escalated (watch/confirm/klaxon) must also be excluded from the baseline-computation window, or
   a real overdose night would train the engine to expect it as normal. Both are Phase 2 concerns
   (`BaselineCalculator` wiring), not Phase 1 code changes, but need to land before real baselines
   feed this engine.
