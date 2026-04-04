import Foundation
import SwiftData
import WatchConnectivity

/// iPhone-side WatchConnectivity. Receives anxiety entries from Watch, sends stats back.
final class PhoneConnectivityManager: NSObject, WCSessionDelegate {
    static let shared = PhoneConnectivityManager()

    // Set once during app launch — accessed from nonisolated delegate callbacks
    nonisolated(unsafe) var modelContainer: ModelContainer?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Push latest metrics to the Watch's applicationContext.
    func sendStatsToWatch(lastAnxiety: Int?, hrvAvg: Double?, restingHR: Double?) {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isPaired,
              WCSession.default.isWatchAppInstalled
        else { return }

        var context: [String: Any] = [:]
        if let v = lastAnxiety { context["lastAnxiety"] = v }
        if let v = hrvAvg { context["hrvAvg"] = v }
        if let v = restingHR { context["restingHR"] = v }

        try? WCSession.default.updateApplicationContext(context)
    }

    // MARK: - Check-In Context

    /// Update Watch applicationContext with pending check-in state.
    func updateCheckInContext(pending: Bool) {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isPaired,
              WCSession.default.isWatchAppInstalled
        else { return }

        var context = (try? WCSession.default.receivedApplicationContext) ?? [:]
        context["pendingRandomCheckIn"] = pending
        try? WCSession.default.updateApplicationContext(context)
    }

    // MARK: - WCSessionDelegate (iOS requires all three activation methods)

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    // MARK: - Receiving entries from Watch

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleIncoming(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handleIncoming(userInfo)
    }

    nonisolated private func handleIncoming(_ message: [String: Any]) {
        guard message["type"] as? String == "anxietyEntry",
              let severity = message["severity"] as? Int,
              let ts = message["timestamp"] as? TimeInterval,
              let container = modelContainer
        else { return }

        let notes = message["notes"] as? String ?? ""
        let timestamp = Date(timeIntervalSince1970: ts)

        Task { @MainActor in
            let context = ModelContext(container)
            let entry = AnxietyEntry(timestamp: timestamp, severity: severity, notes: notes)
            context.insert(entry)
            try? context.save()
        }
    }
}
