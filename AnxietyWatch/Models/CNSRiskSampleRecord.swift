import Foundation
import SwiftData

/// One ~10s risk-engine snapshot while a `MonitoringSession` is active (spec
/// §5.2/§5.3), persisted for Phase 3's ~1-hour view. Pruned beyond
/// `CNSMonitoringConstants.sampleRetention` by `MonitoringSessionStore.prune`.
/// Local-only (`HealthSample` precedent, klaxon-phase2 plan decision 8) —
/// see `MonitoringSession`'s doc comment for the full rationale.
@Model
final class CNSRiskSampleRecord {
    var id: UUID
    var timestamp: Date
    /// nil = `.insufficientData` at this instant (spec §11: the engine never
    /// fabricates a score from nothing — false reassurance is the worst
    /// outcome).
    var riskScore: Double?
    /// `CNSAlertTier.rawValue` at this instant.
    var tier: Int
    var canAssess: Bool
    /// JSON-encoded `[CNSContributionRecord]` per-signal contributions —
    /// what Phase 3's 1-hour view renders as the per-signal breakdown.
    /// Decode via `contributions`.
    var contributionsData: Data?
    var session: MonitoringSession?

    init(
        timestamp: Date,
        riskScore: Double? = nil,
        tier: Int,
        canAssess: Bool,
        contributionsData: Data? = nil,
        session: MonitoringSession? = nil
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.riskScore = riskScore
        self.tier = tier
        self.canAssess = canAssess
        self.contributionsData = contributionsData
        self.session = session
    }
}

/// `Codable` mirror of Phase 1's `CNSSignalAssessment`, for JSON-encoding
/// into `CNSRiskSampleRecord.contributionsData`. `CNSSignalAssessment`
/// itself isn't `Codable` (it's a pure-engine value type with no
/// persistence concerns); `kind`/`source` are captured as their raw case
/// names so this persisted shape never has to change when the engine enums
/// do.
struct CNSContributionRecord: Codable, Equatable, Sendable {
    let kind: String
    let source: String
    let severity: Double
    let confidence: Double

    init(kind: String, source: String, severity: Double, confidence: Double) {
        self.kind = kind
        self.source = source
        self.severity = severity
        self.confidence = confidence
    }

    init(assessment: CNSSignalAssessment) {
        self.kind = String(describing: assessment.kind)
        self.source = String(describing: assessment.source)
        self.severity = assessment.severity
        self.confidence = assessment.confidence
    }
}

extension CNSRiskSampleRecord {
    /// Decodes `contributionsData`; `[]` when nil or (in principle)
    /// corrupt — a persisted-data read must never crash or throw.
    var contributions: [CNSContributionRecord] {
        get {
            guard let data = contributionsData else { return [] }
            return (try? JSONDecoder().decode([CNSContributionRecord].self, from: data)) ?? []
        }
        set {
            contributionsData = try? JSONEncoder().encode(newValue)
        }
    }
}
