import Foundation

/// Which physiological signal a sample carries. SpO₂ and respiratory rate are
/// the primary CNS-depression signals (opioid → rate, benzo → depth/SpO₂);
/// heart rate and HRV corroborate — they can raise watch alone but never
/// confirm or klaxon alone (spec §3, §5.2).
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
/// `HealthSnapshot`; nil = no baseline yet → for SpO₂ and HR the scorer falls
/// back to conservative population defaults at reduced confidence, but for
/// HRV there is no default — a raw ms value is only interpretable against a
/// personal mean, so the scorer returns nil (no assessment) instead.
/// Implausible (corrupted / mis-scaled) SpO₂-nadir and resting-HR values are
/// treated as absent — see `CNSThresholds.sanitizedSpO2Nadir(_:)`.
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
