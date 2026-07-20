import Foundation
import Testing

@testable import AnxietyWatch

/// Covers `CNSSensorAdapters`: pure EMAY/Polar → `[CNSSignalSample]` mapping.
/// Adapters must never fabricate a value for a missing sensor field (spec
/// §5.1, §11) — the tests below assert exact sample counts/kinds, not just
/// "no crash." SpO₂ is 0-100 percent on both `EMAYReading.spo2` and
/// `CNSSignalSample.value` — no conversion. EMAY exposes no perfusion index,
/// so `perfusionIndex` must stay nil for every EMAY-sourced sample.
struct CNSSensorAdapterTests {
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - EMAY

    @Test("EMAY reading with both values yields exactly [spo2, heartRate]")
    func emayBothValues() {
        let reading = EMAYReading(spo2: 96, pulseRate: 62, timestamp: t0)
        let samples = CNSSensorAdapters.samples(from: reading)
        #expect(samples.count == 2)

        let spo2 = samples.first { $0.kind == .spo2 }
        #expect(spo2 != nil)
        #expect(spo2?.source == .emayOximeter)
        #expect(abs((spo2?.value ?? -1) - 96) < 0.001)
        #expect(spo2?.timestamp == t0)
        #expect(spo2?.perfusionIndex == nil)

        let hr = samples.first { $0.kind == .heartRate }
        #expect(hr != nil)
        #expect(hr?.source == .emayOximeter)
        #expect(abs((hr?.value ?? -1) - 62) < 0.001)
        #expect(hr?.timestamp == t0)
        #expect(hr?.perfusionIndex == nil)
    }

    @Test("EMAY pulse-only reading (no finger / no SpO2) yields only heartRate — never a fabricated spo2")
    func emayPulseOnly() {
        let reading = EMAYReading(spo2: nil, pulseRate: 58, timestamp: t0)
        let samples = CNSSensorAdapters.samples(from: reading)
        #expect(samples.count == 1)
        #expect(samples[0].kind == .heartRate)
        #expect(abs(samples[0].value - 58) < 0.001)
        #expect(samples.contains { $0.kind == .spo2 } == false)
    }

    @Test("EMAY spo2-only reading yields only spo2")
    func emaySpO2Only() {
        let reading = EMAYReading(spo2: 91, pulseRate: nil, timestamp: t0)
        let samples = CNSSensorAdapters.samples(from: reading)
        #expect(samples.count == 1)
        #expect(samples[0].kind == .spo2)
        #expect(abs(samples[0].value - 91) < 0.001)
        #expect(samples.contains { $0.kind == .heartRate } == false)
    }

    @Test("Fully-nil EMAY reading yields no samples")
    func emayFullyNil() {
        let reading = EMAYReading(spo2: nil, pulseRate: nil, timestamp: t0)
        let samples = CNSSensorAdapters.samples(from: reading)
        #expect(samples.isEmpty)
    }

    // MARK: - AS11

    @Test(
        "AS11 emits only present SpO2 and HR fields",
        arguments: [
            (spo2: 94.0 as Double?, hr: 61.0 as Double?, expectedKinds: [CNSSignalKind.spo2, .heartRate]),
            (spo2: 94.0 as Double?, hr: nil, expectedKinds: [CNSSignalKind.spo2]),
            (spo2: nil, hr: 61.0 as Double?, expectedKinds: [CNSSignalKind.heartRate]),
            (spo2: nil, hr: nil, expectedKinds: [])
        ]
    )
    func as11PresentAndAbsentFields(
        spo2: Double?, hr: Double?, expectedKinds: [CNSSignalKind]
    ) {
        let payload = AS11StreamPayload(
            id: "fictional-as11", bridgeId: "test-bridge", timestampUTC: t0,
            pressure: nil, flow: nil, leak: nil, spo2: spo2, hr: hr,
            state: AS11StreamState.streamingOK.rawValue
        )

        let samples = CNSSensorAdapters.samples(from: payload)

        #expect(samples.map(\.kind) == expectedKinds)
        #expect(samples.allSatisfy { $0.source == .as11Bridge && $0.timestamp == t0 })
        #expect(samples.first { $0.kind == .spo2 }?.value == spo2)
        #expect(samples.first { $0.kind == .heartRate }?.value == hr)
    }

    // MARK: - Polar

    @Test("Polar HR 62 yields one heartRate/polarH10 sample with no PI")
    func polarHR() {
        let samples = CNSSensorAdapters.samples(polarHR: 62, at: t0)
        #expect(samples.count == 1)
        #expect(samples[0].kind == .heartRate)
        #expect(samples[0].source == .polarH10)
        #expect(abs(samples[0].value - 62) < 0.001)
        #expect(samples[0].timestamp == t0)
        #expect(samples[0].perfusionIndex == nil)
    }

    @Test("Polar HR nil yields no samples")
    func polarHRNil() {
        let samples = CNSSensorAdapters.samples(polarHR: nil, at: t0)
        #expect(samples.isEmpty)
    }

    @Test("Polar RMSSD 45.0 yields one hrv/polarH10 sample with no PI")
    func polarRMSSD() {
        let samples = CNSSensorAdapters.samples(polarRMSSD: 45.0, at: t0)
        #expect(samples.count == 1)
        #expect(samples[0].kind == .hrv)
        #expect(samples[0].source == .polarH10)
        #expect(abs(samples[0].value - 45.0) < 0.001)
        #expect(samples[0].timestamp == t0)
        #expect(samples[0].perfusionIndex == nil)
    }

    @Test("Polar RMSSD nil yields no samples")
    func polarRMSSDNil() {
        let samples = CNSSensorAdapters.samples(polarRMSSD: nil, at: t0)
        #expect(samples.isEmpty)
    }
}
