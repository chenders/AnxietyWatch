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

    @Test("Pipeline threads AS11 fault state through fusion and tier hold")
    func as11FaultStateIntegration() {
        let as11Samples = SyntheticTraceFactory.constant(
            kind: .spo2, source: .as11Bridge, value: 82,
            start: t0.addingTimeInterval(-59), duration: 59
        )
        var pipeline = CNSDetectionPipeline(thresholds: thresholds, companionPresent: false)

        let (assessment, tier) = pipeline.process(
            samples: as11Samples, baselines: .none,
            as11State: .bridgeDown, at: t0
        )

        #expect(assessment == .monitoringDegraded(reason: AS11StreamState.bridgeDown.rawValue))
        #expect(tier == .clear)
        #expect(pipeline.canAssess == false)
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

    @Test("A lossy EMAY stream (~3.3% drop, gate-legal) still reaches klaxon")
    func lossyEmayStreamStillReachesKlaxon() {
        // The C2 regression test: the old 0.7 lone-source override-confidence
        // floor demanded >= 59/60 good samples per window — dropping every
        // 30th sample (two BLE packets a minute, well inside the gate's 3s
        // gap tolerance) silently capped the score below klaxon forever.
        // The same overdose trace as emayOnlyOverdoseReachesKlaxon, lossy.
        let decline = SyntheticTraceFactory.decliningRamp(
            kind: .spo2, source: .emayOximeter, from: 96, to: 82,
            start: t0, duration: 600, perfusionIndex: 1.2
        )
        let hold = SyntheticTraceFactory.constant(
            kind: .spo2, source: .emayOximeter, value: 82,
            start: t0.addingTimeInterval(600), duration: 300, perfusionIndex: 1.2
        )
        let lossy = (decline + hold).enumerated()
            .filter { $0.offset % 30 != 29 }
            .map(\.element)
        let result = replay(samples: lossy, seconds: 900)
        #expect(result.tierAtEnd == .klaxon)
        #expect(result.firstKlaxonSecond != nil)
    }

    @Test("Companion-present replay of the lossless overdose trace still reaches klaxon")
    func companionPresentOverdoseStillReachesKlaxon() {
        // Companion mode raises every threshold by the alone delta; the
        // full overdose signature (score 0.86 vs klaxon 0.85) must still
        // cross them. Later than alone-mode is fine — only the terminal
        // tier is asserted.
        let decline = SyntheticTraceFactory.decliningRamp(
            kind: .spo2, source: .emayOximeter, from: 96, to: 82,
            start: t0, duration: 600, perfusionIndex: 1.2
        )
        let hold = SyntheticTraceFactory.constant(
            kind: .spo2, source: .emayOximeter, value: 82,
            start: t0.addingTimeInterval(600), duration: 300, perfusionIndex: 1.2
        )
        let result = replay(samples: decline + hold, seconds: 900, companionPresent: true)
        #expect(result.tierAtEnd == .klaxon)
    }
}
