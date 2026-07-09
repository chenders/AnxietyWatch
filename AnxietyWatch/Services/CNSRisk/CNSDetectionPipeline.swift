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
        // Trim to the gate window BEFORE grouping: the scorer medians every
        // sample it is handed, so feeding it the whole rolling buffer would
        // let hours-old healthy readings outvote the current decline (a
        // 96→82 ramp's all-history median lags the live value by half the
        // elapsed time — the klaxon would never fire). Filtering first also
        // avoids grouping stale samples a caller may have retained. The
        // buffer may hold any age; the window is the pipeline's contract
        // with the scorer. `CNSQualityGate.evaluate` applies the identical
        // boundary again internally — deliberate defense-in-depth. Removing
        // either filter reintroduces a documented bug: this pre-trim is
        // load-bearing for the scorer's median, the gate's for direct
        // callers. Keep the boundaries identical.
        let windowStart = now.addingTimeInterval(-thresholds.gateWindowSeconds)
        let windowed = samples.filter { $0.timestamp > windowStart && $0.timestamp <= now }
        // Group by (kind, source): the §14.2 gate is per-source because the
        // sensors expose different quality channels.
        let groups = Dictionary(grouping: windowed) { StreamKey(kind: $0.kind, source: $0.source) }
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
