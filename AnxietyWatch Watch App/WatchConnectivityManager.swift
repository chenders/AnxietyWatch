import Foundation
import WatchConnectivity
import WidgetKit

/// Watch-side connectivity. Sends anxiety entries to iPhone, receives stats via applicationContext.
@Observable
final class WatchConnectivityManager: NSObject, WCSessionDelegate {
    static let shared = WatchConnectivityManager()

    var lastAnxiety: Int?
    var hrvAvg: Double?
    var restingHR: Double?
    var lastSyncStatus: String?
    var pendingRandomCheckIn = false

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func sendAnxietyEntry(severity: Int, notes: String = "", source: String? = nil) {
        var message: [String: Any] = [
            "type": "anxietyEntry",
            "severity": severity,
            "timestamp": Date().timeIntervalSince1970,
            "notes": notes,
        ]
        if let source {
            message["source"] = source
        }

        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil) { [weak self] _ in
                // Phone not reachable — queue for later delivery
                WCSession.default.transferUserInfo(message)
                Task { @MainActor in
                    self?.lastSyncStatus = "Queued"
                }
            }
        } else {
            WCSession.default.transferUserInfo(message)
        }
    }

    private static let appGroup = "group.org.waitingforthefuture.AnxietyWatch.watch"

    private func loadContext() {
        let ctx = WCSession.default.receivedApplicationContext
        lastAnxiety = ctx["lastAnxiety"] as? Int
        hrvAvg = ctx["hrvAvg"] as? Double
        restingHR = ctx["restingHR"] as? Double
        pendingRandomCheckIn = ctx["pendingRandomCheckIn"] as? Bool ?? false
        pushToWidget()
    }

    /// Write stats to shared UserDefaults so the widget extension can read them.
    private func pushToWidget() {
        guard let defaults = UserDefaults(suiteName: Self.appGroup) else { return }
        if let v = lastAnxiety { defaults.set(v, forKey: "lastAnxiety") }
        if let v = hrvAvg { defaults.set(v, forKey: "hrvAvg") }
        if let v = restingHR { defaults.set(v, forKey: "restingHR") }
        defaults.set(Date().timeIntervalSince1970, forKey: "lastUpdate")
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        Task { @MainActor in self.loadContext() }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor in
            self.applyIncomingData(applicationContext)
        }
    }

    /// Handle queued `transferUserInfo` deliveries from the phone side.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            self.applyIncomingData(userInfo)
        }
    }

    // MARK: - Helpers

    @MainActor
    private func applyIncomingData(_ data: [String: Any]) {
        if let v = data["lastAnxiety"] as? Int { lastAnxiety = v }
        if let v = data["hrvAvg"] as? Double { hrvAvg = v }
        if let v = data["restingHR"] as? Double { restingHR = v }
        pendingRandomCheckIn = data["pendingRandomCheckIn"] as? Bool ?? pendingRandomCheckIn
        pushToWidget()
    }
}
