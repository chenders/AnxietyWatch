import Foundation
import SwiftData
import WatchConnectivity

/// Assembles every input the HealthKit-access diagnostic needs — recent history
/// (SwiftData), Watch pairing (WatchConnectivity), the grace timer, and the
/// live presence probe — in one place, so the Dashboard banner and the Apple
/// Health settings panel stay in sync. WCSession is activated at launch by
/// PhoneConnectivityManager, so isPaired is valid by the time any view runs.
enum HealthKitAccessProbe {
    static func currentResult(
        modelContext: ModelContext,
        now: Date = Date(),
        watchPaired: Bool? = nil,
        source: HealthKitDataSource = HealthKitManager.shared,
        defaults: UserDefaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
    ) async -> HealthKitAccessDiagnostic.Result {
        // Recent history — single-clause, date-bounded fetch.
        let cutoff = Calendar.current.date(
            byAdding: .day, value: -HealthKitHistoryProbe.defaultWindowDays, to: now) ?? now
        let descriptor = FetchDescriptor<HealthSnapshot>(
            predicate: #Predicate { $0.date >= cutoff })
        let snapshots = (try? modelContext.fetch(descriptor)) ?? []
        let hadHistory = HealthKitHistoryProbe.hadRecentHealthKitData(in: snapshots, now: now)

        // External corroboration: a paired Watch means data should exist.
        let paired = watchPaired ?? (WCSession.isSupported() && WCSession.default.isPaired)

        // Grace: stamp first-authorized once auth is determined, then check age.
        var graceElapsed = false
        if await !source.authorizationNeedsRequest() {
            let firstAuth = HealthKitGraceGate.recordFirstAuthorizedIfNeeded(now: now, defaults: defaults)
            graceElapsed = HealthKitGraceGate.hasElapsed(firstAuthorizedAt: firstAuth, now: now)
        }

        return await HealthKitAccessDiagnostic(source: source).run(
            now: now, hadRecentHistory: hadHistory,
            watchPaired: paired, graceElapsed: graceElapsed)
    }
}
