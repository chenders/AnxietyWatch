import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

/// Covers the pure per-minute downsampler that turns the ~1 Hz live EMAY BLE
/// stream into the minute-mean `QuantityHealthSample` rows the Trends live
/// card reads: minute bucketing, mean math, partial-minute flush, the
/// min-sample gate, nil-field (sentinel) exclusion, and the SpO₂
/// percent→fraction conversion.
struct EMAYLiveDownsamplerTests {

    /// Fixed, minute-aligned reference instant (780,000,000 is divisible by
    /// 60) so bucket boundaries in assertions are exact.
    private let base = Date(timeIntervalSinceReferenceDate: 780_000_000)

    private func reading(_ offset: TimeInterval, spo2: Int?, pulse: Int?) -> EMAYReading {
        EMAYReading(spo2: spo2, pulseRate: pulse, timestamp: base.addingTimeInterval(offset))
    }

    /// Feed `count` 1 Hz readings starting at `from`, discarding any
    /// completed-minute output — bulk setup for the ≥10-sample gate.
    private func addSteady(
        _ downsampler: inout EMAYLiveDownsampler,
        from start: TimeInterval,
        count: Int,
        spo2: Int?,
        pulse: Int?
    ) {
        for i in 0..<count {
            _ = downsampler.add(reading(start + TimeInterval(i), spo2: spo2, pulse: pulse))
        }
    }

    @Test("Readings within one minute buffer silently; crossing the boundary emits that minute's means")
    func minuteBucketingAndMeans() throws {
        var downsampler = EMAYLiveDownsampler()
        // 10 samples (the gate minimum): SpO₂ alternates 95/97 (mean 96),
        // pulse alternates 60/64 (mean 62).
        for i in 0..<10 {
            let completed = downsampler.add(reading(
                TimeInterval(i),
                spo2: i.isMultiple(of: 2) ? 95 : 97,
                pulse: i.isMultiple(of: 2) ? 60 : 64
            ))
            #expect(completed.isEmpty)
        }

        // First reading of the NEXT minute finalizes the previous bucket.
        let completed = downsampler.add(reading(60, spo2: 90, pulse: 70))
        #expect(completed.count == 2)

        let spo2 = try #require(completed.first { $0.metricType == EMAYImporter.spo2MetricType })
        // Mean of alternating 95/97 percent = 96 → stored as the fraction 0.96.
        #expect(abs(spo2.value - 0.96) < 0.001)
        #expect(spo2.unitString == "%")
        #expect(spo2.minuteStart == base)

        let pulse = try #require(completed.first { $0.metricType == EMAYImporter.heartRateMetricType })
        #expect(abs(pulse.value - 62.0) < 0.001)
        #expect(pulse.unitString == "count/min")
        #expect(pulse.minuteStart == base)
    }

    @Test("flush() emits a gate-clearing partial open minute once; a second flush is empty")
    func partialMinuteFlush() throws {
        var downsampler = EMAYLiveDownsampler()
        // 10 samples: SpO₂ alternates 94/96 (mean 95), pulse 58/60 (mean 59).
        for i in 0..<10 {
            _ = downsampler.add(reading(
                TimeInterval(i),
                spo2: i.isMultiple(of: 2) ? 94 : 96,
                pulse: i.isMultiple(of: 2) ? 58 : 60
            ))
        }

        let flushed = downsampler.flush()
        let spo2 = try #require(flushed.first { $0.metricType == EMAYImporter.spo2MetricType })
        #expect(abs(spo2.value - 0.95) < 0.001)
        let pulse = try #require(flushed.first { $0.metricType == EMAYImporter.heartRateMetricType })
        #expect(abs(pulse.value - 59.0) < 0.001)

        // Nothing buffered anymore — teardown paths can flush repeatedly.
        #expect(downsampler.flush().isEmpty)
    }

    @Test("Nil fields never contribute — sentinels are absence of data, not zeros")
    func nilFieldExclusion() throws {
        var downsampler = EMAYLiveDownsampler()
        // 10 pulse-only frames (no-finger SpO₂ drop), 10 SpO₂-only frames,
        // and a fully-empty frame — the nils must not contribute zeros.
        addSteady(&downsampler, from: 0, count: 10, spo2: nil, pulse: 58)
        addSteady(&downsampler, from: 10, count: 10, spo2: 97, pulse: nil)
        _ = downsampler.add(reading(20, spo2: nil, pulse: nil))

        let flushed = downsampler.flush()
        #expect(flushed.count == 2)
        let spo2 = try #require(flushed.first { $0.metricType == EMAYImporter.spo2MetricType })
        // Only the non-nil SpO₂ values contribute — a coerced 0 from any
        // nil frame would have dragged this far below 0.97.
        #expect(abs(spo2.value - 0.97) < 0.001)
        let pulse = try #require(flushed.first { $0.metricType == EMAYImporter.heartRateMetricType })
        #expect(abs(pulse.value - 58.0) < 0.001)
    }

