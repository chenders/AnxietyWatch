import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

/// Tests that model date normalization behaves consistently across all types.
struct ModelNormalizationTests {

    // MARK: - HealthSnapshot

    @Test("HealthSnapshot normalizes date to midnight")
    func healthSnapshotMidnight() {
        let afternoon = Calendar.current.date(
            bySettingHour: 14, minute: 30, second: 45, of: .now
        )!
        let snapshot = HealthSnapshot(date: afternoon)

        let components = Calendar.current.dateComponents(
            [.hour, .minute, .second], from: snapshot.date
        )
        #expect(components.hour == 0)
        #expect(components.minute == 0)
        #expect(components.second == 0)
    }

    @Test("HealthSnapshot preserves calendar day")
    func healthSnapshotPreservesDay() {
        let calendar = Calendar.current
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 15
        components.hour = 23
        components.minute = 59
        let lateNight = calendar.date(from: components)!

        let snapshot = HealthSnapshot(date: lateNight)
        let snapshotComponents = calendar.dateComponents([.year, .month, .day], from: snapshot.date)
        #expect(snapshotComponents.year == 2026)
        #expect(snapshotComponents.month == 3)
        #expect(snapshotComponents.day == 15)
    }

    // MARK: - CPAPSession

    @Test("CPAPSession normalizes date to midnight")
    func cpapSessionMidnight() {
        let morning = Calendar.current.date(
            bySettingHour: 9, minute: 15, second: 0, of: .now
        )!
        let session = CPAPSession(
            date: morning,
            ahi: 3.0,
            totalUsageMinutes: 420,
            leakRate95th: 10.0,
            pressureMin: 8.0,
            pressureMax: 13.0,
            pressureMean: 10.0,
            obstructiveEvents: 4,
            centralEvents: 1,
            hypopneaEvents: 6,
            importSource: "test"
        )

        let components = Calendar.current.dateComponents(
            [.hour, .minute, .second], from: session.date
        )
        #expect(components.hour == 0)
        #expect(components.minute == 0)
        #expect(components.second == 0)
    }

    @Test("CPAPSession and HealthSnapshot for same moment produce equal dates")
    func crossModelDateEquality() {
        let now = Date.now
        let snapshot = HealthSnapshot(date: now)
        let session = CPAPSession(
            date: now,
            ahi: 2.0,
            totalUsageMinutes: 360,
            leakRate95th: 8.0,
            pressureMin: 7.0,
            pressureMax: 12.0,
            pressureMean: 9.0,
            obstructiveEvents: 3,
            centralEvents: 1,
            hypopneaEvents: 4,
            importSource: "test"
        )

        #expect(snapshot.date == session.date,
                "Both should normalize to the same midnight")
    }

    // MARK: - AnxietyEntry and BarometricReading (NOT normalized — exact timestamps)

    @Test("AnxietyEntry preserves exact timestamp")
    func anxietyEntryExactTimestamp() {
        let calendar = Calendar.current
        let specificTime = calendar.date(
            bySettingHour: 14, minute: 32, second: 17, of: .now
        )!
        let entry = AnxietyEntry(timestamp: specificTime, severity: 5)

        #expect(entry.timestamp == specificTime)
    }

    @Test("BarometricReading preserves exact timestamp")
    func barometricReadingExactTimestamp() {
        let specificTime = Date.now
        let reading = BarometricReading(
            timestamp: specificTime,
            pressureKPa: 101.3,
            relativeAltitudeM: 0.5
        )

        #expect(reading.timestamp == specificTime)
    }

    // MARK: - SwiftData unique constraint

    @Test("Two HealthSnapshots for same calendar day have same date value")
    func uniqueConstraintAlignment() {
        let calendar = Calendar.current
        let morning = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: .now)!
        let evening = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: .now)!

        let snapshot1 = HealthSnapshot(date: morning)
        let snapshot2 = HealthSnapshot(date: evening)

        #expect(snapshot1.date == snapshot2.date,
                "Both normalize to midnight — unique constraint prevents duplicates")
    }
}
