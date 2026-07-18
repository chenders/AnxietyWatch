import Foundation
import Observation

/// The single launch switch for the full-app recording walkthrough. The mode
/// can only become active in a DEBUG build; release builds always evaluate to
/// false even if an argument with the same spelling is supplied.
enum FullAppDemoMode {
    nonisolated static let launchArgument = "-demoFullAppSequence"

    nonisolated static var isActive: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains(launchArgument)
#else
        false
#endif
    }
}

/// Shared clock for the simulated Polar and EMAY sessions. Both devices use
/// the same start instant so their six-hour durations cannot drift apart.
/// `now` is injected for focused deterministic tests.
@MainActor
final class FullAppDemoClock {
    static let initialElapsed: TimeInterval = 6 * 60 * 60

    let epoch: Date
    let deviceStartedAt: Date
    private let nowProvider: () -> Date

    init(epoch: Date = .now, now: @escaping () -> Date = Date.init) {
        self.epoch = epoch
        self.deviceStartedAt = epoch.addingTimeInterval(-Self.initialElapsed)
        self.nowProvider = now
    }

    var now: Date { nowProvider() }
    var elapsed: TimeInterval { max(0, now.timeIntervalSince(deviceStartedAt)) }
}

/// Hardware-free, persistence-free state used by the full-app demo. Values
/// are pure functions of elapsed whole seconds, so chapter relaunches render
/// the same readings at the same logical instant without random state.
@MainActor
@Observable
final class FullAppDemoDeviceSession {
    static let polarName = "Polar H10 (Simulated)"
    static let emayName = "EMAY Oximeter (Simulated)"

    let isEnabled: Bool
    let clock: FullAppDemoClock

    private(set) var elapsed: TimeInterval
    private(set) var polarHeartRate: Int
    private(set) var polarRMSSD: Double
    private(set) var emaySpO2: Int
    private(set) var emayPulse: Int

    init(enabled: Bool = FullAppDemoMode.isActive, clock: FullAppDemoClock? = nil) {
        self.isEnabled = enabled
        let resolvedClock = clock ?? FullAppDemoClock()
        self.clock = resolvedClock
        let values = Self.values(at: resolvedClock.elapsed)
        self.elapsed = resolvedClock.elapsed
        self.polarHeartRate = values.polarHeartRate
        self.polarRMSSD = values.polarRMSSD
        self.emaySpO2 = values.emaySpO2
        self.emayPulse = values.emayPulse
    }

    func refresh() {
        guard isEnabled else { return }
        let nextElapsed = max(elapsed, clock.elapsed)
        let values = Self.values(at: nextElapsed)
        elapsed = nextElapsed
        polarHeartRate = values.polarHeartRate
        polarRMSSD = values.polarRMSSD
        emaySpO2 = values.emaySpO2
        emayPulse = values.emayPulse
    }

    nonisolated static func values(at elapsed: TimeInterval) -> (
        polarHeartRate: Int, polarRMSSD: Double, emaySpO2: Int, emayPulse: Int
    ) {
        let t = floor(max(0, elapsed))
        let heartRate = Int((70 + 7 * sin(t / 17) + 3 * sin(t / 5)).rounded())
        let rmssd = 46 + 7 * sin(t / 29) + 2 * cos(t / 11)
        let spo2 = Int((97 + sin(t / 23) + 0.4 * cos(t / 7)).rounded())
        let pulse = Int((67 + 6 * sin(t / 19) + 2 * cos(t / 6)).rounded())
        return (
            min(86, max(58, heartRate)),
            min(58, max(34, rmssd)),
            min(99, max(94, spo2)),
            min(82, max(57, pulse))
        )
    }
}
