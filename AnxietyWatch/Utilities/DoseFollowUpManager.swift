import Foundation
import UserNotifications

/// Manages 30-minute follow-up notifications after dose-triggered anxiety entries.
/// Tracks pending follow-ups in UserDefaults so they survive app termination.
enum DoseFollowUpManager {

    private static let pendingKey = "pendingDoseFollowUps"
    static let followUpDelay: TimeInterval = 30 * 60 // 30 minutes
    private static let staleThreshold: TimeInterval = 2 * 60 * 60 // 2 hours

    struct PendingFollowUp: Codable, Equatable {
        let doseID: UUID
        let medicationName: String
        let scheduledTime: Date
    }

    // MARK: - Notification Authorization

    /// Request notification permission if not already granted.
    /// Call this the first time a prompted dose is logged.
    static func ensureAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Schedule / Cancel

    /// Schedule a 30-minute follow-up notification for a dose.
    static func scheduleFollowUp(doseID: UUID, medicationName: String) {
        let scheduledTime = Date.now.addingTimeInterval(followUpDelay)

        // Save to UserDefaults
        var pending = loadPending()
        pending.append(PendingFollowUp(
            doseID: doseID,
            medicationName: medicationName,
            scheduledTime: scheduledTime
        ))
        savePending(pending)

        // Schedule local notification
        let content = UNMutableNotificationContent()
        content.title = "How's your anxiety?"
        content.body = "You took \(medicationName) 30 minutes ago"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: followUpDelay,
            repeats: false
        )

        let request = UNNotificationRequest(
            identifier: notificationID(for: doseID),
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request)
    }

    /// Cancel a pending follow-up (e.g., if the dose is deleted).
    static func cancelFollowUp(doseID: UUID) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [notificationID(for: doseID)])
        var pending = loadPending()
        pending.removeAll { $0.doseID == doseID }
        savePending(pending)
    }

    // MARK: - Foreground Check

    /// Returns the first pending follow-up that is due (past scheduled time)
    /// and not yet stale (within 2 hours). Call on app foreground.
    static func pendingFollowUpIfDue() -> PendingFollowUp? {
        let now = Date.now
        let pending = loadPending()
        return pending.first { followUp in
            followUp.scheduledTime <= now &&
            now.timeIntervalSince(followUp.scheduledTime) < staleThreshold
        }
    }

    /// Mark a follow-up as completed or dismissed. Removes it from pending.
    static func completeFollowUp(doseID: UUID) {
        var pending = loadPending()
        pending.removeAll { $0.doseID == doseID }
        savePending(pending)
    }

    /// Remove follow-ups older than 2 hours. Call on app foreground.
    static func cleanupStale() {
        let now = Date.now
        var pending = loadPending()
        pending.removeAll { now.timeIntervalSince($0.scheduledTime) >= staleThreshold }
        savePending(pending)
    }

    // MARK: - Persistence

    static func loadPending() -> [PendingFollowUp] {
        guard let data = UserDefaults.standard.data(forKey: pendingKey) else { return [] }
        return (try? JSONDecoder().decode([PendingFollowUp].self, from: data)) ?? []
    }

    private static func savePending(_ pending: [PendingFollowUp]) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        UserDefaults.standard.set(data, forKey: pendingKey)
    }

    static func notificationID(for doseID: UUID) -> String {
        "dose-followup-\(doseID.uuidString)"
    }
}
