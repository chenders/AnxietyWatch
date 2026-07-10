import Foundation
import UserNotifications

/// Local-notification side effect for sync outcomes, so a dead sync server
/// can't fail silently for a month again. Both sync paths — the manual
/// Sync Now / Full Re-sync buttons in `SyncSettingsView` and the Dashboard
/// auto-sync — run through `SyncService.shared.sync()`, whose
/// `outcomeHandler` calls `handle(outcome:)` after every completed run.
///
/// Policy per outcome:
/// - **failure** — notify, throttled to one per `throttleWindow` so an
///   auto-sync retry loop doesn't spam; the body admits when part of the
///   run committed before the failure. A failure also breaks any
///   consecutive-partial streak.
/// - **partial** — quiet when occasional, but a *persistent* run of
///   partials (a permanently failing flag flip re-uploading the same rows
///   forever) is the silent-failure mode relocated: after
///   `partialEscalationThreshold` consecutive partials, notify under the
///   same throttle.
/// - **success** — resets the throttle AND the partial streak, and clears
///   the delivered notification. Only a full success does this; a partial
///   must not re-arm the throttle it may be about to need.
///
/// The throttle/streak decisions and notification content are pure
/// (injected defaults + clock) and unit-tested; the
/// `UNUserNotificationCenter` calls are thin glue, untested by design.
/// Authorization rides the same shared plumbing as the random check-in
/// notifications (`LocalNotifications.ensureAuthorization`).
///
/// Not actor-isolated: `UNUserNotificationCenter` is thread-safe, and the
/// throttle helpers are pure over their injected `defaults` + `now`.
enum SyncFailureNotifier {
    /// Stable identifier: a newer failure notification replaces the previous
    /// one instead of stacking, and a success can clear the delivered one.
    static let notificationIdentifier = "sync-failure"
    static let lastNotifiedKey = "syncFailureNotify_lastNotifiedAt"
    static let partialStreakKey = "syncFailureNotify_partialStreak"
    /// At most one failure notification per this window.
    static let throttleWindow: TimeInterval = 12 * 60 * 60
    /// Consecutive `.partial` runs before the bookkeeping-failure
    /// notification posts. One or two partials are transient noise; three
    /// in a row means the flag flip is failing persistently.
    static let partialEscalationThreshold = 3

    static func handle(
        outcome: SyncRunOutcome,
        defaults: UserDefaults = .standard,
        now: Date = .now
    ) {
        // Exhaustive by design: a future outcome case must force a decision
        // here (notify? reset? escalate?) as a compile error, not silently
        // fall into a default arm.
        switch outcome {
        case .success:
            recordSuccess(defaults: defaults)
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])
        case .partial:
            guard recordPartialAndDecide(defaults: defaults, now: now) else { return }
            postNotification(title: escalationTitle, body: partialEscalationBody)
        case .failure(let kind, _, let madeProgress, _):
            // A failure breaks the *consecutive*-partial streak even when
            // the throttle suppresses its own notification.
            resetPartialStreak(defaults: defaults)
            guard recordFailureAndDecide(defaults: defaults, now: now) else { return }
            postNotification(
                title: notificationTitle,
                body: notificationBody(reason: kind.shortReason, madeProgress: madeProgress)
            )
        }
    }

    // MARK: - Throttle + streak state (pure given injected defaults + clock; tested)

    /// Whether a failure right now should post a notification, recording the
    /// post time when it should. One function for both the check and the
    /// record so the pair can't drift apart — a separated check/set invites
    /// two concurrent failures both passing the check.
    static func recordFailureAndDecide(defaults: UserDefaults, now: Date) -> Bool {
        guard shouldNotify(lastNotifiedAt: lastNotifiedAt(defaults: defaults), now: now) else {
            return false
        }
        defaults.set(now.timeIntervalSince1970, forKey: lastNotifiedKey)
        return true
    }

    /// Fused streak increment + escalation decision for a `.partial` run.
    /// Returns true when this partial is the `partialEscalationThreshold`-th
    /// (or later) consecutive one AND the shared 12h throttle allows a post
    /// — a persistent partial keeps re-notifying once per window until a
    /// full success clears it.
    static func recordPartialAndDecide(defaults: UserDefaults, now: Date) -> Bool {
        let streak = partialStreak(defaults: defaults) + 1
        defaults.set(streak, forKey: partialStreakKey)
        guard streak >= partialEscalationThreshold else { return false }
        return recordFailureAndDecide(defaults: defaults, now: now)
    }

    /// A full success re-arms everything: the next failure is fresh news
    /// and should notify immediately, and the partial streak starts over.
    static func recordSuccess(defaults: UserDefaults) {
        defaults.removeObject(forKey: lastNotifiedKey)
        resetPartialStreak(defaults: defaults)
    }

    static func resetPartialStreak(defaults: UserDefaults) {
        defaults.removeObject(forKey: partialStreakKey)
    }

    static func partialStreak(defaults: UserDefaults) -> Int {
        defaults.integer(forKey: partialStreakKey)
    }

    static func lastNotifiedAt(defaults: UserDefaults) -> Date? {
        let timestamp = defaults.double(forKey: lastNotifiedKey)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    /// Pure throttle rule: notify when never notified, when the window has
    /// elapsed, or when the recorded timestamp is in the future (clock
    /// rolled back / corrupt state — one extra notification beats a silent
    /// suppression that outlives the skew).
    static func shouldNotify(lastNotifiedAt: Date?, now: Date) -> Bool {
        guard let lastNotifiedAt else { return true }
        if lastNotifiedAt > now { return true }
        return now.timeIntervalSince(lastNotifiedAt) >= throttleWindow
    }

    // MARK: - Content (pure; tested)

    static let notificationTitle = "Sync failed"
    static let escalationTitle = "Sync needs attention"

    /// Honest body for a failed run. `madeProgress` (some round trips
    /// committed before the failure) softens the "data stays on this
    /// phone" claim — part of the run DID reach the server.
    static func notificationBody(reason: String, madeProgress: Bool) -> String {
        let tail = madeProgress
            ? "Some data uploaded before the failure; the rest stays on this phone until a sync succeeds."
            : "Data stays on this phone until a sync succeeds."
        return "AnxietyWatch sync failed: \(reason). \(tail)"
    }

    /// Honest body for a persistent partial: the server IS receiving data,
    /// so "sync failed / data stays on this phone" would be false — the
    /// problem is local bookkeeping wasting every sync on re-uploads.
    static let partialEscalationBody = "Sync is reaching the server, but local bookkeeping "
        + "keeps failing — the same data is re-uploading every sync."

    // MARK: - UNUserNotificationCenter glue (thin, untested by design)

    private static func postNotification(title: String, body: String) {
        LocalNotifications.ensureAuthorization()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // nil trigger delivers immediately.
        let request = UNNotificationRequest(
            identifier: notificationIdentifier, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
