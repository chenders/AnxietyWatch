import Foundation

/// §5.2 cross-sensor fusion. Deliberately not over-aggressive: primary
/// signals (SpO₂, respiratory rate) drive the score, corroborating signals
/// (HR, HRV) can only boost, a lone screaming sensor is damped, and no data
/// is an explicit state — never a fabricated zero.
struct CNSFusionEngine {
    let thresholds: CNSThresholds

    func fuse(_ assessments: [CNSSignalAssessment], as11State: AS11StreamState = .streamingOK) -> CNSRiskAssessment {
        var usable = assessments.filter { $0.confidence >= thresholds.minimumAssessableConfidence }

        // A fault invalidates every AS11 channel, not only SpO₂. Strip first
        // so AS11-only input resolves to the observable fault state rather
        // than falling through to generic insufficient data.
        if as11State != .streamingOK {
            usable.removeAll { $0.source == .as11Bridge }
        }
        if usable.isEmpty {
            switch as11State {
            case .bridgeDown, .streamStalled:
                return .monitoringDegraded(reason: as11State.rawValue)
            case .maskOffLeak:
                return .monitoringPaused(reason: as11State.rawValue)
            case .streamingOK:
                return .insufficientData
            }
        }

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

        let corroborationBoost = min(
            corroborating
                .map { min($0.severity * $0.confidence * thresholds.corroborationScale, thresholds.corroborationPerSignalCap) }
                .reduce(0, +),
            thresholds.corroborationAggregateCap
        )

        let elevated = usable.filter {
            $0.severity >= thresholds.elevatedSeverityFloor
                && $0.confidence >= thresholds.elevatedConfidenceFloor
        }
        let elevatedSources = Set(elevated.map(\.source))
        let multiSourceBonus = elevatedSources.count >= 2 ? thresholds.multiSourceBonus : 0

        var score = min(max(primaryScore + corroborationBoost + multiSourceBonus, 0), 1)

        // Corroborating-only guard: if no primary signal is meaningfully
        // elevated (missing OR reading healthy), HR/HRV agreement across any
        // number of devices stays below the confirm tier. A healthy SpO₂
        // stream alongside screaming HR/HRV is not the CNS-depression
        // signature — it's watchfulness, not confirmation.
        let primaryMeaningfullyElevated = primary.contains {
            $0.severity >= thresholds.contributingSeverityFloor
        }
        if !primaryMeaningfullyElevated {
            score = min(score, thresholds.corroboratingOnlyRiskCap)
        }

        // Lone-sensor damping: if every contributing (severity above the
        // contributing floor) assessment comes from ONE source, cap below the
        // confirm tier unless the strongest is extreme AND high-confidence.
        let contributing = usable.filter { $0.severity >= thresholds.contributingSeverityFloor }
        let contributingSources = Set(contributing.map(\.source))
        // Only a primary signal (SpO₂/RR) can justify a lone-source
        // escalation past the cap; a lone screaming HR/HRV stream cannot.
        if contributingSources.count == 1,
           let strongest = contributing
               .filter({ $0.kind == .spo2 || $0.kind == .respiratoryRate })
               .max(by: { $0.severity < $1.severity }) {
            let extremeOverride = strongest.severity >= thresholds.loneSourceOverrideSeverity
                && strongest.confidence >= thresholds.loneSourceOverrideConfidence
            if !extremeOverride {
                score = min(score, thresholds.loneSourceRiskCap)
            }
        }

        // Echo the assessments that were actually COUNTED (post confidence
        // filter), not the raw input: downstream consumers — the tier
        // machine's primary-informed check, UI attribution — must never see
        // a contribution the score itself ignored.
        return .assessed(riskScore: score, contributions: usable)
    }
}
