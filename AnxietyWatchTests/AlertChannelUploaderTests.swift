import Testing
import Foundation
@testable import AnxietyWatch

/// Pure-logic tests for the redundant alert-channel uploader (sub-project C
/// Task 5): the sample→wire mapping (including the artifact-drop invariant) and
/// the APNs token hex encoding. The URLSession I/O is thin and exercised only
/// through these pure seams.
struct AlertChannelUploaderTests {
    // A whole-second instant so ISO8601 (second precision) round-trips exactly.
    private let ref = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func mapsSpo2AndHeartRateToServerChannels() {
        let wire = AlertChannelUploader.wireSamples(from: [
            CNSSignalSample(kind: .spo2, source: .emayOximeter, value: 96, timestamp: ref),
            CNSSignalSample(kind: .heartRate, source: .polarH10, value: 62, timestamp: ref),
        ])
        #expect(wire.count == 2)
        #expect(wire.compactMap { $0["channel"] as? String } == ["SPO2", "HR"])
        #expect((wire[0]["value"] as? Double) == 96)
        #expect((wire[1]["value"] as? Double) == 62)
    }

    @Test func dropsArtifactSamples() {
        let wire = AlertChannelUploader.wireSamples(from: [
            CNSSignalSample(kind: .spo2, source: .emayOximeter, value: 80, timestamp: ref, isArtifact: true),
            CNSSignalSample(kind: .spo2, source: .emayOximeter, value: 97, timestamp: ref),
        ])
        // The artifact sample must be ABSENT — never coerced to a value the
        // server backstop could score. A gap is indeterminate, never "safe".
        #expect(wire.count == 1)
        #expect((wire[0]["value"] as? Double) == 97)
    }

    @Test func mapsEveryKindToAChannelForHeartbeatLiveness() {
        // Every kind uploads so the server's no-data heartbeat can track
        // liveness even for a CPAP-only / RR-only session; the SpO2 backstop
        // ignores every channel except "SPO2".
        #expect(AlertChannelUploader.channelLabel(for: .spo2) == "SPO2")
        #expect(AlertChannelUploader.channelLabel(for: .heartRate) == "HR")
        #expect(AlertChannelUploader.channelLabel(for: .respiratoryRate) == "RR")
        #expect(AlertChannelUploader.channelLabel(for: .hrv) == "HRV")
        let wire = AlertChannelUploader.wireSamples(from: [
            CNSSignalSample(kind: .respiratoryRate, source: .as11Bridge, value: 12, timestamp: ref),
            CNSSignalSample(kind: .hrv, source: .polarH10, value: 40, timestamp: ref),
        ])
        #expect(wire.compactMap { $0["channel"] as? String } == ["RR", "HRV"])
    }

    @Test func tagsEachSampleWithItsSource() {
        // Source must reach the server so the backstop evaluates each SpO2
        // source independently (concurrent-source masking fix).
        let wire = AlertChannelUploader.wireSamples(from: [
            CNSSignalSample(kind: .spo2, source: .emayOximeter, value: 96, timestamp: ref),
            CNSSignalSample(kind: .spo2, source: .as11Bridge, value: 88, timestamp: ref),
        ])
        #expect(wire.compactMap { $0["source"] as? String } == ["oximeter", "as11"])
        #expect(AlertChannelUploader.sourceLabel(for: .polarH10) == "polar")
        #expect(AlertChannelUploader.sourceLabel(for: .appleWatch) == "watch")
    }

    @Test func wireSampleTimestampRoundTripsAsISO8601() throws {
        let wire = AlertChannelUploader.wireSamples(from: [
            CNSSignalSample(kind: .spo2, source: .emayOximeter, value: 96, timestamp: ref),
        ])
        let ts = try #require(wire.first?["ts_utc"] as? String)
        #expect(ISO8601DateFormatter().date(from: ts) == ref)
    }

    @Test func hexTokenIsLowercaseHex() {
        #expect(AlertChannelUploader.hexToken(Data([0x00, 0x1f, 0xa0, 0xff])) == "001fa0ff")
        #expect(AlertChannelUploader.hexToken(Data()) == "")
    }
}
