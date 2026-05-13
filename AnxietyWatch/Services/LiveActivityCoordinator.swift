import ActivityKit
import Foundation
import Observation
import os.log

/// Pure-function output of the coordinator's branching decision —
/// extracted so the start / update / end / noop cases are testable
/// without ActivityKit. The coordinator executes the decision; this
/// type holds zero ActivityKit references.
enum LiveActivityDecision: Equatable {
    case noOp
    /// Start a brand-new activity with this attributes / state pair.
    case startNew(HRVRecordingActivityAttributes.ContentState)
    /// Update the running activity with this state (subject to the
    /// caller's throttle check, which is also tested independently).
    case updateExisting(HRVRecordingActivityAttributes.ContentState)
    /// End the running activity — either because there is no in-progress
    /// session anymore, or because the previous activity was dismissed
    /// by the user and we want to clear local bookkeeping.
    case end
}

/// Drives the Lock Screen + Dynamic Island Live Activity for an in-
/// progress Polar H10 session. Subscribes to `PolarHRMService.state`
/// via the SwiftUI Observation framework's re-arming pattern; on each
/// state change, decides whether to request a new Activity, update
/// the existing one (subject to `LiveActivityUpdateThrottle`), or end
/// it.
///
/// Decoupled from `PolarHRMService` so the BLE service can stay
/// narrowly focused on Bluetooth + recording mechanics. The
/// coordinator can be omitted from a build (e.g. for a target that
/// excludes ActivityKit) without touching the service.
@MainActor
@Observable
final class LiveActivityCoordinator {
    private let polarService: PolarHRMService
    private var currentActivity: Activity<HRVRecordingActivityAttributes>?
    private var lastPushedAt: Date?
    private var lastPushedState: HRVRecordingActivityAttributes.ContentState?

    /// Soft staleness window. If the system hasn't received an update
    /// within this interval the Activity is marked stale and rendered
    /// as such — preventing the Lock Screen from showing an hours-old
    /// HR value after a Bluetooth disconnect mid-session. Set generously
    /// relative to the 10s update throttle so legitimate updates always
    /// land before staleness fires.
    static let staleAfter: TimeInterval = 60

    private static let log = Logger(
        subsystem: "com.groundeffectsoftware.AnxietyWatch",
        category: "LiveActivityCoordinator"
    )

    init(polarService: PolarHRMService) {
        self.polarService = polarService
        // Respond to whatever state we observe at construction (covers
        // the rare case where a session is already in flight when the
        // coordinator is created — e.g. background-launched after
        // state restoration). Subsequent changes flow through the
        // re-arming observation below.
        respond(to: polarService.state)
        startObserving()
    }

    /// Whether the activity is considered hosted from the coordinator's
    /// perspective: non-nil and not in a terminal state. ActivityKit
    /// can dismiss / end an activity out from under us (user dismisses
    /// from Lock Screen, system reclaims it for resources, etc.); this
    /// predicate reconciles our reference against the OS truth so a
    /// subsequent session can correctly call `startNew` rather than
    /// trying to `updateExisting` a corpse.
    private var hasHostedActivity: Bool {
        guard let a = currentActivity else { return false }
        switch a.activityState {
        // `.pending` (iOS 16.2+): system accepted Activity.request but
        // hasn't yet rendered the activity; treat as hosted so we
        // don't start a duplicate.
        case .active, .stale, .pending: return true
        case .dismissed, .ended: return false
        @unknown default: return false
        }
    }

    /// Pure decision helper — extracted from the coordinator so the
    /// start / update / end branches are testable without ActivityKit.
    /// `nextContent` is the result of `ContentState.from(state:)` (nil
    /// when the activity should end). `currentlyHosted` mirrors the
    /// coordinator's `hasHostedActivity` predicate.
    static func decide(
        currentlyHosted: Bool,
        nextContent: HRVRecordingActivityAttributes.ContentState?
    ) -> LiveActivityDecision {
        switch (currentlyHosted, nextContent) {
        case (true, let next?):
            return .updateExisting(next)
        case (false, let next?):
            return .startNew(next)
        case (true, nil):
            return .end
        case (false, nil):
            return .noOp
        }
    }

    /// True when this status represents a session ending that the user
    /// didn't initiate (BLE drop, hardware fault, permission revoked
    /// mid-session). Used to decide whether to fire a banner alert
    /// when ending the Live Activity — silent end for user-initiated
    /// stops (.idle), audible heads-up for everything else where the
    /// user probably didn't realize the session dropped.
    static func isUnexpectedEnd(status: PolarHRMState.Status) -> Bool {
        switch status {
        case .error, .bluetoothOff, .bluetoothUnauthorized, .bluetoothUnsupported:
            return true
        case .idle, .scanning, .connecting, .recording:
            return false
        }
    }

