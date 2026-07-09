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
        // `CNSDetectionPipeline` already pre-trims to this exact boundary
        // (strict at windowStart, inclusive at now) before calling in — the
        // duplication is deliberate defense-in-depth, and the pipeline's
        // pre-trim is load-bearing for the scorer's median. Removing either
        // filter reintroduces a documented bug; keep the boundaries identical.
        let windowStart = now.addingTimeInterval(-thresholds.gateWindowSeconds)
        let inWindow = samples
            .filter { $0.timestamp > windowStart && $0.timestamp <= now }
            .sorted { $0.timestamp < $1.timestamp }
        guard !inWindow.isEmpty else {
            return CNSWindowVerdict(quality: .indeterminate, goodCoverageFraction: 0)
        }

        // §14.2: > maxArtifactFraction artifact/ectopic samples in the window
        // → indeterminate, regardless of how much clean coverage remains.
        let artifactCount = inWindow.filter(\.isArtifact).count
        let artifactFraction = Double(artifactCount) / Double(inWindow.count)
        let good = goodSamples(inWindow, thresholds: thresholds)
        // Sample-count-as-seconds assumes ~1 Hz streams (EMAY / Polar).
        // Phase 2 adapters for sparse sources (Apple Watch spot-checks) need
        // a cadence-aware coverage/gap design decision — do not feed sparse
        // streams through this gate unchanged.
        let coverage = min(Double(good.count) / thresholds.gateWindowSeconds, 1.0)
        guard artifactFraction <= thresholds.maxArtifactFraction else {
            return CNSWindowVerdict(quality: .indeterminate, goodCoverageFraction: coverage)
        }

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
