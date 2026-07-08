import Foundation
import os
import UserNotifications

/// Manages 30-minute follow-up notifications after dose-triggered anxiety entries.
/// Tracks pending follow-ups in UserDefaults so they survive app termination.
enum DoseFollowUpManager {

    private static let pendingKey = "pendingDoseFollowUps"
    /// Where an undecodable pending blob is preserved so a Codable schema change
    /// on an app update can't silently destroy the user's pending follow-ups.
    /// Internal (not private) so migration-safety tests can assert preservation.
    static let corruptBackupKey = "pendingDoseFollowUps.corruptBackup"
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

        // Save to UserDefaults (dedup first)
        var pending = loadPending()
        pending.removeAll { $0.doseID == doseID }
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
    static func pendingFollowUpIfDue(now: Date = .now) -> PendingFollowUp? {
        let pending = loadPending()
        return pending.first { followUp in
            followUp.scheduledTime <= now &&
            now.timeIntervalSince(followUp.scheduledTime) < staleThreshold
        }
    }

    /// Mark a follow-up as completed or dismissed. Removes from pending and cancels notification.
    static func completeFollowUp(doseID: UUID) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [notificationID(for: doseID)])
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [notificationID(for: doseID)])
        var pending = loadPending()
        pending.removeAll { $0.doseID == doseID }
        savePending(pending)
    }

    /// Remove follow-ups older than 2 hours and their notifications. Call on app foreground.
    static func cleanupStale(now: Date = .now) {
        var pending = loadPending()
        let stale = pending.filter { now.timeIntervalSince($0.scheduledTime) >= staleThreshold }
        if !stale.isEmpty {
            let ids = stale.map { notificationID(for: $0.doseID) }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
        pending.removeAll { now.timeIntervalSince($0.scheduledTime) >= staleThreshold }
        savePending(pending)
    }

    // MARK: - Persistence

    static func loadPending() -> [PendingFollowUp] {
        let defaults = UserDefaults.standard
        // No stored data is a clean empty state, NOT a failure — return [].
        guard let data = defaults.data(forKey: pendingKey) else { return [] }
        do {
            return try JSONDecoder().decode([PendingFollowUp].self, from: data)
        } catch {
            // Migration safety: a decode failure (e.g. a Codable schema change on
            // a future app update) must not silently discard pending follow-ups
            // and let the next savePending overwrite the key with []. Preserve the
            // undecodable blob under a backup key so it can be recovered/migrated,
            // then REMOVE the primary key: leaving the corrupt blob in place would
            // make every subsequent loadPending re-hit this path and re-log the
            // same error until something happens to save (Copilot review of #164).
            // Only back up if we haven't already, so a repeat decode failure can't
            // clobber the original corrupt blob with a later (already-cleared)
            // value. Log the size only — never the contents (medication names).
            if defaults.data(forKey: corruptBackupKey) == nil {
                defaults.set(data, forKey: corruptBackupKey)
            }
            defaults.removeObject(forKey: pendingKey)
            Log.data.error("DoseFollowUp decode failed; preserved \(data.count, privacy: .public)-byte blob under backup key")
            return []
        }
    }

    private static func savePending(_ pending: [PendingFollowUp]) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        UserDefaults.standard.set(data, forKey: pendingKey)
    }

    static func notificationID(for doseID: UUID) -> String {
        "dose-followup-\(doseID.uuidString)"
    }
}
