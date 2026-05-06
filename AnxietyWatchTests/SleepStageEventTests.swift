import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

@Suite("SleepStageEvent initialization")
struct SleepStageEventInitTests {
    @Test("Initializes with start/end/stage and sensible defaults")
    func initDefaults() {
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        let end = start.addingTimeInterval(1800)
        let event = SleepStageEvent(
            startTime: start,
            endTime: end,
            stage: "asleepDeep",
            sourceBundleID: "com.apple.health",
            sourceName: "Apple Watch"
        )
        #expect(event.startTime == start)
        #expect(event.endTime == end)
        #expect(event.stage == "asleepDeep")
        #expect(event.sourceBundleID == "com.apple.health")
        #expect(event.sourceName == "Apple Watch")
        #expect(event.deviceModel == nil)
        #expect(event.syncedToServer == false)
        #expect(abs(event.createdAt.timeIntervalSinceNow) < 5)
    }
}

@Suite("SleepStageEvent idempotency")
struct SleepStageEventIdempotencyTests {
    @Test("Inserting two events with the same id results in one row")
    func sameIDDedupes() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        let sharedID = UUID()
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        let end = start.addingTimeInterval(1800)

        let first = SleepStageEvent(
            id: sharedID,
            startTime: start,
            endTime: end,
            stage: "asleepDeep",
            sourceBundleID: "com.apple.health",
            sourceName: "Apple Watch"
        )
        context.insert(first)
        try context.save()

        let second = SleepStageEvent(
            id: sharedID,
            startTime: start,
            endTime: end,
            stage: "asleepDeep",
            sourceBundleID: "com.apple.health",
            sourceName: "Apple Watch"
        )
        context.insert(second)
        try context.save()

        let rows = try context.fetch(FetchDescriptor<SleepStageEvent>())
        #expect(rows.count == 1)
    }
}
