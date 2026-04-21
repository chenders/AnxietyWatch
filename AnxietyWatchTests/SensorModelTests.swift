// AnxietyWatchTests/SensorModelTests.swift
import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

struct SensorModelTests {

    private let referenceDate: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 4
        components.day = 20
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }()

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

    @Test("SensorSession persists with Codable interruptions")
    func sensorSessionInterruptions() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let session = SensorSession(startTime: referenceDate, batteryAtStart: 85)
        session.interruptions = [
            SensorInterruption(reason: "userWorkout", startTime: referenceDate, endTime: nil)
        ]
        context.insert(session)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<SensorSession>())
        #expect(fetched.count == 1)
        #expect(fetched[0].interruptions.count == 1)
        #expect(fetched[0].interruptions[0].reason == "userWorkout")
        #expect(fetched[0].batteryAtStart == 85)
    }

    @Test("HRVReading persists full-spectrum values")
    func hrvReadingPersistence() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let reading = HRVReading(
            timestamp: referenceDate,
            rmssd: 42.5, sdnn: 55.0, pnn50: 18.3,
            lfPower: 0.004, hfPower: 0.008, lfHfRatio: 0.5
        )
        context.insert(reading)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<HRVReading>())
        #expect(fetched.count == 1)
        #expect(fetched[0].rmssd == 42.5)
        #expect(fetched[0].lfHfRatio == 0.5)
    }

    @Test("AccelSpectrogram persists band powers")
    func accelSpectrogramPersistence() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let spec = AccelSpectrogram(
            timestamp: referenceDate,
            tremorBandPower: 0.015,
            breathingBandPower: 0.002,
            fidgetBandPower: 0.008,
            activityLevel: 0.95
        )
        context.insert(spec)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<AccelSpectrogram>())
        #expect(fetched.count == 1)
        #expect(fetched[0].tremorBandPower == 0.015)
        #expect(fetched[0].fidgetBandPower == 0.008)
    }

    @Test("DerivedBreathingRate persists with source")
    func breathingRatePersistence() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let rate = DerivedBreathingRate(
            timestamp: referenceDate,
            breathsPerMinute: 16.5,
            confidence: 0.92,
            source: "accelerometer"
        )
        context.insert(rate)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<DerivedBreathingRate>())
        #expect(fetched.count == 1)
        #expect(fetched[0].breathsPerMinute == 16.5)
        #expect(fetched[0].source == "accelerometer")
    }
}
