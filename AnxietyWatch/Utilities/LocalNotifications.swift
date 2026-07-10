import UserNotifications

/// Shared local-notification authorization plumbing. Extracted from the
/// identical bodies in `RandomCheckInManager` / `DoseFollowUpManager` so
/// every local-notification producer (check-ins, dose follow-ups,
/// sync-failure alerts) rides one request path instead of duplicating
/// center calls.
enum LocalNotifications {
    /// Request notification permission if not already determined. Safe to
    /// call repeatedly — the system prompt only ever appears once.
    static func ensureAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
}
