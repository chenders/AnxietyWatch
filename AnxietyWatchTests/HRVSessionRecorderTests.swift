// AnxietyWatchTests/HRVSessionRecorderTests.swift
import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

@MainActor
struct HRVSessionRecorderTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            SensorSession.self,
            HRVReading.self,
            AccelSpectrogram.self,
            DerivedBreathingRate.self,
        ])
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(isStoredInMemoryOnly: true)
        ])
    }

    private func intervals(count: Int, baseMs: Double = 800) -> [RRIntervalSample] {
        (0..<count).map { i in
            RRIntervalSample(timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)), rrMs: baseMs)
        }
    }

    @Test("a minute with ≥30 intervals writes one HRVReading with frequency-domain populated")
    func minuteFlushWritesReading() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let buffer = RRIntervalBuffer(window: 60)
        for s in intervals(count: 60) { await buffer.append(timestamp: s.timestamp, rrMs: s.rrMs) }

        let recorder = HRVSessionRecorder(
            modelContext: context,
            buffer: buffer,
            source: "polar_h10"
        )
        try recorder.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        try await recorder.tick(at: Date(timeIntervalSince1970: 1_700_000_060))

        let readings = try context.fetch(FetchDescriptor<HRVReading>())
        #expect(readings.count == 1)
        #expect(readings.first?.source == "polar_h10")
        #expect(readings.first?.rmssd ?? 0 >= 0)
    }

    @Test("a minute with <2 intervals writes nothing and increments skippedMinutes")
    func sparseMinuteIsSkipped() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let buffer = RRIntervalBuffer(window: 60)

        let recorder = HRVSessionRecorder(
            modelContext: context,
            buffer: buffer,
            source: "polar_h10"
        )
        try recorder.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        try await recorder.tick(at: Date(timeIntervalSince1970: 1_700_000_060))

        let readings = try context.fetch(FetchDescriptor<HRVReading>())
        #expect(readings.isEmpty)
        #expect(recorder.skippedMinutes == 1)
    }

    @Test("finalize writes a session summary with rmssdMean and rrCount")
    func finalizeWritesSummary() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let buffer = RRIntervalBuffer(window: 60)
        for s in intervals(count: 60) { await buffer.append(timestamp: s.timestamp, rrMs: s.rrMs) }

        let recorder = HRVSessionRecorder(
            modelContext: context,
            buffer: buffer,
            source: "polar_h10"
        )
        try recorder.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        try await recorder.tick(at: Date(timeIntervalSince1970: 1_700_000_060))
        try recorder.finalize(at: Date(timeIntervalSince1970: 1_700_000_120))

        let sessions = try context.fetch(FetchDescriptor<SensorSession>())
        #expect(sessions.count == 1)
        let summary = sessions.first?.summaryJSON ?? ""
        #expect(summary.contains("rmssdMean"))
        #expect(summary.contains("rrCount"))
        #expect(sessions.first?.endTime != nil)
    }

    @Test("recovery initializer reuses an existing SensorSession instead of inserting a new one")
    func recoveryInitReusesExistingSession() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let buffer = RRIntervalBuffer(window: 60)

        // Pre-insert a SensorSession as if it were left open by a previous run.
        let existing = SensorSession(
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            batteryAtStart: 80
        )
        existing.source = "polar_h10"
        context.insert(existing)
        try context.save()
        let existingID = existing.id

        let recorder = HRVSessionRecorder(
            modelContext: context,
            buffer: buffer,
            source: "polar_h10",
            existing: existing
        )

        // Should expose the existing session's ID without inserting a new row.
        #expect(recorder.sessionID == existingID)
        let allSessions = try context.fetch(FetchDescriptor<SensorSession>())
        #expect(allSessions.count == 1)
        #expect(allSessions.first?.id == existingID)
    }

    @Test("recovered recorder finalizes onto the existing session row")
    func recoveredRecorderFinalizesExisting() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let buffer = RRIntervalBuffer(window: 60)

        let existing = SensorSession(
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            batteryAtStart: 80
        )
        existing.source = "polar_h10"
        context.insert(existing)
        try context.save()
        let existingID = existing.id

        let recorder = HRVSessionRecorder(
            modelContext: context,
            buffer: buffer,
            source: "polar_h10",
            existing: existing
        )
        try recorder.finalize(at: Date(timeIntervalSince1970: 1_700_001_800))

        let sessions = try context.fetch(FetchDescriptor<SensorSession>())
        #expect(sessions.count == 1)
        let row = sessions.first!
        #expect(row.id == existingID)
        #expect(row.endTime != nil)
        #expect(row.summaryJSON?.contains("rrCount") == true)
    }

    @Test("finalize before any tick still writes a session row with zeroed summary")
    func finalizeWithNoData() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let buffer = RRIntervalBuffer(window: 60)

        let recorder = HRVSessionRecorder(
            modelContext: context,
            buffer: buffer,
            source: "polar_h10"
        )
        try recorder.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        try recorder.finalize(at: Date(timeIntervalSince1970: 1_700_000_010))

        let sessions = try context.fetch(FetchDescriptor<SensorSession>())
        #expect(sessions.count == 1)
        #expect(sessions.first?.summaryJSON?.contains("\"rrCount\":0") == true)
    }

    // MARK: - Session-mean HR (Phase 4a)

    @Test("buildSummaryJSON includes hrMean computed from hrValues")
    func buildSummaryIncludesHRMean() throws {
        let session = SensorSession(
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            batteryAtStart: 80
        )
        session.endTime = Date(timeIntervalSince1970: 1_700_003_600) // 1h session

        let json = HRVSessionRecorder.buildSummaryJSON(
            rmssdValues: [40, 45, 50],
            hrValues: [60, 70, 80],
            totalRRCount: 3_600,
            skippedMinutes: 0,
            session: session
        )
        let dict = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let hrMean = dict?["hrMean"] as? Double ?? 0
        #expect(abs(hrMean - 70) < 0.001)
    }

    @Test("buildSummaryJSON emits hrMean == 0 when hrValues is empty")
    func buildSummaryEmptyHR() throws {
        let session = SensorSession(
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            batteryAtStart: 80
        )
        session.endTime = Date(timeIntervalSince1970: 1_700_003_600)

        let json = HRVSessionRecorder.buildSummaryJSON(
            rmssdValues: [],
            hrValues: [],
            totalRRCount: 0,
            skippedMinutes: 0,
            session: session
        )
        let dict = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let hrMean = dict?["hrMean"] as? Double
        #expect(hrMean == 0)
    }

    @Test("tick appends one hrValues entry per accepted window, equal to 60_000 / mean RR ms")
    func tickPopulatesHRValues() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let buffer = RRIntervalBuffer(window: 60)
        // 60 intervals of 800ms → HR = 60_000 / 800 = 75 bpm
        for s in intervals(count: 60, baseMs: 800) {
            await buffer.append(timestamp: s.timestamp, rrMs: s.rrMs)
        }

        let recorder = HRVSessionRecorder(
            modelContext: context,
            buffer: buffer,
            source: PolarHRMService.sourceLabel
        )
        try recorder.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        try await recorder.tick(at: Date(timeIntervalSince1970: 1_700_000_060))

        #expect(recorder.hrValues.count == 1)
        #expect(abs((recorder.hrValues.first ?? 0) - 75) < 0.001)
    }

    @Test("rehydratedHRValues returns empty array for empty inputs")
    func rehydratedHREmpty() {
        let result = HRVSessionRecorder.rehydratedHRValues(priorReadings: [], samples: [])
        #expect(result.isEmpty)
    }

    @Test("rehydratedHRValues computes one HR value per HRVReading whose 60s window has enough samples")
    func rehydratedHRPerReading() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = SensorSession(
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            batteryAtStart: 80
        )
        context.insert(session)
        // Two HRVReading rows, 60s apart
        let r1 = HRVReading(
            timestamp: Date(timeIntervalSince1970: 1_700_000_060),
            rmssd: 40, sdnn: 50, pnn50: 10,
            lfPower: 1, hfPower: 2, lfHfRatio: 0.5,
            sensorSessionID: session.id, source: PolarHRMService.sourceLabel
        )
        let r2 = HRVReading(
            timestamp: Date(timeIntervalSince1970: 1_700_000_120),
            rmssd: 45, sdnn: 55, pnn50: 12,
            lfPower: 1, hfPower: 2, lfHfRatio: 0.5,
            sensorSessionID: session.id, source: PolarHRMService.sourceLabel
        )
        context.insert(r1)
        context.insert(r2)
        // First window: 60 samples of 1000ms (HR = 60). Second: 60 samples of
        // 750ms (HR = 80). Loop 2 starts at +061 so the boundary sample at
        // +060 doesn't double-count into both windows (helper uses an
        // inclusive upper bound on each reading's 60s window).
        var samples: [RRIntervalSample] = []
        for i in 0..<60 {
            samples.append(RRIntervalSample(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
                rrMs: 1_000
            ))
        }
        for i in 0..<60 {
            samples.append(RRIntervalSample(
                timestamp: Date(timeIntervalSince1970: 1_700_000_061 + Double(i)),
                rrMs: 750
            ))
        }

        let result = HRVSessionRecorder.rehydratedHRValues(
            priorReadings: [r1, r2],
            samples: samples
        )

        #expect(result.count == 2)
        #expect(abs(result[0] - 60) < 0.001)
        #expect(abs(result[1] - 80) < 0.001)
    }

    @Test("rehydratedHRValues skips readings whose window has fewer than 2 in-range samples (and excludes artifacts)")
    func rehydratedHRSkipsSparseAndFiltersArtifacts() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = SensorSession(
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            batteryAtStart: 80
        )
        context.insert(session)
        let r1 = HRVReading(
            timestamp: Date(timeIntervalSince1970: 1_700_000_060),
            rmssd: 40, sdnn: 50, pnn50: 10,
            lfPower: 1, hfPower: 2, lfHfRatio: 0.5,
            sensorSessionID: session.id, source: PolarHRMService.sourceLabel
        )
        context.insert(r1)
        // One in-range sample + two artifacts (>2000ms) — should leave 1 valid, fail the count >= 2 gate
        let samples = [
            RRIntervalSample(timestamp: Date(timeIntervalSince1970: 1_700_000_010), rrMs: 800),
            RRIntervalSample(timestamp: Date(timeIntervalSince1970: 1_700_000_020), rrMs: 2_500),
            RRIntervalSample(timestamp: Date(timeIntervalSince1970: 1_700_000_030), rrMs: 3_000),
        ]

        let result = HRVSessionRecorder.rehydratedHRValues(
            priorReadings: [r1],
            samples: samples
        )

        #expect(result.isEmpty)
    }

    @Test("tick does not append to hrValues when the minute is too sparse")
    func tickSparseNoHRValue() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let buffer = RRIntervalBuffer(window: 60)

        let recorder = HRVSessionRecorder(
            modelContext: context,
            buffer: buffer,
            source: PolarHRMService.sourceLabel
        )
        try recorder.start(at: Date(timeIntervalSince1970: 1_700_000_000))
        try await recorder.tick(at: Date(timeIntervalSince1970: 1_700_000_060))

        #expect(recorder.hrValues.isEmpty)
    }
}