    @Test("A minute with no SpO2 emits only the pulse sample (and vice versa)")
    func singleMetricMinute() throws {
        var downsampler = EMAYLiveDownsampler()
        addSteady(&downsampler, from: 0, count: 10, spo2: nil, pulse: 61)
        let flushed = downsampler.flush()
        #expect(flushed.count == 1)
        let only = try #require(flushed.first)
        #expect(only.metricType == EMAYImporter.heartRateMetricType)
    }

    @Test("SpO2 is persisted as a 0-1 fraction, not the device's integer percent")
    func fractionConversion() throws {
        var downsampler = EMAYLiveDownsampler()
        addSteady(&downsampler, from: 0, count: 10, spo2: 88, pulse: nil)
        let spo2 = try #require(downsampler.flush().first)
        #expect(abs(spo2.value - 0.88) < 0.001)
    }

    @Test("Fully-empty frames neither emit nor rotate the open bucket")
    func emptyFrameIsInert() throws {
        var downsampler = EMAYLiveDownsampler()
        addSteady(&downsampler, from: 0, count: 10, spo2: 95, pulse: 60)
        // An empty frame in the NEXT minute must not finalize the open
        // bucket — it carries no data and no evidence the stream moved on.
        #expect(downsampler.add(reading(65, spo2: nil, pulse: nil)).isEmpty)
        let flushed = downsampler.flush()
        let spo2 = try #require(flushed.first { $0.metricType == EMAYImporter.spo2MetricType })
        #expect(spo2.minuteStart == base)
    }

    @Test("minuteStart floors to the containing minute")
    func minuteStartFlooring() {
        #expect(EMAYLiveDownsampler.minuteStart(for: base) == base)
        #expect(EMAYLiveDownsampler.minuteStart(for: base.addingTimeInterval(59.9)) == base)
        #expect(EMAYLiveDownsampler.minuteStart(for: base.addingTimeInterval(60)) == base.addingTimeInterval(60))
    }

    @Test("A backward clock jump into an earlier minute finalizes the open bucket first")
    func backwardJumpFinalizesOpenBucket() throws {
        var downsampler = EMAYLiveDownsampler()
        addSteady(&downsampler, from: 120, count: 10, spo2: 95, pulse: nil)
        // Clock adjustment: the stream jumps two minutes earlier.
        let completed = downsampler.add(reading(30, spo2: 91, pulse: nil))
        let finalized = try #require(completed.first)
        #expect(finalized.minuteStart == base.addingTimeInterval(120))
        // The new open bucket belongs to the earlier minute; fill it past
        // the gate so the flush assertion isn't confounded by sparsity.
        addSteady(&downsampler, from: 31, count: 9, spo2: 91, pulse: nil)
        let flushed = try #require(downsampler.flush().first)
        #expect(flushed.minuteStart == base)
        #expect(abs(flushed.value - 0.91) < 0.001)
    }

    // MARK: - Min-sample gate

    @Test("A sparse minute (fewer than minimumSamplesPerMinute valid samples) is not persisted")
    func sparseMinuteNotPersisted() {
        var downsampler = EMAYLiveDownsampler()
        addSteady(
            &downsampler, from: 0,
            count: EMAYLiveDownsampler.minimumSamplesPerMinute - 1,
            spo2: 95, pulse: 60
        )
        // A probe-contact artifact of a few samples must not masquerade as
        // a full minute's mean.
        #expect(downsampler.flush().isEmpty)
    }

    @Test("Exactly minimumSamplesPerMinute valid samples clears the gate (stop() flush included)")
    func minimumSampleBoundary() throws {
        var downsampler = EMAYLiveDownsampler()
        addSteady(
            &downsampler, from: 0,
            count: EMAYLiveDownsampler.minimumSamplesPerMinute,
            spo2: 95, pulse: 60
        )
        let flushed = downsampler.flush()
        #expect(flushed.count == 2)
        let spo2 = try #require(flushed.first { $0.metricType == EMAYImporter.spo2MetricType })
        #expect(abs(spo2.value - 0.95) < 0.001)
    }

