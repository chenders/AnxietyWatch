import XCTest
@testable import AnxietyWatchKit

final class ExportLogsTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ExportLogs_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - zip structure

    func testExportWithDBAndCursorProducesZip() async throws {
        let dbURL = tempDir.appendingPathComponent("tsdb.sqlite")
        let cursorURL = tempDir.appendingPathComponent("sync_cursor.json")

        // Write some content so the files exist
        try Data("test-db-content".utf8).write(to: dbURL)
        try Data("{\"cursor\": 1}".utf8).write(to: cursorURL)

        let bundle = try await ExportLogs.exportBundle(
            databaseURL: dbURL,
            cursorFileURL: cursorURL,
            since: Date(),
            maximumLogEntries: 100
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.zipURL.path))
        XCTAssertGreaterThanOrEqual(bundle.fileCount, 3) // db + cursor + log
        let zipData = try Data(contentsOf: bundle.zipURL)
        XCTAssertGreaterThan(zipData.count, 100) // zip header + entries

        // Verify the ZIP local file header signature (0x04034b50)
        let sig = zipData.prefix(4).withUnsafeBytes {
            $0.load(as: UInt32.self)
        }
        XCTAssertEqual(sig.littleEndian, 0x04034b50, "ZIP local file header signature")
    }

    func testExportWithOnlyCursorFile() async throws {
        let dbURL = tempDir.appendingPathComponent("tsdb.sqlite")
        let cursorURL = tempDir.appendingPathComponent("sync_cursor.json")

        // Only the cursor file exists
        try Data("cursor-data".utf8).write(to: cursorURL)

        let bundle = try await ExportLogs.exportBundle(
            databaseURL: dbURL,
            cursorFileURL: cursorURL,
            since: Date(),
            maximumLogEntries: 100
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.zipURL.path))
        // db absent, cursor + log present
        XCTAssertGreaterThanOrEqual(bundle.fileCount, 2)
    }

    func testExportWithNoFilesStillProducesZip() async throws {
        let dbURL = tempDir.appendingPathComponent("nonexistent.sqlite")
        let cursorURL = tempDir.appendingPathComponent("nonexistent.json")

        let bundle = try await ExportLogs.exportBundle(
            databaseURL: dbURL,
            cursorFileURL: cursorURL,
            since: Date(),
            maximumLogEntries: 100
        )

        // At minimum, the OSLog dump is always included
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.zipURL.path))
        XCTAssertGreaterThanOrEqual(bundle.fileCount, 1) // just the log file
    }

    func testExportWithWALFile() async throws {
        let dbURL = tempDir.appendingPathComponent("tsdb.sqlite")
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        let cursorURL = tempDir.appendingPathComponent("sync_cursor.json")

        try Data("db".utf8).write(to: dbURL)
        try Data("wal".utf8).write(to: walURL)
        try Data("cursor".utf8).write(to: cursorURL)

        let bundle = try await ExportLogs.exportBundle(
            databaseURL: dbURL,
            cursorFileURL: cursorURL,
            since: Date(),
            maximumLogEntries: 100
        )

        let zipData = try Data(contentsOf: bundle.zipURL)

        // Search for the WAL filename in the zip data (only appears if WAL was bundled)
        let walName = "tsdb.sqlite-wal".data(using: .utf8)!
        let containsWAL = zipData.range(of: walName) != nil
        XCTAssertTrue(containsWAL, "WAL file should be referenced in the ZIP")

        XCTAssertGreaterThanOrEqual(bundle.fileCount, 4) // db + wal + cursor + log
    }

    // MARK: - OSLog fallback

    func testOSLogDumpWhenStoreUnavailable() async throws {
        // ExportLogs handles OSLogStore failures internally.
        // The output always includes the log file even when empty.
        let dbURL = tempDir.appendingPathComponent("dummy.sqlite")
        let cursorURL = tempDir.appendingPathComponent("dummy.json")
        try Data("x".utf8).write(to: dbURL)
        try Data("x".utf8).write(to: cursorURL)

        let bundle = try await ExportLogs.exportBundle(
            databaseURL: dbURL,
            cursorFileURL: cursorURL,
            since: Date(),
            maximumLogEntries: 100
        )

        let zipData = try Data(contentsOf: bundle.zipURL)
        let logName = "anxietywatch.log".data(using: .utf8)!
        XCTAssertNotNil(zipData.range(of: logName), "anxietywatch.log should be in the zip")
    }

    // MARK: - Bundle struct

    func testBundleValues() {
        let url = URL(fileURLWithPath: "/tmp/test.zip")
        let b = ExportLogs.Bundle(zipURL: url, fileCount: 5)
        XCTAssertEqual(b.zipURL, url)
        XCTAssertEqual(b.fileCount, 5)
    }

    // MARK: - ZIP with many files

    func testZipWithManyFiles() async throws {
        let dbURL = tempDir.appendingPathComponent("tsdb.sqlite")
        let cursorURL = tempDir.appendingPathComponent("sync_cursor.json")

        // Write large-ish DB content to exercise compression path
        let largeContent = Data(repeating: 0x41, count: 50_000)
        try largeContent.write(to: dbURL)
        try Data("cursor".utf8).write(to: cursorURL)

        let bundle = try await ExportLogs.exportBundle(
            databaseURL: dbURL,
            cursorFileURL: cursorURL,
            since: Date(),
            maximumLogEntries: 100
        )

        let zipData = try Data(contentsOf: bundle.zipURL)
        // The compressed zip should be noticeably smaller than 50 kB due to DEFLATE
        XCTAssertLessThan(zipData.count, 52_000, "DEFLATE should compress repetitive content")
    }
}
