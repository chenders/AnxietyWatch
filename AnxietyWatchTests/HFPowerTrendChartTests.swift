import Foundation
import Testing

@testable import AnxietyWatch

/// Tests for the pure-function helper that flattens Polar overnight HF
/// session means and anxiety entries into the HFPowerTrendChart datum
/// array. HFPower is Polar-only — HealthKit does not surface frequency-
/// domain HRV at this resolution.
@Suite("HFPowerTrendDatum builder")
@MainActor
struct HFPowerTrendChartTests {

    private let referenceDate: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 5, day: 1, hour: 12))!
    }()

    private func nightlyMean(
        daysBefore: Int,
        hfMean: Double?
    ) -> LFHFAggregator.NightlyMean {
        let night = Calendar.current.date(byAdding: .day, value: -daysBefore, to: referenceDate)!
        return LFHFAggregator.NightlyMean(
            id: UUID(),
            night: night,
            hfMean: hfMean,
            lfMean: hfMean,
            lfHfMean: hfMean.map { _ in 1.0 },
            validWindowCount: hfMean == nil ? 0 : 200
        )
    }

    private func entry(daysBefore: Int, severity: Int = 3) -> AnxietyEntry {
        let timestamp = Calendar.current.date(byAdding: .day, value: -daysBefore, to: referenceDate)!
        return AnxietyEntry(timestamp: timestamp, severity: severity)
    }

    @Test("from: emits a polar datum for each NightlyMean with a non-nil hfMean")
    func happyPath() {
        let means = [nightlyMean(daysBefore: 1, hfMean: 320), nightlyMean(daysBefore: 0, hfMean: 340)]
        let datums = HFPowerTrendDatum.from(
            windowMeans: means,
            entries: [],
            baseline: nil
        )
        let polarCount = datums.filter { if case .polar = $0 { return true } else { return false } }.count
        #expect(polarCount == 2)
    }

    @Test("from: skips means whose hfMean is nil (all-sentinel sessions)")
    func skipsNilHFMean() {
        let means = [
            nightlyMean(daysBefore: 1, hfMean: nil),
            nightlyMean(daysBefore: 0, hfMean: 340),
        ]
        let datums = HFPowerTrendDatum.from(
            windowMeans: means,
            entries: [],
            baseline: nil
        )
        let polarCount = datums.filter { if case .polar = $0 { return true } else { return false } }.count
        #expect(polarCount == 1)
    }

    @Test("from: includes baseline rule mark when baseline is non-nil")
    func includesBaseline() {
        let datums = HFPowerTrendDatum.from(
            windowMeans: [nightlyMean(daysBefore: 0, hfMean: 340)],
            entries: [],
            baseline: 280
        )
        let hasBaseline = datums.contains {
            if case .baselineMean = $0 { return true } else { return false }
        }
        #expect(hasBaseline)
    }

    @Test("from: omits baseline rule mark when baseline is nil")
    func omitsBaselineWhenNil() {
        let datums = HFPowerTrendDatum.from(
            windowMeans: [nightlyMean(daysBefore: 0, hfMean: 340)],
            entries: [],
            baseline: nil
        )
        let hasBaseline = datums.contains {
            if case .baselineMean = $0 { return true } else { return false }
        }
        #expect(!hasBaseline)
    }

    @Test("from: includes anxiety entries as context rule marks")
    func includesEntries() {
        let datums = HFPowerTrendDatum.from(
            windowMeans: [nightlyMean(daysBefore: 0, hfMean: 340)],
            entries: [entry(daysBefore: 0, severity: 4)],
            baseline: nil
        )
        let entryCount = datums.filter { if case .entry = $0 { return true } else { return false } }.count
        #expect(entryCount == 1)
    }

    @Test("hasAnyData: false when windowMeans is empty or all hfMean is nil")
    func hasAnyDataEmpty() {
        #expect(HFPowerTrendDatum.hasAnyData(windowMeans: []) == false)
        let allNil = [nightlyMean(daysBefore: 0, hfMean: nil)]
        #expect(HFPowerTrendDatum.hasAnyData(windowMeans: allNil) == false)
    }

    @Test("hasAnyData: true when at least one mean has hfMean")
    func hasAnyDataPositive() {
        #expect(HFPowerTrendDatum.hasAnyData(
            windowMeans: [nightlyMean(daysBefore: 0, hfMean: 340)]
        ) == true)
    }
}
