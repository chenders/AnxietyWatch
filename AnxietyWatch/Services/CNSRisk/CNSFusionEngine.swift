import Foundation

/// §5.2 cross-sensor fusion. Deliberately not over-aggressive: primary
/// signals (SpO₂, respiratory rate) drive the score, corroborating signals
/// (HR, HRV) can only boost, a lone screaming sensor is damped, and no data
/// is an explicit state — never a fabricated zero.
struct CNSFusionEngine {
    let thresholds: CNSThresholds

    func fuse(_ assessments: [CNSSignalAssessment], as11State: AS11StreamState = .streamingOK) -> CNSRiskAssessment {
        let usable = assessments.filter { $0.confidence >= thresholds.minimumAssessableConfidence }

        // Handling AS11 stream states for faults and pauses
        if as11State == .bridgeDown || as11State == .streamStalled {
            // If the bridge is down but we have usable data from elsewhere, we can proceed.
            // If we have no data, it's a monitoring degraded state rather than simply insufficient data.
            if usable.isEmpty {
                return .monitoringDegraded(reason: as11State.rawValue)
            }
        }

        if as11State == .maskOffLeak {
            // Mechanical reason for missing or bad data (e.g., mask off).
            // We suppress physiological alarms if AS11 was a primary contributor
            // or if we simply have no data.
            // A conservative approach: if mask is off, the monitoring is paused.
            // We might still evaluate non-AS11 sensors if they exist, but typical CPAP
            // users rely on the mask-on state for accurate SpO2 if integrated.
            // The instructions say: "suppress physiological alarm, optionally a low-priority 'monitoring paused'".
            if usable.isEmpty || usable.allSatisfy({ $0.source == .as11Bridge }) {
                return .monitoringPaused(reason: as11State.rawValue)
            }
        }

        guard !usable.isEmpty else { return .insufficientData }

        var primary = usable.filter { $0.kind == .spo2 || $0.kind == .respiratoryRate }

        // "make SpO2 escalation require stream health + mask-on"
        if as11State != .streamingOK {
            // If AS11 is not streaming OK, we cannot trust AS11 SpO2 for escalation.
            primary = primary.filter { !($0.source == .as11Bridge && $0.kind == .spo2) }
        }

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
