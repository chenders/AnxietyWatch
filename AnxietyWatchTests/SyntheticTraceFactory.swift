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

    /// 1 Hz stream declining linearly from `from` TOWARD `to` over the
    /// duration — the canonical CNS-depression onset shape. The half-open
    /// stride means the final sample sits one step shy of `to` (at
    /// `to + (from − to)/duration`); tests that need the trace to sit AT the
    /// terminal value append a `constant(value: to, ...)` hold segment, which
    /// also gives sustain windows room to complete.
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
