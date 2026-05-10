// AnxietyWatch/Services/PolarHRMParser.swift
import Foundation

/// Decodes one Heart Rate Measurement characteristic (UUID 0x2A37) frame
/// per Bluetooth SIG spec. The Polar H10 emits these at ~1 Hz with HR plus
/// zero-or-more RR intervals (the strap's whole-point feature for HRV).
enum PolarHRMParser {

    enum ParseError: Error, Equatable {
        case truncated
    }

    struct Frame: Equatable {
        let hrBpm: Int
        let rrIntervalsMs: [Double]
    }

    /// 1/1024 s → ms conversion factor.
    private static let rrUnitToMs: Double = 1000.0 / 1024.0

    static func parse(_ data: Data) throws -> Frame {
        guard data.count >= 2 else { throw ParseError.truncated }
        let flags = data[data.startIndex]
        // Bluetooth SIG Heart Rate Measurement flags:
        //   bit 0 (0x01): HR value format (0 = uint8, 1 = uint16)
        //   bits 1-2:     sensor contact status (no payload effect)
        //   bit 3 (0x08): Energy Expended Present → 2-byte uint16 between HR and RR
        //   bit 4 (0x10): RR-Interval Present → trailing list of uint16 values
        let hrIs16Bit = (flags & 0x01) != 0
        let energyExpendedPresent = (flags & 0x08) != 0
        let rrPresent = (flags & 0x10) != 0

        var idx = data.startIndex + 1
        let hrBpm: Int
        if hrIs16Bit {
            guard idx + 2 <= data.endIndex else { throw ParseError.truncated }
            let lo = UInt16(data[idx])
            let hi = UInt16(data[idx + 1])
            hrBpm = Int((hi << 8) | lo)
            idx += 2
        } else {
            hrBpm = Int(data[idx])
            idx += 1
        }

        if energyExpendedPresent {
            guard idx + 2 <= data.endIndex else { throw ParseError.truncated }
            // Field is uint16 little-endian; we don't surface it (the H10 doesn't
            // populate Energy Expended), but we must advance the cursor past it
            // so the RR-interval section begins at the right offset.
            idx += 2
        }

        var rrs: [Double] = []
        if rrPresent {
            while idx < data.endIndex {
                guard idx + 2 <= data.endIndex else { throw ParseError.truncated }
                let lo = UInt16(data[idx])
                let hi = UInt16(data[idx + 1])
                let rr1024 = (hi << 8) | lo
                rrs.append(Double(rr1024) * rrUnitToMs)
                idx += 2
            }
        }

        return Frame(hrBpm: hrBpm, rrIntervalsMs: rrs)
    }
}