    @Test("The gate is per metric: a minute rich in pulse but sparse in SpO2 persists only pulse")
    func perMetricSampleGate() throws {
        var downsampler = EMAYLiveDownsampler()
        for i in 0..<12 {
            // Only the first two frames carry SpO₂ — probe-contact artifact.
            _ = downsampler.add(reading(TimeInterval(i), spo2: i < 2 ? 85 : nil, pulse: 62))
        }
        let flushed = downsampler.flush()
        #expect(flushed.count == 1)
        #expect(flushed.first?.metricType == EMAYImporter.heartRateMetricType)
    }

    // MARK: - Reconnect weighting

    @Test("Same-minute disconnect+reconnect accumulates one correctly-weighted mean")
    func sameMinuteReconnectWeighting() throws {
        var downsampler = EMAYLiveDownsampler()
        // 10 samples at 90%, then a transient BLE drop (NO flush — the
        // service keeps the open bucket alive on auto-reconnect paths),
        // then 20 samples at 96% after the same-minute reconnect.
        addSteady(&downsampler, from: 0, count: 10, spo2: 90, pulse: nil)
        addSteady(&downsampler, from: 30, count: 20, spo2: 96, pulse: nil)
        let flushed = try #require(downsampler.flush().first)
        // Weighted over all 30 samples: (10×90 + 20×96)/30 = 94 — NOT the
        // 93 that a mean of two flushed partial means would produce.
        #expect(abs(flushed.value - 0.94) < 0.001)
        #expect(flushed.minuteStart == base)
    }
}

/// Covers `EMAYRealtimeService.insertLiveMinutes` — the persist-time
/// first-write-wins dedup for live minute rows (the residual duplicate path
/// is a stop→restart within one wall-clock minute).
@MainActor
struct EMAYLiveMinutePersistenceTests {

    private let base = Date(timeIntervalSinceReferenceDate: 780_000_000)

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: QuantityHealthSample.self, configurations: config)
        return ModelContext(container)
    }

    private func spo2Minute(_ offset: TimeInterval, value: Double) -> EMAYLiveDownsampler.MinuteSample {
        EMAYLiveDownsampler.MinuteSample(
            minuteStart: base.addingTimeInterval(offset),
            metricType: EMAYImporter.spo2MetricType,
            value: value,
            unitString: "%"
        )
    }

    @Test("Re-persisting the same (timestamp, metricType) is skipped — first write wins")
    func firstWriteWins() throws {
        let context = try makeContext()
        #expect(EMAYRealtimeService.insertLiveMinutes([spo2Minute(0, value: 0.95)], into: context) == 1)
        try context.save()
        // stop→restart within one wall-clock minute: the second partial
        // mean for the same minute must not create a second row.
        #expect(EMAYRealtimeService.insertLiveMinutes([spo2Minute(0, value: 0.90)], into: context) == 0)
        let rows = try context.fetch(FetchDescriptor<QuantityHealthSample>())
        #expect(rows.count == 1)
        #expect(abs((rows.first?.value ?? 0) - 0.95) < 0.001)
    }

    @Test("A distinct metric or timestamp still inserts")
    func distinctKeysInsert() throws {
        let context = try makeContext()
        _ = EMAYRealtimeService.insertLiveMinutes([spo2Minute(0, value: 0.95)], into: context)
        try context.save()
        let pulseSameMinute = EMAYLiveDownsampler.MinuteSample(
            minuteStart: base,
            metricType: EMAYImporter.heartRateMetricType,
            value: 60,
            unitString: "count/min"
        )
        let inserted = EMAYRealtimeService.insertLiveMinutes(
            [pulseSameMinute, spo2Minute(60, value: 0.94)],
            into: context
        )
        #expect(inserted == 2)
    }

    @Test("Rows from other bundles (CSV import) do not block a live insert")
    func otherBundleDoesNotBlock() throws {
        let context = try makeContext()
        // Same (timestamp, metricType) but under the CSV-import bundle —
        // the dedup key includes the live bundle ID, so this must not
        // suppress the live row (the two provenances coexist by design).
        context.insert(QuantityHealthSample(
            timestamp: base,
            metricType: EMAYImporter.spo2MetricType,
            value: 0.93,
            unitString: "%",
            sourceBundleID: EMAYImporter.sourceBundleID,
            sourceName: EMAYImporter.sourceName
        ))
        try context.save()
        #expect(EMAYRealtimeService.insertLiveMinutes([spo2Minute(0, value: 0.95)], into: context) == 1)
    }
}
