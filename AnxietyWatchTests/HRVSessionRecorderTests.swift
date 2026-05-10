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
}
