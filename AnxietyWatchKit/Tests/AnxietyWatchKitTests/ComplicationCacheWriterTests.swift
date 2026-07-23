import XCTest
@testable import AnxietyWatchKit

final class ComplicationCacheWriterTests: XCTestCase {

    var tempDir: URL!
    var writer: ComplicationCacheWriter!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        writer = ComplicationCacheWriter(containerURL: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testDebounceCoalescesBursts() async throws {
        let state1 = ComplicationState(alertTier: "Elevated", fusionScore: 0.5)
        let state2 = ComplicationState(alertTier: "High", fusionScore: 0.8)
        let state3 = ComplicationState(alertTier: "Severe", fusionScore: 1.0)

        await writer.submit(state1)
        await writer.submit(state2)
        await writer.submit(state3)

        // Wait for debounce (500ms) plus a tiny margin
        try await Task.sleep(for: .milliseconds(600))

        let plistURL = tempDir.appendingPathComponent("complication.plist")
        let data = try Data(contentsOf: plistURL)
        let decoded = try PropertyListDecoder().decode(ComplicationState.self, from: data)

        // Ensure only the final state (state3) was written out.
        XCTAssertEqual(decoded, state3)
        XCTAssertEqual(decoded.alertTier, "Severe")
        XCTAssertEqual(decoded.fusionScore, 1.0)

        // Ensure pending is cleared
        let pending = await writer.pendingState
        XCTAssertNil(pending)
    }

    func testNoWriteWhenIdle() async throws {
        // We do nothing, no plist should be created.
        let plistURL = tempDir.appendingPathComponent("complication.plist")
        let tmpURL = tempDir.appendingPathComponent("complication.plist.tmp")

        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpURL.path))

        // Even after waiting, nothing should happen
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL.path))
    }

    func testAtomicWrite() async throws {
        let state = ComplicationState(alertTier: "Normal", fusionScore: 0.1)

        // Directly call flush to avoid waiting for debounce in this test
        await writer.submit(state)
        await writer.flush()

        let plistURL = tempDir.appendingPathComponent("complication.plist")
        let tmpURL = tempDir.appendingPathComponent("complication.plist.tmp")

        XCTAssertTrue(FileManager.default.fileExists(atPath: plistURL.path))
        // TMP file should be gone after atomic replace
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpURL.path))

        let data = try Data(contentsOf: plistURL)
        let decoded = try PropertyListDecoder().decode(ComplicationState.self, from: data)
        XCTAssertEqual(decoded.alertTier, "Normal")
    }

    func testFlushClearsPending() async throws {
        let state = ComplicationState(alertTier: "Normal", fusionScore: 0.1)
        await writer.submit(state)

        var pending = await writer.pendingState
        XCTAssertNotNil(pending)

        await writer.flush()

        pending = await writer.pendingState
        XCTAssertNil(pending)
    }

    func testAppGroupIdentifierIsTheRebrandedGroup() {
        // Regression guard: the writer must use the App Group the Watch app +
        // Widgets (and the Widgets' reader) are entitled for. Reverting to the
        // pre-rebrand "group.com.anxietywatch" silently breaks the watch
        // complication (writer and reader on different containers) and hard-fails
        // a release-build init on device.
        XCTAssertEqual(
            ComplicationCacheWriter.appGroupIdentifier,
            "group.com.groundeffectsoftware.AnxietyWatch.watch"
        )
    }
}
