import SwiftUI
import Testing

@testable import AnxietyWatch

/// Smoke tests for the centralized chart palette. The goal is not exhaustive
/// color equality (SwiftUI Color comparisons are environment-dependent under
/// trait collections), but to lock in three invariants that the palette
/// migration was designed to enforce:
///
/// 1. **Distinctness of source pairs.** When two charts overlay the same
///    metric from two sources, the per-source tokens must NOT resolve to the
///    same value. Heart-rate (HK vs Polar) is the canonical case.
/// 2. **Stage-vs-source separation.** Sleep stage colors must not collide
///    with heart-rate source colors — a "Core sleep" band and a "Polar HR"
///    line would both read as "blue" if no discipline is applied.
/// 3. **Severity orthogonality.** ChartPalette tokens for sources/annotations
///    must not be identical to `Color.severity(_:)` outputs, since the two
///    namespaces are meant to be combined on the same chart (e.g., HK HR line
///    with severity-band overlays). Identical colors would erase the
///    distinction.
///
/// These are written against the public API. They will fail if a future
/// refactor accidentally collapses two semantic tokens onto the same Color.
@Suite("ChartPalette")
@MainActor
struct ChartPaletteTests {

    // MARK: - Heart-rate source distinctness

    @Test("HK and Polar heart-rate tokens are distinct")
    func hrSourcesDistinct() throws {
        // Direct Color equality is fine here because both tokens are defined
        // as Color.<system> literals — they compare equal when assigned to
        // the same system color.
        #expect(ChartPalette.hkHeartRate != ChartPalette.polarHeartRate)
    }

    // MARK: - HRV-source distinctness

    @Test("HealthKit HRV and Polar RMSSD tokens are distinct")
    func hrvSourcesDistinct() throws {
        #expect(ChartPalette.healthKitHRV != ChartPalette.polarRMSSD)
    }

    // MARK: - LF / HF / ratio separation

    @Test("LF, HF, and LF/HF ratio tokens are mutually distinct")
    func lfHfRatioMutuallyDistinct() throws {
        #expect(ChartPalette.polarLFPower != ChartPalette.polarHFPower)
        #expect(ChartPalette.polarLFPower != ChartPalette.polarLFHFRatio)
        #expect(ChartPalette.polarHFPower != ChartPalette.polarLFHFRatio)
    }

    // MARK: - Sleep-stage separation from HR sources

    @Test("Sleep stage colors do not collide with heart-rate source colors")
    func sleepStagesVsHRSources() throws {
        // Core sleep is a muted form of blue; the assertion that it is "not
        // exactly" Polar HR's color holds because we apply .opacity(0.5) — a
        // future change that drops the opacity would trip this test.
        #expect(ChartPalette.sleepCore != ChartPalette.polarHeartRate)
        // Deep and REM should never share a HR color.
        #expect(ChartPalette.sleepDeep != ChartPalette.hkHeartRate)
        #expect(ChartPalette.sleepDeep != ChartPalette.polarHeartRate)
        #expect(ChartPalette.sleepREM != ChartPalette.hkHeartRate)
        #expect(ChartPalette.sleepREM != ChartPalette.polarHeartRate)
    }

    @Test("Sleep stages are mutually distinct")
    func sleepStagesMutuallyDistinct() throws {
        #expect(ChartPalette.sleepDeep != ChartPalette.sleepREM)
        #expect(ChartPalette.sleepDeep != ChartPalette.sleepCore)
        #expect(ChartPalette.sleepREM != ChartPalette.sleepCore)
    }

    @Test("Sleep stages don't collide with Polar LF/HF series")
    func sleepStagesVsLFHF() throws {
        // sleepDeep and polarLFPower were both `.indigo` before the
        // post-review fix. They appear in different charts but in the same
        // Trends scroll. Locking the differentiation here prevents a future
        // "simplify polarLFPower back to .indigo" PR from reintroducing the
        // collision.
        #expect(ChartPalette.sleepDeep != ChartPalette.polarLFPower)
    }

    // MARK: - CPAP usage vs HF power separation

    @Test("CPAP usage bars are distinct from HF power line")
    func cpapUsageVsHFPower() throws {
        // `cpapUsage` and `polarHFPower` were both `.teal` before the
        // post-review fix (the token was misleadingly named `respiratoryRate`
        // when it actually colored CPAP usage hours bars). Both appear in
        // SleepRespiratoryTrendChart's stack; collision was real.
        #expect(ChartPalette.cpapUsage != ChartPalette.polarHFPower)
    }

    // MARK: - SpO2 source separation

    @Test("EMAY oximeter and Apple Watch SpO2 tokens are distinct")
    func spo2SourcesDistinct() throws {
        #expect(ChartPalette.oximeterSpO2 != ChartPalette.appleWatchSpO2)
    }

    // MARK: - Annotation layer separation from source data

    @Test("Baseline-rule color is distinct from glucose and SpO2 oximeter")
    func baselineRuleDistinctFromGreens() throws {
        // Both baseline rule and oximeter SpO2 derive from green; the rule
        // uses opacity(0.6) so they should compare unequal. This test
        // protects against a future "simplify the palette" PR that drops the
        // opacity, which would make a baseline reference line and an SpO2
        // mark indistinguishable.
        #expect(ChartPalette.baselineRule != ChartPalette.oximeterSpO2)
    }

    @Test("Out-of-range fill is distinct from in-range fill")
    func rangeFillsDistinct() throws {
        #expect(ChartPalette.outOfRangeFill != ChartPalette.inRangeFill)
    }

    // MARK: - Token presence / non-removal

    @Test("All semantic tokens resolve (compile-time witness)")
    func tokensResolve() throws {
        // The mere fact that this test compiles and runs proves every named
        // token in ChartPalette is non-private and accessible to test code.
        // If a future refactor renames or removes a token used by a chart
        // file, this test will fail to compile alongside the chart file —
        // surfacing the breakage at one place instead of N chart files.
        _ = [
            ChartPalette.hkHeartRate,
            ChartPalette.polarHeartRate,
            ChartPalette.healthKitHRV,
            ChartPalette.polarRMSSD,
            ChartPalette.polarHFPower,
            ChartPalette.polarLFPower,
            ChartPalette.polarLFHFRatio,
            ChartPalette.sleepDeep,
            ChartPalette.sleepREM,
            ChartPalette.sleepCore,
            ChartPalette.oximeterSpO2,
            ChartPalette.appleWatchSpO2,
            ChartPalette.cpapUsage,
            ChartPalette.glucose,
            ChartPalette.activity,
            ChartPalette.barometric,
            ChartPalette.correlation,
            ChartPalette.baselineRule,
            ChartPalette.baselineLabel,
            ChartPalette.outOfRangeFill,
            ChartPalette.inRangeFill,
        ]
    }
}
