import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

@Suite("Full-app demo device session")
@MainActor
struct FullAppDemoDeviceSessionTests {
    @Test("Both simulated devices begin at the same six-hour epoch")
    func startsAtSixHours() {
        let epoch = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let clock = FullAppDemoClock(epoch: epoch, now: { epoch })
        let session = FullAppDemoDeviceSession(enabled: true, clock: clock)

        #expect(clock.deviceStartedAt == epoch.addingTimeInterval(-21_600))
        #expect(session.elapsed == 21_600)
        #expect(session.polarHeartRate >= 58 && session.polarHeartRate <= 86)
        #expect(session.polarRMSSD >= 34 && session.polarRMSSD <= 58)
        #expect(session.emaySpO2 >= 94 && session.emaySpO2 <= 99)
        #expect(session.emayPulse >= 57 && session.emayPulse <= 82)
    }

    @Test("Values are deterministic and change without leaving safe ranges")
    func deterministicChangingValues() {
        let first = FullAppDemoDeviceSession.values(at: 21_600)
        let repeated = FullAppDemoDeviceSession.values(at: 21_600)
        let later = FullAppDemoDeviceSession.values(at: 21_637)

        #expect(first.polarHeartRate == repeated.polarHeartRate)
        #expect(first.polarRMSSD == repeated.polarRMSSD)
        #expect(first.emaySpO2 == repeated.emaySpO2)
        #expect(first.emayPulse == repeated.emayPulse)
        #expect(first.polarHeartRate != later.polarHeartRate || first.polarRMSSD != later.polarRMSSD)
        #expect(first.emaySpO2 != later.emaySpO2 || first.emayPulse != later.emayPulse)
        #expect((58...86).contains(later.polarHeartRate))
        #expect((34.0...58.0).contains(later.polarRMSSD))
        #expect((94...99).contains(later.emaySpO2))
        #expect((57...82).contains(later.emayPulse))
    }

    @Test("Refresh advances both devices from one monotonic clock")
    func refreshAdvancesMonotonically() {
        let epoch = Date(timeIntervalSinceReferenceDate: 2_000_000)
        var now = epoch
        let clock = FullAppDemoClock(epoch: epoch, now: { now })
        let session = FullAppDemoDeviceSession(enabled: true, clock: clock)

        now = epoch.addingTimeInterval(12)
        session.refresh()
        #expect(session.elapsed == 21_612)

        now = epoch.addingTimeInterval(3)
        session.refresh()
        #expect(session.elapsed == 21_612)
    }

    @Test("Polar and EMAY adapters are active and cannot stop or persist")
    func serviceAdaptersAreSideEffectFree() throws {
        let container = try PreviewHelpers.makeFullContainer()
        let context = ModelContext(container)
        let epoch = Date(timeIntervalSinceReferenceDate: 3_000_000)
        let clock = FullAppDemoClock(epoch: epoch, now: { epoch })
        let demo = FullAppDemoDeviceSession(enabled: true, clock: clock)
        let polar = PolarHRMService(modelContext: context, demoSession: demo)
        let emay = EMAYRealtimeService(modelContext: context, demoSession: demo)

        #expect(polar.isFullAppDemoSimulated)
        #expect(polar.isPaired)
        #expect(polar.state.status == .recording)
        #expect(polar.state.sessionElapsed == 21_600)
        #expect(polar.state.pairedDeviceName == FullAppDemoDeviceSession.polarName)
        #expect(emay.isFullAppDemoSimulated)
        #expect(emay.status == .streaming)
        #expect(emay.fullAppDemoElapsed == 21_600)

        polar.stopSession()
        emay.stop()
        #expect(polar.state.status == .recording)
        #expect(emay.status == .streaming)
        #expect(try context.fetch(FetchDescriptor<SensorSession>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<QuantityHealthSample>()).isEmpty)
    }
}
