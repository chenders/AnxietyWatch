// AnxietyWatchTests/SensorModelMigrationTests.swift
import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

struct SensorModelMigrationTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            SensorSession.self,
            HRVReading.self,
            AccelSpectrogram.self,
            DerivedBreathingRate.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test("HRVReading accepts a source label and round-trips it")
    @MainActor
    func hrvReadingPersistsSource() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let reading = HRVReading(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            rmssd: 42, sdnn: 50, pnn50: 10,
            lfPower: 0, hfPower: 0, lfHfRatio: 0,
            sensorSessionID: nil,
            source: "polar_h10"
        )
        context.insert(reading)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<HRVReading>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.source == "polar_h10")
    }

    @Test("HRVReading source is nil when omitted (legacy rows)")
    @MainActor
    func hrvReadingSourceDefaultsToNil() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let reading = HRVReading(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            rmssd: 42, sdnn: 50, pnn50: 10,
            lfPower: 0, hfPower: 0, lfHfRatio: 0,
            sensorSessionID: nil
        )
        context.insert(reading)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<HRVReading>())
        #expect(fetched.first?.source == nil)
    }

    @Test("SensorSession persists source and summaryJSON")
    @MainActor
    func sensorSessionPersistsSourceAndSummary() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = SensorSession(
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            batteryAtStart: 80
        )
        session.source = "polar_h10"
        session.summaryJSON = #"{"rmssdMean":47.0,"rrCount":29812}"#
        context.insert(session)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SensorSession>())
        #expect(fetched.first?.source == "polar_h10")
        #expect(fetched.first?.summaryJSON?.contains("rrCount") == true)
    }
}
