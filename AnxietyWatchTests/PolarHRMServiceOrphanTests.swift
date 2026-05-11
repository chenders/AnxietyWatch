// AnxietyWatchTests/PolarHRMServiceOrphanTests.swift
import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

/// Covers the SwiftData lifecycle helpers on `PolarHRMService` that don't
/// require CoreBluetooth to exercise: orphan finalization (endTime,
/// closed interruptions, back-filled summaryJSON) and multi-open cleanup
/// via `recoverInFlightSessionIfNeeded`.
@MainActor
struct PolarHRMServiceOrphanTests {

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

    @Test("finalizeOrphan sets endTime and writes a populated summaryJSON from persisted HRVReadings")
    func finalizeOrphanWritesSummary() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let service = PolarHRMService(modelContext: context)

        // Pre-insert a SensorSession with a few HRVReading children, as if
        // it were left open by a force-quit.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = SensorSession(startTime: start, batteryAtStart: 80)
        session.source = PolarHRMService.sourceLabel
        context.insert(session)
        for (i, rmssd) in [42.0, 47.0, 51.0].enumerated() {
            let reading = HRVReading(
                timestamp: start.addingTimeInterval(Double(i + 1) * 60),
                rmssd: rmssd, sdnn: 50, pnn50: 10,
                lfPower: 0, hfPower: 0, lfHfRatio: 0,
                sensorSessionID: session.id,
                source: PolarHRMService.sourceLabel
            )
            context.insert(reading)
        }
        try context.save()

        let endAt = start.addingTimeInterval(600)
        service.finalizeOrphan(session, at: endAt)

        let fetched = try context.fetch(FetchDescriptor<SensorSession>())
        #expect(fetched.count == 1)
        let row = fetched[0]
        #expect(row.endTime == endAt)
        let summary = row.summaryJSON ?? ""
        #expect(summary.contains("rmssdMean"))
        // Mean of [42, 47, 51] = 46.666... — verify the back-fill saw the
        // real per-minute readings, not the recorder's empty in-memory state.
        #expect(summary.contains("46.666") || summary.contains("46.67"))
        #expect(summary.contains("durationSec"))
    }

    @Test("finalizeOrphan closes any open SensorInterruption rows on the session")
    func finalizeOrphanClosesOpenInterruptions() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let service = PolarHRMService(modelContext: context)

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = SensorSession(startTime: start, batteryAtStart: 80)
        session.source = PolarHRMService.sourceLabel
        session.interruptions = [
            SensorInterruption(reason: "ble_disconnect",
                               startTime: start.addingTimeInterval(60),
                               endTime: nil)
        ]
        context.insert(session)
        try context.save()

        let endAt = start.addingTimeInterval(600)
        service.finalizeOrphan(session, at: endAt)

        let row = try context.fetch(FetchDescriptor<SensorSession>()).first
        #expect(row?.interruptions.first?.endTime == endAt)
    }

    @Test("recoverInFlightSessionIfNeeded finalizes every older open session before returning")
    func recoverFinalizesOlderOpens() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let service = PolarHRMService(modelContext: context)

        // Two open Polar sessions; the older one should get cleaned up
        // regardless of what happens to the newest. No peripheral set on
        // the service → both will end up finalized (the newer one via the
        // no-peripheral branch, the older one via the dropFirst() loop).
        let oldStart = Date(timeIntervalSince1970: 1_700_000_000)
        let newStart = oldStart.addingTimeInterval(3_600)
        for start in [oldStart, newStart] {
            let s = SensorSession(startTime: start, batteryAtStart: 80)
            s.source = PolarHRMService.sourceLabel
            context.insert(s)
        }
        try context.save()

        let recovered = service.recoverInFlightSessionIfNeeded()
        #expect(recovered == false)

        let rows = try context.fetch(FetchDescriptor<SensorSession>())
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.endTime != nil })
    }
}
