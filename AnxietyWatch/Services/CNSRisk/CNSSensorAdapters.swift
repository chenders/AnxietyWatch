import Foundation

/// Pure, hardware-independent EMAY/Polar → `[CNSSignalSample]` mapping (spec
/// §4, §5.1). No BLE/CoreBluetooth imports here by design — these are static
/// value transforms the coordinator calls on every tick with whatever the
/// live services last reported; nothing here ever touches a raw BLE frame.
///
/// Never coerce invalid/missing sensor data to a value (spec §5.1, §11): a
/// nil field yields NO sample for that kind — it must never fabricate a
/// reading, and it must never silently substitute a stale/sentinel value.
enum CNSSensorAdapters {
    /// EMAY oximeter → 0, 1, or 2 samples. SpO₂ is 0-100 percent on both
    /// `EMAYReading.spo2` and `CNSSignalSample.value` — no scale conversion.
    /// Gates on `hasSpO2`/`hasPulse`, NEVER `isMeasuring`: a pulse-only
    /// reading (finger off, SpO₂ dropped) is `isMeasuring == true` with no
    /// SpO₂, and gating on `isMeasuring` would fabricate a spo2 sample from
    /// nothing (see `EMAYReading.isMeasuring` doc).
    ///
    /// The EMAY device exposes no perfusion index, so `perfusionIndex` stays
    /// nil on every sample this adapter emits — the quality gate's PI rules
    /// (`perfusionSoftFloor`/`perfusionHardFloor`) are therefore inert for
    /// this source; spec §14.2's fallback (recency + cross-sample agreement)
    /// still governs quality downstream.
    static func samples(from reading: EMAYReading) -> [CNSSignalSample] {
        var result: [CNSSignalSample] = []
        if reading.hasSpO2, let spo2 = reading.spo2 {
            result.append(CNSSignalSample(
                kind: .spo2, source: .emayOximeter,
                value: Double(spo2), timestamp: reading.timestamp
            ))
        }
        if reading.hasPulse, let pulse = reading.pulseRate {
            result.append(CNSSignalSample(
                kind: .heartRate, source: .emayOximeter,
                value: Double(pulse), timestamp: reading.timestamp
            ))
        }
        return result
    }

    /// Polar H10 live heart rate → 0 or 1 corroborating-only sample (spec
    /// §5.2: heart rate can raise watchfulness but never confirms/klaxons
    /// alone). No perfusion index — the Polar strap has no PPG channel.
    static func samples(polarHR: Int?, at timestamp: Date) -> [CNSSignalSample] {
        guard let hr = polarHR else { return [] }
        return [CNSSignalSample(
            kind: .heartRate, source: .polarH10, value: Double(hr), timestamp: timestamp
        )]
    }

    /// Polar H10 per-minute RMSSD → 0 or 1 corroborating-only HRV sample (ms,
    /// compared as a fraction of the personal baseline downstream). No
    /// perfusion index.
    static func samples(polarRMSSD: Double?, at timestamp: Date) -> [CNSSignalSample] {
        guard let rmssd = polarRMSSD else { return [] }
        return [CNSSignalSample(
            kind: .hrv, source: .polarH10, value: rmssd, timestamp: timestamp
        )]
    }

    /// AS11 Bridge feed → SpO₂ and HR samples.
    /// Pressure, flow, and leak are context channels and do not become `CNSSignalSample`s
    /// but they influence the `AS11StreamState`.
    ///
    /// Two guards specific to this source's untrusted network + third-party-
    /// bridge + Postgres round trip (EMAY/Polar are on-device):
    /// - **Plausibility:** an out-of-range value (dropped-channel sentinel `0`,
    ///   or a flow/leak/pressure number mislabeled into the SpO₂/HR slot) yields
    ///   NO sample — invalid data contributes nothing (spec §11), never a
    ///   fabricated reading that could drive a false escalation. Bounds reject
    ///   only the impossible, never a real desaturation.
    /// - **Timestamp:** time-window on the LOCAL receipt instant (`receivedAt`,
    ///   stamped at ingest) so a skewed bridge clock can't push live samples
    ///   out of the gate window. Fall back to the server `timestampUTC` only for
    ///   directly-constructed payloads that never crossed the socket.
    static func samples(from payload: AS11StreamPayload) -> [CNSSignalSample] {
        var result: [CNSSignalSample] = []
        let timestamp = payload.receivedAt ?? payload.timestampUTC
        if let spo2 = payload.spo2, CNSMonitoringConstants.as11PlausibleSpO2Percent.contains(spo2) {
            result.append(CNSSignalSample(
                kind: .spo2, source: .as11Bridge, value: spo2, timestamp: timestamp
            ))
        }
        if let hr = payload.hr, CNSMonitoringConstants.as11PlausibleHeartRate.contains(hr) {
            result.append(CNSSignalSample(
                kind: .heartRate, source: .as11Bridge, value: hr, timestamp: timestamp
            ))
        }
        return result
    }
}
