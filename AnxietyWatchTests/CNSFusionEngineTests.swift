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

    @Test("Corroborating-only signals from multiple sources still cannot reach confirm")
    func corroboratingOnlyMultiSourceStaysBelowConfirm() {
        // Oximeter fell off overnight; chest strap and watch both scream.
        // Five concurrent HR/HRV streams across three sources must stay in
        // watch territory — no primary signal means no confirmation.
        let swarm = [
            assessment(kind: .heartRate, source: .polarH10, severity: 1.0, confidence: 0.95),
            assessment(kind: .hrv, source: .polarH10, severity: 1.0, confidence: 0.9),
            assessment(kind: .heartRate, source: .appleWatch, severity: 1.0, confidence: 0.7),
            assessment(kind: .hrv, source: .appleWatch, severity: 1.0, confidence: 0.6),
            assessment(kind: .heartRate, source: .emayOximeter, severity: 1.0, confidence: 0.8)
        ]
        guard case .assessed(let score, _) = engine.fuse(swarm) else {
            Issue.record("expected .assessed"); return
        }
        let aloneConfirm = thresholds.confirmThreshold - thresholds.aloneModeThresholdDelta
        #expect(score < aloneConfirm)
    }

    @Test("A healthy primary signal keeps screaming corroborators below confirm")
    func healthyPrimaryDampsCorroborators() {
        // SpO2 reads clean while HR/HRV from two sources are elevated: not
        // the CNS-depression signature (SpO2 catches both opioid and benzo
        // depression), so the composite stays sub-confirm.
        let mixed = [
            assessment(kind: .spo2, source: .emayOximeter, severity: 0.0, confidence: 0.9),
            assessment(kind: .heartRate, source: .polarH10, severity: 1.0, confidence: 0.95),
            assessment(kind: .hrv, source: .appleWatch, severity: 1.0, confidence: 0.6)
        ]
        guard case .assessed(let score, _) = engine.fuse(mixed) else {
            Issue.record("expected .assessed"); return
        }
        let aloneConfirm = thresholds.confirmThreshold - thresholds.aloneModeThresholdDelta
        #expect(score < aloneConfirm)
    }

    @Test("Primary overdose scenario: lone saturated EMAY at no-baseline confidence clears alone-mode klaxon")
    func loneSaturatedEMAYNoBaselineClearsKlaxon() {
        // THE core scenario: EMAY-only night, no personal baseline yet.
        // Confidence = fidelity 0.9 x density 1.0 x missing-baseline 0.8 =
        // 0.72 — which must clear the lone-source override-confidence floor,
        // and the soft-scaled score 1.0 x (0.5 + 0.5 x 0.72) = 0.86 must
        // clear the alone-mode klaxon threshold (0.85 - 0.05 = 0.80).
        let lone = [
            assessment(kind: .spo2, source: .emayOximeter, severity: 1.0, confidence: 0.72)
        ]
        guard case .assessed(let score, _) = engine.fuse(lone) else {
            Issue.record("expected .assessed"); return
        }
        #expect(abs(score - 0.86) < 0.001)
        #expect(score >= thresholds.klaxonThreshold - thresholds.aloneModeThresholdDelta)
    }

    @Test("AS11 bridge down with no other data yields monitoring degraded")
    func bridgeDownNoData() {
        #expect(engine.fuse([], as11State: .bridgeDown) == .monitoringDegraded(reason: "BRIDGE_DOWN"))
    }

    @Test("AS11 mask off leak suppresses physiological alarm")
    func maskOffLeakSuppresses() {
        let maskOff = [
            assessment(kind: .spo2, source: .as11Bridge, severity: 0.8, confidence: 0.9)
        ]
        #expect(engine.fuse(maskOff, as11State: .maskOffLeak) == .monitoringPaused(reason: "MASK_OFF_LEAK"))
    }

    @Test("AS11-only assessment under bridge fault remains observably degraded")
    func bridgeFaultAfterStripIsDegraded() {
        let as11Only = [
            assessment(kind: .spo2, source: .as11Bridge, severity: 1.0, confidence: 0.95)
        ]

        #expect(
            engine.fuse(as11Only, as11State: .bridgeDown)
                == .monitoringDegraded(reason: AS11StreamState.bridgeDown.rawValue)
        )
    }

    @Test("AS11 bridge fault strips AS11 heart rate while preserving other-source data")
    func bridgeFaultStripsAllAS11Channels() {
        let assessments = [
            assessment(kind: .heartRate, source: .as11Bridge, severity: 1.0, confidence: 0.95),
            assessment(kind: .heartRate, source: .polarH10, severity: 0.7, confidence: 0.95)
        ]

        guard case .assessed(let score, let contributions) = engine.fuse(
            assessments, as11State: .bridgeDown
        ) else {
            Issue.record("expected other-source assessment")
            return
        }

        #expect(score > 0)
        #expect(contributions.count == 1)
        #expect(contributions[0].source == .polarH10)
        #expect(!contributions.contains { $0.source == .as11Bridge })
    }

    @Test("AS11 stalled stream strips AS11 SpO2 from primary but allows other data")
    func streamStalledStripsAS11Primary() {
        let assessments = [
            assessment(kind: .spo2, source: .as11Bridge, severity: 1.0, confidence: 0.9), // Should be stripped
            assessment(kind: .heartRate, source: .polarH10, severity: 0.9, confidence: 0.95) // Should remain as corroborating
        ]
        guard case .assessed(let score, let contributions) = engine.fuse(
            assessments, as11State: .streamStalled
        ) else {
            Issue.record("expected .assessed"); return
        }
        // Since primary is empty (AS11 SpO2 was stripped) and we only have corroborating, it stays below confirm
        #expect(score > 0)
        #expect(score < thresholds.confirmThreshold)
        #expect(!contributions.contains { $0.source == .as11Bridge })
    }

    @Test("Contributions echo the assessments that were actually counted")
    func contributionsEchoed() {
        // Contributions = the assessments the score actually consumed (post
        // confidence filter), for UI attribution and the tier machine's
        // primary-informed check. A sub-minimum-confidence input must not
        // appear: it did not inform the score and must not masquerade as
        // primary evidence downstream.
        let usable = assessment(kind: .spo2, source: .emayOximeter, severity: 0.5, confidence: 0.9)
        let tooWeak = assessment(kind: .spo2, source: .appleWatch, severity: 0.5, confidence: 0.1)
        guard case .assessed(_, let contributions) = engine.fuse([usable, tooWeak]) else {
            Issue.record("expected .assessed"); return
        }
        #expect(contributions == [usable])
    }
}
