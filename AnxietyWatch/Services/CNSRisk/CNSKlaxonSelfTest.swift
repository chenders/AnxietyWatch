#if DEBUG
import Foundation

/// In-memory self-test of the CNS-depression detection engine. Replays a
/// scripted desaturation through the REAL `CNSDetectionPipeline` (quality gate
/// → severity → fusion → tier machine) and reports, per virtual second, the
/// tier the engine itself computes plus the per-signal contributions behind it.
///
/// Pure value types only: no CoreBluetooth, no SwiftData, no notifications,
/// nothing persisted — running it never touches real health records. It drives
/// a desaturation of the same *shape* as the `tools/emay-emulator-nrf52840`
/// firmware (healthy warmup → sustained hypoxic drop), so the escalation can be
/// validated with or without hardware — the exact keyframes differ (this replay
/// recovers; the firmware holds). The replay is deterministic (fixed reference
/// clock, 1 Hz samples), so it also backs the regression test in
/// `CNSKlaxonSelfTestTests`.
enum CNSKlaxonSelfTest {

    /// One virtual second of the replay: fed vitals + the engine's full verdict.
    struct Step: Identifiable, Equatable {
        let second: Int
        let spo2: Int
        let pulse: Int
        let tier: CNSAlertTier
        let canAssess: Bool
        let riskScore: Double?
        /// The fusion state this second: `assessed`, `insufficientData`,
        /// `degraded(reason)`, or `paused(reason)`.
        let stateLabel: String
        /// Per-signal severity/confidence that fed the score (empty unless
        /// `assessed`).
        let contributions: [CNSSignalAssessment]
        var id: Int { second }
    }

    /// A tier change observed during a replay (for the debug transition log).
    struct Transition: Equatable {
        let second: Int
        let from: CNSAlertTier
        let to: CNSAlertTier
    }

    /// `{second, SpO₂%, pulse}` keyframes, linearly interpolated and NOT looped.
    /// Same shape as the firmware scenario: a healthy warmup (lets the 30 s
    /// quality gate reach `canAssess`), a desaturation ramp into sustained
    /// hypoxia (drives watch → confirm → klaxon), then recovery.
    static let keyframes: [(t: Int, spo2: Int, pulse: Int)] = [
        (0, 97, 62),
        (40, 97, 62),    // warmup
        (60, 80, 52),    // desaturation ramp (20 s)
        (240, 80, 50),   // sustained hypoxia (~180 s): watch(+60) → confirm(+60) → klaxon(+30) with margin
        (260, 97, 62),   // recovery ramp
        (340, 97, 62)    // recovery hold → clears
    ]

    /// Linearly interpolates the keyframes at `second` (clamped at the ends).
    static func scenarioValue(at second: Int) -> (spo2: Int, pulse: Int) {
        let s = max(0, second)
        for i in 0 ..< (keyframes.count - 1) {
            let a = keyframes[i], b = keyframes[i + 1]
            if s >= a.t && s < b.t {
                let span = Double(b.t - a.t)
                let d = Double(s - a.t)
                let spo2 = Double(a.spo2) + Double(b.spo2 - a.spo2) * d / span
                let pulse = Double(a.pulse) + Double(b.pulse - a.pulse) * d / span
                return (Int(spo2.rounded()), Int(pulse.rounded()))
            }
        }
        let last = keyframes[keyframes.count - 1]
        return (last.spo2, last.pulse)
    }

    /// Replays `totalSeconds` of the scenario through a fresh pipeline and
    /// returns the per-second verdicts. A fixed reference clock keeps the
    /// result fully deterministic; the rolling buffer mirrors
    /// `CNSMonitoringCoordinator.tick`'s window-trim so the scorer sees the
    /// same input it would in production.
    static func run(totalSeconds: Int = 280, companionPresent: Bool = false) -> [Step] {
        var pipeline = CNSDetectionPipeline(thresholds: .standard, companionPresent: companionPresent)
        var buffer: [CNSSignalSample] = []
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let windowSlack = CNSThresholds.standard.gateWindowSeconds + CNSMonitoringConstants.bufferTrimSlackSeconds
        var steps: [Step] = []
        steps.reserveCapacity(totalSeconds)

        for second in 0 ..< totalSeconds {
            let now = base.addingTimeInterval(Double(second))
            let (spo2, pulse) = scenarioValue(at: second)
            // EMAY emits SpO₂ + pulse per second; perfusionIndex is nil (the
            // device exposes none), matching `CNSSensorAdapters.samples(from:)`.
            buffer.append(CNSSignalSample(kind: .spo2, source: .emayOximeter,
                                          value: Double(spo2), timestamp: now))
            buffer.append(CNSSignalSample(kind: .heartRate, source: .emayOximeter,
                                          value: Double(pulse), timestamp: now))
            let trimBefore = now.addingTimeInterval(-windowSlack)
            buffer.removeAll { $0.timestamp < trimBefore }

            let (assessment, tier) = pipeline.process(samples: buffer, baselines: .none, at: now)
            let score: Double?
            let stateLabel: String
            var contributions: [CNSSignalAssessment] = []
            switch assessment {
            case .assessed(let riskScore, let contribs):
                score = riskScore
                stateLabel = "assessed"
                contributions = contribs
            case .insufficientData:
                score = nil
                stateLabel = "insufficientData"
            case .monitoringDegraded(let reason):
                score = nil
                stateLabel = "degraded (\(reason))"
            case .monitoringPaused(let reason):
                score = nil
                stateLabel = "paused (\(reason))"
            }
            steps.append(Step(second: second, spo2: spo2, pulse: pulse, tier: tier,
                              canAssess: pipeline.canAssess, riskScore: score,
                              stateLabel: stateLabel, contributions: contributions))
        }
        return steps
    }

    /// Derives the tier-change log from a replay (for the debug UI / console).
    static func transitions(in steps: [Step]) -> [Transition] {
        var result: [Transition] = []
        var previous: CNSAlertTier = .clear
        for step in steps where step.tier != previous {
            result.append(Transition(second: step.second, from: previous, to: step.tier))
            previous = step.tier
        }
        return result
    }
}
#endif