    /// SwiftUI `Observation` framework re-arming pattern. The
    /// `onChange` callback **fires off-main** on the thread that
    /// mutated the observed property — we re-hop to `@MainActor` via
    /// the `Task` body. `[weak self]` is only needed on that Task
    /// (long-lived); the outer `apply` / `onChange` closures are
    /// short-lived one-shots that the framework discards after the
    /// notification fires.
    private func startObserving() {
        withObservationTracking {
            _ = polarService.state.status
            _ = polarService.state.currentHR
            _ = polarService.state.sessionStarted
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.respond(to: self.polarService.state)
                self.startObserving()
            }
        }
    }

    private func respond(to state: PolarHRMState) {
        // ActivityAuthorizationInfo().areActivitiesEnabled is the
        // user-facing setting in Settings → AnxietyWatch → Live
        // Activities. If the user toggles it off mid-session, end
        // any currently-running activity rather than leaving it
        // visible — the setting flip is an explicit "I do not want
        // to see this" signal that should be honored. Recording
        // itself proceeds normally; the in-app pill remains the
        // source of truth. Silent end (no alert) because the user
        // initiated this change themselves.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            endRunningSilently()
            return
        }

        // If our stored activity reference is for an activity the OS
        // has already dismissed or ended, clear our local bookkeeping
        // first so the decision below correctly chooses `startNew`
        // for a subsequent session rather than `updateExisting` on a
        // dead handle.
        if currentActivity != nil, !hasHostedActivity {
            currentActivity = nil
            lastPushedAt = nil
            lastPushedState = nil
        }

        let nextContent = HRVRecordingActivityAttributes.ContentState.from(state: state)
        let decision = Self.decide(currentlyHosted: hasHostedActivity, nextContent: nextContent)

        switch decision {
        case .noOp:
            return
        case .startNew(let content):
            startActivity(state: state, content: content)
        case .updateExisting(let content):
            maybeUpdateActivity(nextContent: content)
        case .end:
            endRunning(triggeredBy: state.status)
        }
    }

    private func startActivity(
        state: PolarHRMState,
        content: HRVRecordingActivityAttributes.ContentState
    ) {
        let attributes = HRVRecordingActivityAttributes(
            // `sessionStarted` is non-nil once recording begins; during
            // the connecting phase it may be nil, so fall back to .now
            // (~the moment the user tapped Start). The Lock Screen
            // timer reads as "time since I tapped Start," which is the
            // mental model the user has anyway.
            sessionStartedAt: state.sessionStarted ?? Date()
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(
                    state: content,
                    staleDate: Date().addingTimeInterval(Self.staleAfter)
                )
            )
            currentActivity = activity
            lastPushedAt = Date()
            lastPushedState = content
        } catch {
            Self.log.error("Live Activity request failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func maybeUpdateActivity(
        nextContent: HRVRecordingActivityAttributes.ContentState
    ) {
        let now = Date()
        let shouldPush = LiveActivityUpdateThrottle.shouldPush(
            now: now,
            lastPushedAt: lastPushedAt,
            previousState: lastPushedState,
            nextState: nextContent
        )
        guard shouldPush, let activity = currentActivity else { return }
        // Activity.update is async — fire-and-forget. We don't await
        // because the observation-tracking re-arm is already returning
        // synchronously and any error is non-actionable here.
        Task {
            await activity.update(
                ActivityContent(
                    state: nextContent,
                    staleDate: Date().addingTimeInterval(Self.staleAfter)
                )
            )
        }
        lastPushedAt = now
        lastPushedState = nextContent
    }

    private func endRunning(triggeredBy endStatus: PolarHRMState.Status) {
        guard let activity = currentActivity else { return }
        // `currentActivity = nil` happens synchronously before the
        // detached Task body runs. If BLE drops and re-establishes
        // within the 3-second alert-display window, `respond()` will
        // see no hosted activity and call `startNew` while the old
        // activity is still mid-end. This is safe — each `Activity`
        // handle is independent and ActivityKit ends them separately,
        // so the captured `activity` local here always references the
        // outgoing handle, not whatever new one might be hosted by
        // the time `.end(...)` runs. The user briefly sees two pills
        // (the outgoing "Disconnected" alert and the incoming
        // "Recording") which is a faithful description of what just
        // happened. A stricter restructure (deferring the nil-out
        // until the Task completes, plus an "isEnding" flag respected
        // by maybeUpdateActivity) would suppress the visual overlap
        // but is not worth the added state for a rare edge case.
        currentActivity = nil
        lastPushedAt = nil
        lastPushedState = nil

        if Self.isUnexpectedEnd(status: endStatus) {
            // Fire a banner alert so a user with the phone in their
            // pocket (or in another app) gets a heads-up that their
            // session unexpectedly stopped. Push a final "Disconnected"
            // ContentState so the Lock Screen briefly reads as ended
            // rather than freezing on the last live values, then end.
            let disconnected = HRVRecordingActivityAttributes.ContentState(
                currentHRBPM: nil,
                statusText: "Disconnected",
                isLive: false
            )
            Task {
                await activity.update(
                    ActivityContent(
                        state: disconnected,
                        staleDate: Date().addingTimeInterval(Self.staleAfter)
                    ),
                    alertConfiguration: AlertConfiguration(
                        title: "Recording stopped",
                        body: "Polar H10 disconnected",
                        sound: .default
                    )
                )
                // Brief delay so the alert/banner registers before the
                // activity vanishes. The end uses .default policy so
                // the activity dismisses according to system behavior
                // (~4 hours by default if the user doesn't dismiss it
                // manually).
                try? await Task.sleep(for: .seconds(3))
                await activity.end(nil, dismissalPolicy: .default)
            }
        } else {
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Ends any currently-running activity without firing a banner
    /// alert. Used when the user disables Live Activities mid-session
    /// (the setting flip is itself the user's intent to silence the
    /// surface) and as the building block of the
    /// non-unexpected-end branch of `endRunning(triggeredBy:)`.
    private func endRunningSilently() {
        guard let activity = currentActivity else { return }
        currentActivity = nil
        lastPushedAt = nil
        lastPushedState = nil
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
