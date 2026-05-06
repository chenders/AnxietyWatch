import Foundation
import Testing

@testable import AnxietyWatch

/// Tests for the testable view-model that backs `GlucoseDetailView`.
/// SwiftUI view bodies are intentionally not exercised — the data-prep
/// (window/day filtering, provenance footer formatting, reliability lookup,
/// day-pill list, sleep band clipping, anxiety marker filtering) is what we
/// care about for correctness.
@Suite("GlucoseDetailViewModel")
struct GlucoseDetailViewModelTests {

    /// Fixed reference moment so window/day math is deterministic.
    /// Day-aligned to noon UTC to keep time-zone rounding from biasing assertions.
    private let referenceDate: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 4, day: 15, hour: 12))!
    }()

    private func startOfReferenceDay() -> Date {
        Calendar.current.startOfDay(for: referenceDate)
    }

    /// Build a `QuantityHealthSample` with sensible glucose defaults.
    private func glucoseSample(
        offsetFromStart: TimeInterval,
        value: Double = 120,
        bundleID: String = "com.dexcom.stelo",
        sourceName: String = "Stelo"
    ) -> QuantityHealthSample {
        QuantityHealthSample(
            timestamp: startOfReferenceDay().addingTimeInterval(offsetFromStart),
            metricType: "HKQuantityTypeIdentifierBloodGlucose",
            value: value,
            unitString: "mg/dL",
            sourceBundleID: bundleID,
            sourceName: sourceName
        )
    }

    @Test("samplesForPastDay6h: window anchored to end-of-day → last 6h of selected past day")
    func samplesForPastDay6h() {
        // Build samples spanning ~48h: hourly samples from -24h to +24h around start of day.
        // Reference day (2026-04-15) is comfortably in the past, so the new
        // behavior anchors the window at end-of-day rather than at the day param.
        var samples: [QuantityHealthSample] = []
        for hour in -24...24 {
            samples.append(glucoseSample(offsetFromStart: TimeInterval(hour) * 3600))
        }

        let vm = GlucoseDetailViewModel(
            allSamples: samples,
            snapshots: [],
            sleepIntervals: [],
            anxietyEntries: []
        )

        // Past day + 6h → samples from end-of-day - 6h up to (but not including)
        // end-of-day. That's hours 18, 19, 20, 21, 22, 23 from start-of-day.
        let result = vm.samples(forDay: startOfReferenceDay(), window: 6 * 3600)
        let hours = result.map { Int($0.timestamp.timeIntervalSince(startOfReferenceDay()) / 3600) }
        #expect(hours == [18, 19, 20, 21, 22, 23])
    }

    @Test("samplesForToday6h: window anchored to now → (now - 6h, now)")
    func samplesForToday6h() {
        // Build samples every 30 minutes from -12h to -1m (no future samples,
        // no sample exactly at "now" — both make the assertions sensitive to
        // clock-drift between when the test captures `Date.now` and when the
        // VM reads `Date.now` inside `samples(forDay:window:)`).
        let now = Date.now
        var samples: [QuantityHealthSample] = []
        for halfHour in 1...24 {
            let timestamp = now.addingTimeInterval(-TimeInterval(halfHour) * 1800)
            samples.append(QuantityHealthSample(
                timestamp: timestamp,
                metricType: "HKQuantityTypeIdentifierBloodGlucose",
                value: 120, unitString: "mg/dL",
                sourceBundleID: "com.dexcom.stelo", sourceName: "Stelo"
            ))
        }

        let vm = GlucoseDetailViewModel(
            allSamples: samples,
            snapshots: [],
            sleepIntervals: [],
            anxietyEntries: []
        )

        let today = Calendar.current.startOfDay(for: now)
        let result = vm.samples(forDay: today, window: 6 * 3600)
        // Every returned sample sits inside (now - 6h, now) with a small
        // tolerance to absorb the microseconds between the test's `now` and
        // the VM's internal `Date.now`.
        let earliest = now.addingTimeInterval(-6 * 3600)
        let cushion = now.addingTimeInterval(1) // VM's now will be ≥ test's now
        for sample in result {
            #expect(sample.timestamp >= earliest)
            #expect(sample.timestamp < cushion)
        }
        // At 30-minute spacing, a 6h slice yields ~12 samples. Allow some
        // wiggle for boundary inclusion.
        #expect(result.count >= 10)
        #expect(result.count <= 13)
    }

    @Test("windowBoundsToday: today + 6h → (now - 6h, now)")
    func windowBoundsToday() {
        let vm = GlucoseDetailViewModel(
            allSamples: [],
            snapshots: [],
            sleepIntervals: [],
            anxietyEntries: []
        )
        let now = Date.now
        let today = Calendar.current.startOfDay(for: now)
        let bounds = vm.windowBounds(forDay: today, window: 6 * 3600)
        // End anchored at now (within a small tolerance for clock drift across calls).
        #expect(abs(bounds.end.timeIntervalSince(now)) < 1)
        // Start = end - window.
        #expect(abs(bounds.start.timeIntervalSince(now.addingTimeInterval(-6 * 3600))) < 1)
    }

    @Test("windowBoundsPastDay: past day + 6h → (endOfDay - 6h, endOfDay)")
    func windowBoundsPastDay() {
        let vm = GlucoseDetailViewModel(
            allSamples: [],
            snapshots: [],
            sleepIntervals: [],
            anxietyEntries: []
        )
        let dayStart = startOfReferenceDay()
        let dayEnd = dayStart.addingTimeInterval(86_400)
        let bounds = vm.windowBounds(forDay: dayStart, window: 6 * 3600)
        #expect(bounds.end == dayEnd)
        #expect(bounds.start == dayEnd.addingTimeInterval(-6 * 3600))
    }

    @Test("windowBounds24h: full day regardless of past/today")
    func windowBounds24h() {
        let vm = GlucoseDetailViewModel(
            allSamples: [],
            snapshots: [],
            sleepIntervals: [],
            anxietyEntries: []
        )
        let dayStart = startOfReferenceDay()
        let dayEnd = dayStart.addingTimeInterval(86_400)
        let bounds = vm.windowBounds(forDay: dayStart, window: 86_400)
        #expect(bounds.start == dayStart)
        #expect(bounds.end == dayEnd)
    }

    @Test("provenanceFooterSingleSource: 287 Stelo samples → '287 samples from Stelo over 24 h'")
    func provenanceFooterSingleSource() {
        var samples: [QuantityHealthSample] = []
        for i in 0..<287 {
            samples.append(glucoseSample(
                offsetFromStart: TimeInterval(i) * 300,
                bundleID: "com.dexcom.stelo",
                sourceName: "Stelo"
            ))
        }

        let vm = GlucoseDetailViewModel(
            allSamples: samples,
            snapshots: [],
            sleepIntervals: [],
            anxietyEntries: []
        )

        let footer = vm.provenanceFooter(forDay: startOfReferenceDay(), window: 86400)
        #expect(footer == "287 samples from Stelo over 24 h")
    }

    @Test("provenanceFooterMultiSource: combines two sources with bundle-display names")
    func provenanceFooterMultiSource() {
        var samples: [QuantityHealthSample] = []
        for i in 0..<287 {
            samples.append(glucoseSample(
                offsetFromStart: TimeInterval(i) * 300,
                bundleID: "com.dexcom.stelo",
                sourceName: "Stelo"
            ))
        }
        for i in 0..<5 {
            samples.append(glucoseSample(
                offsetFromStart: TimeInterval(i) * 600,
                bundleID: "com.apple.health",
                sourceName: "Apple Health"
            ))
        }

        let vm = GlucoseDetailViewModel(
            allSamples: samples,
            snapshots: [],
            sleepIntervals: [],
            anxietyEntries: []
        )

        let footer = vm.provenanceFooter(forDay: startOfReferenceDay(), window: 86400)
        // Most-frequent first; uses DeviceProvenance.displayName.
        #expect(footer == "287 from Stelo + 5 from Apple Watch over 24 h")
    }

    @Test("reliabilityLabelHigh: snapshot with glucose.reliability == high")
    func reliabilityLabelHigh() {
        let snapshot = HealthSnapshot(date: startOfReferenceDay())
        snapshot.dataQuality =
            #"{"glucose":{"reliability":"high","sources":{"com.dexcom.stelo":287}}}"#

        let vm = GlucoseDetailViewModel(
            allSamples: [],
            snapshots: [snapshot],
            sleepIntervals: [],
            anxietyEntries: []
        )

        #expect(vm.reliabilityLabel(forDay: startOfReferenceDay()) == "Reliability: high")
    }

    @Test("reliabilityLabelInsufficientWhenNoSnapshot: no snapshot for the day → insufficient")
    func reliabilityLabelInsufficientWhenNoSnapshot() {
        let vm = GlucoseDetailViewModel(
            allSamples: [],
            snapshots: [],
            sleepIntervals: [],
            anxietyEntries: []
        )

        #expect(vm.reliabilityLabel(forDay: startOfReferenceDay()) == "Reliability: insufficient")
    }

    @Test("dayPillsLastFourteenDays: returns 14 dates ending today (oldest first)")
    func dayPillsLastFourteenDays() {
        let vm = GlucoseDetailViewModel(
            allSamples: [],
            snapshots: [],
            sleepIntervals: [],
            anxietyEntries: []
        )

        let pills = vm.dayPills(asOf: referenceDate)
        #expect(pills.count == 14)

        // Oldest first; last entry is today (start of day for the reference date).
        let cal = Calendar.current
        let today = cal.startOfDay(for: referenceDate)
        #expect(pills.last == today)

        // First entry is 13 days before today.
        let firstExpected = cal.date(byAdding: .day, value: -13, to: today)!
        #expect(pills.first == firstExpected)
    }

    @Test("sleepBandsClippedToWindow: sleep interval extending outside window is clipped")
    func sleepBandsClippedToWindow() {
        // Past day + 4h window → window is (endOfDay - 4h, endOfDay) → hours 20..24.
        // Sleep interval: [hour 22, end-of-day + 1h]. Expected clipped band:
        // [hour 22, end-of-day].
        let dayStart = startOfReferenceDay()
        let dayEnd = dayStart.addingTimeInterval(86_400)
        let sleepStart = dayStart.addingTimeInterval(22 * 3600)
        let sleepEnd = dayEnd.addingTimeInterval(3600)

        let vm = GlucoseDetailViewModel(
            allSamples: [],
            snapshots: [],
            sleepIntervals: [(start: sleepStart, end: sleepEnd)],
            anxietyEntries: []
        )

        let bands = vm.sleepBands(forDay: dayStart, window: 4 * 3600)
        #expect(bands.count == 1)
        #expect(bands[0].start == sleepStart)
        #expect(bands[0].end == dayEnd)
    }

    @Test("headerSourceIsWindowNotGlobal: viewing a past day, samples.last is from that day, not today")
    func headerSourceIsWindowNotGlobal() {
        // Build a 3-day spread: a past day (D-2), yesterday (D-1), and the
        // reference day (D). The "global latest" sample is on D — but when the
        // user opens the past day, the header must derive its value/freshness
        // from the past-day window, not the global tail.
        let cal = Calendar.current
        let dayD = cal.startOfDay(for: referenceDate)
        let dayMinus2 = cal.date(byAdding: .day, value: -2, to: dayD)!

        // Past day: 3 samples ramping 100 → 110 → 120 (so status would be
        // "rising"; the value the header should show is 120).
        let pastSamples: [QuantityHealthSample] = [
            QuantityHealthSample(
                timestamp: dayMinus2.addingTimeInterval(2 * 3600),
                metricType: "HKQuantityTypeIdentifierBloodGlucose",
                value: 100, unitString: "mg/dL",
                sourceBundleID: "com.dexcom.stelo", sourceName: "Stelo"
            ),
            QuantityHealthSample(
                timestamp: dayMinus2.addingTimeInterval(3 * 3600),
                metricType: "HKQuantityTypeIdentifierBloodGlucose",
                value: 110, unitString: "mg/dL",
                sourceBundleID: "com.dexcom.stelo", sourceName: "Stelo"
            ),
            QuantityHealthSample(
                timestamp: dayMinus2.addingTimeInterval(4 * 3600),
                metricType: "HKQuantityTypeIdentifierBloodGlucose",
                value: 120, unitString: "mg/dL",
                sourceBundleID: "com.dexcom.stelo", sourceName: "Stelo"
            ),
        ]
        // Today: a single very different sample. If the header used
        // `allGlucoseSamples.last` it would pick this up.
        let todaySamples: [QuantityHealthSample] = [
            QuantityHealthSample(
                timestamp: dayD.addingTimeInterval(10 * 3600),
                metricType: "HKQuantityTypeIdentifierBloodGlucose",
                value: 250, unitString: "mg/dL",
                sourceBundleID: "com.dexcom.stelo", sourceName: "Stelo"
            ),
        ]

        let vm = GlucoseDetailViewModel(
            allSamples: pastSamples + todaySamples,
            snapshots: [],
            sleepIntervals: [],
            anxietyEntries: []
        )

        // Selecting the past day's window should yield only its 3 samples,
        // and `samples.last` (what the header now uses for value + freshness)
        // must be the 120 mg/dL sample at D-2 + 4h — NOT the 250 today.
        let windowSamples = vm.samples(forDay: dayMinus2, window: 86_400)
        #expect(windowSamples.count == 3)
        #expect(windowSamples.last?.value == 120)
        #expect(windowSamples.last?.timestamp == dayMinus2.addingTimeInterval(4 * 3600))
    }

    @Test("emptyWindowYieldsEmptySamples: viewing a past day with no samples returns []")
    func emptyWindowYieldsEmptySamples() {
        // Only "today" samples exist; the past-day window has no data so the
        // header should fall through to the "No data in selected window" arm.
        let cal = Calendar.current
        let dayD = cal.startOfDay(for: referenceDate)
        let dayMinus5 = cal.date(byAdding: .day, value: -5, to: dayD)!

        let todayOnly: [QuantityHealthSample] = [
            QuantityHealthSample(
                timestamp: dayD.addingTimeInterval(10 * 3600),
                metricType: "HKQuantityTypeIdentifierBloodGlucose",
                value: 110, unitString: "mg/dL",
                sourceBundleID: "com.dexcom.stelo", sourceName: "Stelo"
            ),
        ]

        let vm = GlucoseDetailViewModel(
            allSamples: todayOnly,
            snapshots: [],
            sleepIntervals: [],
            anxietyEntries: []
        )

        let windowSamples = vm.samples(forDay: dayMinus5, window: 86_400)
        #expect(windowSamples.isEmpty)
    }

    @Test("windowBoundsSpringForwardDST: 24h window on spring-forward day spans 23h, not 24h")
    func windowBoundsSpringForwardDST() {
        // 2024-03-10 in America/Los_Angeles is a 23-hour day: clocks jump
        // from 02:00 PST to 03:00 PDT. End-of-day is 24 wall-clock hours after
        // start-of-day, but only 23 elapsed seconds-worth of UTC time.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dstDay = cal.date(from: DateComponents(year: 2024, month: 3, day: 10, hour: 12))!
        // `now` set to a time well after the dstDay so the "today" branch isn't taken.
        let now = cal.date(from: DateComponents(year: 2024, month: 4, day: 1, hour: 12))!

        let bounds = GlucoseDetailViewModel.windowBounds(
            forDay: dstDay,
            window: 86_400,
            calendar: cal,
            now: now
        )

        let elapsed = bounds.end.timeIntervalSince(bounds.start)
        // 23 hours = 82_800 seconds. The naive `addingTimeInterval(86_400)`
        // implementation would yield 86_400 here.
        #expect(elapsed == 23 * 3600, "Spring-forward day should span 23 elapsed hours, got \(elapsed / 3600) h")
    }

    @Test("windowBoundsFallBackDST: 24h window on fall-back day spans 25h, not 24h")
    func windowBoundsFallBackDST() {
        // 2024-11-03 in America/Los_Angeles is a 25-hour day: clocks fall back
        // from 02:00 PDT to 01:00 PST.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dstDay = cal.date(from: DateComponents(year: 2024, month: 11, day: 3, hour: 12))!
        let now = cal.date(from: DateComponents(year: 2024, month: 12, day: 1, hour: 12))!

        let bounds = GlucoseDetailViewModel.windowBounds(
            forDay: dstDay,
            window: 86_400,
            calendar: cal,
            now: now
        )

        let elapsed = bounds.end.timeIntervalSince(bounds.start)
        #expect(elapsed == 25 * 3600, "Fall-back day should span 25 elapsed hours, got \(elapsed / 3600) h")
    }

    @Test("anxietyMarkersFilteredToWindow: only in-window entries are returned")
    func anxietyMarkersFilteredToWindow() {
        // Past day + 6h window → window is (endOfDay - 6h, endOfDay) → hours 18..24.
        let dayStart = startOfReferenceDay()
        let inWindow = AnxietyEntry(timestamp: dayStart.addingTimeInterval(20 * 3600), severity: 5)
        let beforeWindow = AnxietyEntry(timestamp: dayStart.addingTimeInterval(10 * 3600), severity: 5)
        let afterWindow = AnxietyEntry(timestamp: dayStart.addingTimeInterval(26 * 3600), severity: 5)

        let vm = GlucoseDetailViewModel(
            allSamples: [],
            snapshots: [],
            sleepIntervals: [],
            anxietyEntries: [inWindow, beforeWindow, afterWindow]
        )

        let markers = vm.anxietyMarkers(forDay: dayStart, window: 6 * 3600)
        #expect(markers.count == 1)
        #expect(markers.first?.id == inWindow.id)
    }
}
