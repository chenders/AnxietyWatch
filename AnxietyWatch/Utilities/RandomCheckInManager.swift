import Foundation
import UserNotifications

/// Schedules random mood check-in notifications during waking hours.
/// Follows the same persistence pattern as DoseFollowUpManager.
enum RandomCheckInManager {

    private static let enabledKey = "randomCheckIn_enabled"
    private static let frequencyKey = "randomCheckIn_frequencyPerDay"
    private static let quietStartKey = "randomCheckIn_quietHoursStart"
    private static let quietEndKey = "randomCheckIn_quietHoursEnd"
    private static let pendingKey = "randomCheckIn_pending"
    private static let staleThreshold: TimeInterval = 24 * 60 * 60

    struct PendingCheckIn: Codable, Equatable {
        let notificationId: String
        let scheduledTime: Date
    }

    // MARK: - Settings

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var frequencyPerDay: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: frequencyKey)
            return v > 0 ? v : 2
        }
        set { UserDefaults.standard.set(newValue, forKey: frequencyKey) }
    }

    static var quietHoursStart: Int {
        get {
            let v = UserDefaults.standard.object(forKey: quietStartKey) as? Int
            return v ?? 22
        }
        set { UserDefaults.standard.set(newValue, forKey: quietStartKey) }
    }

    static var quietHoursEnd: Int {
        get {
            let v = UserDefaults.standard.object(forKey: quietEndKey) as? Int
            return v ?? 8
        }
        set { UserDefaults.standard.set(newValue, forKey: quietEndKey) }
    }

    /// Convenience: active hours start = when quiet hours end (default 8 AM)
    static var activeHoursStart: Int {
        get { quietHoursEnd }
        set { quietHoursEnd = newValue }
    }

    /// Convenience: active hours end = when quiet hours start (default 10 PM)
    static var activeHoursEnd: Int {
        get { quietHoursStart }
        set { quietHoursStart = newValue }
    }

    // MARK: - Notification Authorization

    static func ensureAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Scheduling

    static func scheduleNextCheckIn(from now: Date = .now) {
        guard isEnabled else { return }

        let targetTime = nextRandomTime(from: now)
        let delay = targetTime.timeIntervalSince(now)
        guard delay > 0 else { return }

        let id = "random-checkin-\(UUID().uuidString)"
        let pending = PendingCheckIn(notificationId: id, scheduledTime: targetTime)
        savePending(pending)

        let content = UNMutableNotificationContent()
        content.title = "How are you feeling?"
        content.body = "Quick check-in — tap to log"
        content.sound = .default
        content.categoryIdentifier = "RANDOM_CHECKIN"

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: delay,
            repeats: false
        )

        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)

        updateWatchContext(pending: true)
    }

    // MARK: - Foreground Check

    static func pendingCheckInIfDue(now: Date = .now) -> Bool {
        guard let pending = loadPending() else { return false }
        return pending.scheduledTime <= now &&
               now.timeIntervalSince(pending.scheduledTime) < staleThreshold
    }

    static func completeCheckIn() {
        if let pending = loadPending() {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [pending.notificationId])
            center.removeDeliveredNotifications(withIdentifiers: [pending.notificationId])
        }
        clearPending()
        updateWatchContext(pending: false)
        scheduleNextCheckIn()
    }

    static func dismissCheckIn() {
        completeCheckIn()
    }

    static func cancelAll() {
        if let pending = loadPending() {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [pending.notificationId])
            center.removeDeliveredNotifications(withIdentifiers: [pending.notificationId])
        }
        clearPending()
        updateWatchContext(pending: false)
    }

    static func cleanupStale(now: Date = .now) {
        guard let pending = loadPending() else { return }
        if now.timeIntervalSince(pending.scheduledTime) >= staleThreshold {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [pending.notificationId])
            center.removeDeliveredNotifications(withIdentifiers: [pending.notificationId])
            clearPending()
            scheduleNextCheckIn(from: now)
        }
    }

    // MARK: - Randomization

    static func nextRandomTime(
        from now: Date = .now,
        frequency: Int? = nil,
        quietStart: Int? = nil,
        quietEnd: Int? = nil
    ) -> Date {
        let calendar = Calendar.current
        let freq = frequency ?? frequencyPerDay
        let qStart = quietStart ?? quietHoursStart
        let qEnd = quietEnd ?? quietHoursEnd

        let wakeStart = qEnd * 60
        let wakeEnd = qStart * 60
        let wakingMinutes = wakeEnd - wakeStart
        guard wakingMinutes > 0, freq > 0 else {
            return calendar.date(byAdding: .day, value: 1,
                to: calendar.date(bySettingHour: qEnd, minute: 0, second: 0, of: now)!)!
        }

        let slotSize = wakingMinutes / freq
        let todayStart = calendar.startOfDay(for: now)
        let minutesSinceMidnight = calendar.dateComponents([.hour, .minute], from: now)
        let currentMinute = (minutesSinceMidnight.hour ?? 0) * 60 + (minutesSinceMidnight.minute ?? 0)

        for slot in 0..<freq {
            let slotStart = wakeStart + slot * slotSize
            let slotEnd = slotStart + slotSize

            if currentMinute < slotEnd {
                let effectiveStart = max(slotStart, currentMinute + 1)
                guard effectiveStart < slotEnd else { continue } // slot exhausted, try next
                let randomMinute = Int.random(in: effectiveStart..<slotEnd)
                return calendar.date(byAdding: .minute, value: randomMinute, to: todayStart)!
            }
        }

        let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart)!
        let randomMinute = Int.random(in: wakeStart..<(wakeStart + slotSize))
        return calendar.date(byAdding: .minute, value: randomMinute, to: tomorrow)!
    }

    // MARK: - Persistence

    static func loadPending() -> PendingCheckIn? {
        guard let data = UserDefaults.standard.data(forKey: pendingKey) else { return nil }
        return try? JSONDecoder().decode(PendingCheckIn.self, from: data)
    }

    private static func savePending(_ pending: PendingCheckIn) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        UserDefaults.standard.set(data, forKey: pendingKey)
    }

    private static func clearPending() {
        UserDefaults.standard.removeObject(forKey: pendingKey)
    }

    // MARK: - Watch Context

    private static func updateWatchContext(pending: Bool) {
        PhoneConnectivityManager.shared.updateCheckInContext(pending: pending)
    }
}
