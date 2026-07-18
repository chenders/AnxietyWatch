import XCTest
@testable import AnxietyWatchKit

final class DiagnosticsViewTests: XCTestCase {

    // MARK: - Snapshot construction

    func testDefaultSnapshotHasSaneDefaults() {
        let s = DiagnosticsSnapshot()
        XCTAssertEqual(s.pipeline.currentTier, .normal)
        XCTAssertEqual(s.pipeline.fusionOverall, 0.0)
        XCTAssertEqual(s.pipeline.ringCounts.hr, 0)
        XCTAssertFalse(s.pipeline.isRunning)
        XCTAssertNil(s.pipeline.lastGapEndMs)
        XCTAssertTrue(s.syncCursors.perNode.isEmpty)
        XCTAssertTrue(s.sources.isEmpty)
        XCTAssertFalse(s.system.clockSuspect)
        XCTAssertEqual(s.system.lastPanicResult, "—")
    }

    func testSnapshotFullyPopulated() {
        let nodeID = Data(repeating: 0xAB, count: 16)
        let s = DiagnosticsSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_720_000_000),
            pipeline: .init(
                currentTier: .warning,
                fusionOverall: 0.45,
                fusionContributions: .init(hr: 0.6, hrv: 0.2, spo2: 0.8, accel: 0.3, breath: 0.0),
                ringCounts: .init(hr: 95, spo2: 42, hrv: 30, accel: 150),
                isRunning: true,
                lastGapEndMs: 1_720_000_000_000,
                thresholds: CNSThresholds()
            ),
            syncCursors: .init(perNode: [
                .init(nodeID: nodeID, pullSamplesHLC: 1_720_000_000_000,
                      pushSamplesHLC: 1_719_999_000_000,
                      pullTombstonesHLC: 0, pushTombstonesHLC: 0)
            ]),
            sources: [
                .init(name: "Polar", lastFrameAt: 1_719_999_000, secondsSinceLastFrame: 12, isIdle: false),
                .init(name: "HealthKit", lastFrameAt: nil, secondsSinceLastFrame: nil, isIdle: true)
            ],
            system: .init(
                clockSuspect: false,
                lastPanicResult: "normal",
                dbSizeBytes: 45_000_000,
                nodeIDSuffix: "AB01",
                hlcPhysicalNow: 1_720_000_000_000,
                localNodeCount: 2
            )
        )

        XCTAssertEqual(s.pipeline.currentTier, .warning)
        XCTAssertEqual(s.pipeline.fusionOverall, 0.45)
        XCTAssertEqual(s.pipeline.fusionContributions.hr, 0.6)
        XCTAssertEqual(s.pipeline.fusionContributions.spo2, 0.8)
        XCTAssertEqual(s.pipeline.ringCounts.accel, 150)
        XCTAssertTrue(s.pipeline.isRunning)
        XCTAssertEqual(s.pipeline.lastGapEndMs, 1_720_000_000_000)
        XCTAssertEqual(s.syncCursors.perNode.count, 1)
        XCTAssertEqual(s.syncCursors.perNode.first?.pullSamplesHLC, 1_720_000_000_000)
        XCTAssertEqual(s.sources.count, 2)
        XCTAssertEqual(s.sources.first?.name, "Polar")
        XCTAssertEqual(s.sources.first?.isIdle, false)
        XCTAssertEqual(s.sources.last?.isIdle, true)
        XCTAssertEqual(s.system.dbSizeBytes, 45_000_000)
        XCTAssertEqual(s.system.localNodeCount, 2)
    }

    // MARK: - CursorNode suffix

    func testCursorNodeSuffixFromKnownData() {
        let node = DiagnosticsSnapshot.CursorNode(
            nodeID: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            pullSamplesHLC: 1000
        )
        XCTAssertEqual(node.nodeIDSuffix, "BEEF")
    }

    func testCursorNodeSuffixShortData() {
        let node = DiagnosticsSnapshot.CursorNode(
            nodeID: Data([0x42]),
            pullSamplesHLC: 0
        )
        XCTAssertEqual(node.nodeIDSuffix, "??")
    }

    // MARK: - Codable round-trip

    func testSnapshotCodableRoundTrip() throws {
        let nodeID = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                           0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10])
        let original = DiagnosticsSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pipeline: .init(
                currentTier: .advisory,
                fusionOverall: 0.33,
                fusionContributions: .init(hr: 0.5, hrv: 0.1, spo2: 0.6, accel: 0.0, breath: 0.1),
                ringCounts: .init(hr: 60, spo2: 30, hrv: 15, accel: 0),
                isRunning: true,
                lastGapEndMs: nil,
                thresholds: CNSThresholds()
            ),
            syncCursors: .init(perNode: [
                .init(nodeID: nodeID, pullSamplesHLC: 1_700_000_000_000,
                      pushSamplesHLC: 1_700_000_001_000,
                      pullTombstonesHLC: 500, pushTombstonesHLC: 600)
            ]),
            sources: [
                .init(name: "EMAY", lastFrameAt: 1_699_000_000, secondsSinceLastFrame: 5, isIdle: false)
            ],
            system: .init(
                clockSuspect: true,
                lastPanicResult: "yellowSyncFailedNoActionNeeded",
                dbSizeBytes: 200_000_000,
                nodeIDSuffix: "0F10",
                hlcPhysicalNow: 1_700_000_002_000,
                localNodeCount: 3
            )
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(DiagnosticsSnapshot.self, from: data)

        XCTAssertEqual(decoded.pipeline.currentTier, original.pipeline.currentTier)
        XCTAssertEqual(decoded.pipeline.fusionOverall, original.pipeline.fusionOverall)
        XCTAssertEqual(decoded.pipeline.ringCounts.hr, original.pipeline.ringCounts.hr)
        XCTAssertEqual(decoded.syncCursors.perNode.count, original.syncCursors.perNode.count)
        XCTAssertEqual(decoded.syncCursors.perNode.first?.nodeIDSuffix, "0F10")
        XCTAssertEqual(decoded.syncCursors.perNode.first?.pullSamplesHLC, 1_700_000_000_000)
        XCTAssertEqual(decoded.sources.count, 1)
        XCTAssertEqual(decoded.system.clockSuspect, true)
        XCTAssertEqual(decoded.system.lastPanicResult, "yellowSyncFailedNoActionNeeded")
    }

    func testEmptySnapshotCodableRoundTrip() throws {
        let original = DiagnosticsSnapshot()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DiagnosticsSnapshot.self, from: data)
        XCTAssertEqual(decoded.pipeline.currentTier, .normal)
        XCTAssertTrue(decoded.syncCursors.perNode.isEmpty)
    }

    // MARK: - Snapshot with multiple nodes

    func testMultipleCursorNodes() {
        let n1 = Data(repeating: 0xAA, count: 16)
        let n2 = Data(repeating: 0xBB, count: 16)
        let s = DiagnosticsSnapshot(
            syncCursors: .init(perNode: [
                .init(nodeID: n1, pullSamplesHLC: 100, pushSamplesHLC: 200),
                .init(nodeID: n2, pullSamplesHLC: 300, pushSamplesHLC: 400)
            ])
        )
        XCTAssertEqual(s.syncCursors.perNode.count, 2)
        // Sort should be stable by construction order
        XCTAssertEqual(s.syncCursors.perNode[0].nodeIDSuffix, "AAAA")
        XCTAssertEqual(s.syncCursors.perNode[1].nodeIDSuffix, "BBBB")
    }

    // MARK: - Fusion contributions zero

    func testFusionContributionsAllZero() {
        let fc = DiagnosticsSnapshot.FusionContributions()
        XCTAssertEqual(fc.hr, 0)
        XCTAssertEqual(fc.hrv, 0)
        XCTAssertEqual(fc.spo2, 0)
        XCTAssertEqual(fc.accel, 0)
        XCTAssertEqual(fc.breath, 0)
    }

    // MARK: - Source state idle vs active

    func testSourceStateIdleVsActive() {
        let active = DiagnosticsSnapshot.SourceState(
            name: "Polar", lastFrameAt: 1_000_000, secondsSinceLastFrame: 2, isIdle: false
        )
        let idle = DiagnosticsSnapshot.SourceState(
            name: "HealthKit", lastFrameAt: 1_000_000, secondsSinceLastFrame: 320, isIdle: true
        )
        let never = DiagnosticsSnapshot.SourceState(
            name: "EMAY", lastFrameAt: nil, secondsSinceLastFrame: nil, isIdle: true
        )

        XCTAssertFalse(active.isIdle)
        XCTAssertTrue(idle.isIdle)
        XCTAssertTrue(never.isIdle)
        XCTAssertEqual(active.secondsSinceLastFrame, 2)
        XCTAssertNil(never.secondsSinceLastFrame)
    }
}
