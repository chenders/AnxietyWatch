// AnxietyWatchTests/PolarHRMParserTests.swift
import Foundation
import Testing

@testable import AnxietyWatch

struct PolarHRMParserTests {

    @Test("8-bit HR value, no RR intervals")
    func uint8NoRR() throws {
        // Flags 0x00: HR uint8, no RR
        let data = Data([0x00, 75])
        let frame = try PolarHRMParser.parse(data)
        #expect(frame.hrBpm == 75)
        #expect(frame.rrIntervalsMs.isEmpty)
    }

    @Test("8-bit HR value, two RR intervals")
    func uint8TwoRR() throws {
        // Flags 0x10: HR uint8, RR present
        // RR uint16 little-endian, 1/1024 s units. 819 → ~800 ms, 821 → ~801.95 ms
        let data = Data([0x10, 60, 0x33, 0x03, 0x35, 0x03])
        let frame = try PolarHRMParser.parse(data)
        #expect(frame.hrBpm == 60)
        #expect(frame.rrIntervalsMs.count == 2)
        // 819 * 1000/1024 ≈ 799.8 ; tolerate 0.5 ms
        #expect(abs(frame.rrIntervalsMs[0] - 799.8) < 0.5)
        #expect(abs(frame.rrIntervalsMs[1] - 801.8) < 0.5)
    }

    @Test("16-bit HR value, one RR interval")
    func uint16OneRR() throws {
        // Flags 0x11: HR uint16, RR present
        // HR = 0x012C = 300 (intentionally absurd, just exercises the 16-bit path)
        // RR = 0x0400 = 1024 (1/1024 s) → 1000 ms
        let data = Data([0x11, 0x2C, 0x01, 0x00, 0x04])
        let frame = try PolarHRMParser.parse(data)
        #expect(frame.hrBpm == 300)
        #expect(frame.rrIntervalsMs.count == 1)
        #expect(abs(frame.rrIntervalsMs[0] - 1000) < 0.5)
    }

    @Test("Energy Expended field (flag bit 3) is skipped before RR intervals")
    func energyExpendedSkipped() throws {
        // Flags 0x18: HR uint8 + Energy Expended Present + RR Present
        // HR=60, EE=0x0123 (291 kJ), RR=0x0400 = 1024 (1/1024 s) → 1000 ms
        let data = Data([0x18, 60, 0x23, 0x01, 0x00, 0x04])
        let frame = try PolarHRMParser.parse(data)
        #expect(frame.hrBpm == 60)
        #expect(frame.rrIntervalsMs.count == 1)
        #expect(abs(frame.rrIntervalsMs[0] - 1000) < 0.5)
    }

    @Test("Energy Expended without enough bytes throws")
    func truncatedEnergyExpended() {
        // Flags 0x08 (EE present), HR=60, then only 1 byte where EE should be
        let data = Data([0x08, 60, 0x23])
        #expect(throws: PolarHRMParser.ParseError.truncated) {
            try PolarHRMParser.parse(data)
        }
    }

    @Test("malformed frame (truncated RR) throws")
    func truncatedRR() {
        // Flags 0x10 (RR present), HR=60, then only 1 byte of RR
        let data = Data([0x10, 60, 0x33])
        #expect(throws: PolarHRMParser.ParseError.truncated) {
            try PolarHRMParser.parse(data)
        }
    }

    @Test("empty payload throws")
    func emptyFrame() {
        #expect(throws: PolarHRMParser.ParseError.truncated) {
            try PolarHRMParser.parse(Data())
        }
    }
}
