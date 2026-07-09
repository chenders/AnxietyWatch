import Foundation
import Testing

@testable import AnxietyWatch

/// Locks in the reverse-engineered EMAY SleepO2 "S50" BLE protocol
/// (verified live 2026-07-09). The checksum mask (0x7F, not 0xFF) is the
/// detail that made every other command silently fail, so it gets explicit
/// coverage.
struct EMAYProtocolTests {

    @Test("Checksum masks with 0x7F, not 0xFF")
    func checksumMask() {
        // 0x9A sum = 154; & 0x7F = 26 (0x1A). The 0xFF mask would give 0x9A.
        #expect(EMAYProtocol.checksum([0x9A]) == 0x1A)
        #expect(EMAYProtocol.checksum([0x89]) == 0x09)
        // 0x9B + 0x7F = 0x11A; & 0x7F = 0x1A (this is the one that happened to
        // work under either mask, which is why only it responded before).
        #expect(EMAYProtocol.checksum([0x9B, 0x7F]) == 0x1A)
    }

    @Test("Command framing matches the captured app bytes")
    func commandFraming() {
        #expect(EMAYProtocol.hello == [0x89, 0x09])
        #expect(EMAYProtocol.deviceState == [0x8E, 0x05, 0x13])
        #expect(EMAYProtocol.startRealtime == [0x9B, 0x01, 0x1C])
        #expect(EMAYProtocol.getBattery == [0x86, 0x06])
        #expect(EMAYProtocol.heartbeat == [0x9A, 0x1A])
        #expect(EMAYProtocol.stopRealtime == [0x9B, 0x7F, 0x1A])
    }

    @Test("Start sequence is hello → deviceState → startRealtime → getBattery")
    func startSequenceOrder() {
        #expect(EMAYProtocol.startSequence == [
            [0x89, 0x09], [0x8E, 0x05, 0x13], [0x9B, 0x01, 0x1C], [0x86, 0x06],
        ])
    }

    @Test("Parses a real data packet into SpO2 + pulse")
    func parsesRealPacket() throws {
        // eb 01 05 3e 5f 7f 00 0d — captured live: PR 0x3E=62, SpO2 0x5F=95.
        let data = Data([0xEB, 0x01, 0x05, 0x3E, 0x5F, 0x7F, 0x00, 0x0D])
        let r = try #require(EMAYProtocol.parseReading(data, at: Date()))
        #expect(r.pulseRate == 62)
        #expect(r.spo2 == 95)
        #expect(r.isMeasuring)
    }

    @Test("Non-data frames (command ACKs, battery reply) parse to nil")
    func rejectsNonDataFrames() {
        let now = Date()
        // Short frames (battery reply, device-state reply, truncated).
        #expect(EMAYProtocol.parseReading(Data([0xF6, 0x50, 0x46]), at: now) == nil)
        #expect(EMAYProtocol.parseReading(Data([0xFE, 0x05, 0x00, 0x00]), at: now) == nil)
        #expect(EMAYProtocol.parseReading(Data([0xEB, 0x01]), at: now) == nil)
        // Full 8-byte length but WRONG header (not EB 01) — exercises the
        // header discriminator itself, not just the length guard.
        #expect(EMAYProtocol.parseReading(Data([0xF6, 0x50, 0x46, 0x00, 0x00, 0x00, 0x00, 0x00]), at: now) == nil)
    }

    @Test("No-reading sentinels (0xFF, 0x00) yield nil fields, never a fabricated reading")
    func sentinelsYieldNilFields() throws {
        // Valid frame + checksum, but sensor reports its no-finger sentinel.
        // 0xFF: cks(eb 01 05 ff ff 7f 00) = 0x6E.
        let noFinger = try #require(
            EMAYProtocol.parseReading(Data([0xEB, 0x01, 0x05, 0xFF, 0xFF, 0x7F, 0x00, 0x6E]), at: Date()))
        #expect(noFinger.spo2 == nil)
        #expect(noFinger.pulseRate == nil)
        #expect(!noFinger.isMeasuring)
        // 0x00: cks(eb 01 05 00 00 7f 00) = 0x70.
        let zeros = try #require(
            EMAYProtocol.parseReading(Data([0xEB, 0x01, 0x05, 0x00, 0x00, 0x7F, 0x00, 0x70]), at: Date()))
        #expect(zeros.spo2 == nil)
        #expect(zeros.pulseRate == nil)
    }

    // SAFETY-CRITICAL: a genuinely dangerous low (SpO2 40%, pulse 15 bpm) must
    // be reported, not silently discarded as "invalid" — that would be the
    // false-reassurance failure mode for the overdose early-warning path.
    @Test("Clinically severe low values are preserved, not dropped")
    func severeLowsPreserved() throws {
        // cks(eb 01 05 0f 28 7f 00) = 0x27. PR 0x0F=15, SpO2 0x28=40.
        let r = try #require(
            EMAYProtocol.parseReading(Data([0xEB, 0x01, 0x05, 0x0F, 0x28, 0x7F, 0x00, 0x27]), at: Date()))
        #expect(r.spo2 == 40)
        #expect(r.pulseRate == 15)
        #expect(r.isMeasuring)
        #expect(r.hasSpO2)
    }

    @Test("Frame validation rejects bad checksum, wrong fixed bytes, and truncation")
    func rejectsInauthenticFrames() {
        let now = Date()
        // Correct packet is …00 0d; corrupt the checksum → reject.
        #expect(EMAYProtocol.parseReading(Data([0xEB, 0x01, 0x05, 0x3E, 0x5F, 0x7F, 0x00, 0x0C]), at: now) == nil)
        // Wrong fixed byte b[2] (0x06 not 0x05) → reject even if it starts EB 01.
        #expect(EMAYProtocol.parseReading(Data([0xEB, 0x01, 0x06, 0x3E, 0x5F, 0x7F, 0x00, 0x0D]), at: now) == nil)
        // Truncated: full data minus the checksum byte (7 bytes) → reject.
        #expect(EMAYProtocol.parseReading(Data([0xEB, 0x01, 0x05, 0x3E, 0x5F, 0x7F, 0x00]), at: now) == nil)
        // Over-length: a valid 8-byte frame plus a trailing byte (9) → reject,
        // rather than silently ignoring the extra (concatenated/corrupt frame).
        #expect(EMAYProtocol.parseReading(Data([0xEB, 0x01, 0x05, 0x3E, 0x5F, 0x7F, 0x00, 0x0D, 0x00]), at: now) == nil)
    }
}
