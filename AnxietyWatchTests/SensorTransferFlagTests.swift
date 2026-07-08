import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

/// F-018: the Watch → phone sensor transfer gates on a persistent per-row
/// `transferredToPhone` flag (PhoneTransferable) rather than a timestamp
/// watermark, so a backward system-clock step can't make a row permanently
/// unfetchable. These exercise the flag semantics on the shared HRVReading
/// model (the watch-side fetch/mark wiring itself isn't unit-testable without
/// a WatchConnectivity host).
@MainActor
struct SensorTransferFlagTests {

    @Test("New rows default to not-transferred and match the un-sent predicate")
    func newRowsAreUntransferred() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let reading = HRVReading(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            rmssd: 40, sdnn: 50, pnn50: 10, lfPower: 1, hfPower: 1, lfHfRatio: 1
        )
        context.insert(reading)
        try context.save()

        #expect(reading.transferredToPhone == false)
        let unsent = try context.fetch(
            FetchDescriptor<HRVReading>(predicate: #Predicate { !$0.transferredToPhone })
        )
        #expect(unsent.count == 1)
    }

    @Test("A transferred row is excluded from the un-sent fetch and never re-fetched")
    func transferredRowExcluded() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let sent = HRVReading(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            rmssd: 40, sdnn: 50, pnn50: 10, lfPower: 1, hfPower: 1, lfHfRatio: 1
        )
        let pending = HRVReading(
            timestamp: Date(timeIntervalSince1970: 1_700_000_060),
            rmssd: 42, sdnn: 52, pnn50: 12, lfPower: 1, hfPower: 1, lfHfRatio: 1
        )
        context.insert(sent)
        context.insert(pending)
        // Mark via the PhoneTransferable protocol, as the completion handler does.
        (sent as any PhoneTransferable).transferredToPhone = true
        try context.save()

        let unsent = try context.fetch(
            FetchDescriptor<HRVReading>(predicate: #Predicate { !$0.transferredToPhone })
        )
        #expect(unsent.count == 1)
        #expect(unsent.first?.id == pending.id)
    }

    // A row inserted with an OLDER timestamp than an already-transferred row
    // (the backward-clock-step case) must still be eligible — the flag, not
    // the timestamp, decides. This is the exact permanent-loss path the
    // timestamp watermark had.
    @Test("An older-timestamped new row is still eligible after a newer row was transferred")
    func olderRowAfterTransferStillEligible() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let newer = HRVReading(
            timestamp: Date(timeIntervalSince1970: 1_700_001_000),
            rmssd: 40, sdnn: 50, pnn50: 10, lfPower: 1, hfPower: 1, lfHfRatio: 1
        )
        context.insert(newer)
        (newer as any PhoneTransferable).transferredToPhone = true
        try context.save()

        // Clock stepped back: a row with an EARLIER timestamp arrives.
        let older = HRVReading(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            rmssd: 44, sdnn: 54, pnn50: 14, lfPower: 1, hfPower: 1, lfHfRatio: 1
        )
        context.insert(older)
        try context.save()

        let unsent = try context.fetch(
            FetchDescriptor<HRVReading>(predicate: #Predicate { !$0.transferredToPhone })
        )
        #expect(unsent.map(\.id) == [older.id])
    }
}
