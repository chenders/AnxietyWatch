import Foundation
import Testing

@testable import AnxietyWatch

/// Tests for the pure `LiveActivityUpdateThrottle.shouldPush` helper.
/// HR updates fire at roughly 1 Hz once a session is active; throttling
/// to one Activity update every 10 seconds keeps us comfortably under
/// Apple's local-update budget while still feeling responsive on the
/// Lock Screen. Status transitions (e.g. connecting → recording)
/// bypass the throttle so the user sees them immediately.
@Suite("LiveActivityUpdateThrottle.shouldPush")
struct LiveActivityUpdateThrottleTests {

    private let referenceDate: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 5, day: 12, hour: 12))!
    }()

    private func state(
        currentHRBPM: Int? = 62,
        statusText: String = "Recording",
        isLive: Bool = true
    ) -> HRVRecordingActivityAttributes.ContentState {
        HRVRecordingActivityAttributes.ContentState(
            currentHRBPM: currentHRBPM,
            statusText: statusText,
            isLive: isLive
        )
    }

    @Test("first push is always allowed when there's no last update")
    func firstPushAlways() {
        let result = LiveActivityUpdateThrottle.shouldPush(
            now: referenceDate,
            lastPushedAt: nil,
            previousState: nil,
            nextState: state()
        )
        #expect(result == true)
    }

    @Test("within 10s of the last update, identical content is throttled")
    func throttledWithinWindow() {
        let last = state(currentHRBPM: 62)
        let next = state(currentHRBPM: 62)
        let result = LiveActivityUpdateThrottle.shouldPush(
            now: referenceDate.addingTimeInterval(5),
            lastPushedAt: referenceDate,
            previousState: last,
            nextState: next
        )
        #expect(result == false)
    }

    @Test("after 10s, an HR change pushes")
    func pushAfterWindow() {
        let last = state(currentHRBPM: 62)
        let next = state(currentHRBPM: 65)
        let result = LiveActivityUpdateThrottle.shouldPush(
            now: referenceDate.addingTimeInterval(11),
            lastPushedAt: referenceDate,
            previousState: last,
            nextState: next
        )
        #expect(result == true)
    }

    @Test("exactly at 10s boundary, an update pushes (>= threshold)")
    func pushAtBoundary() {
        let last = state(currentHRBPM: 62)
        let next = state(currentHRBPM: 65)
        let result = LiveActivityUpdateThrottle.shouldPush(
            now: referenceDate.addingTimeInterval(10),
            lastPushedAt: referenceDate,
            previousState: last,
            nextState: next
        )
        #expect(result == true)
    }

    @Test("status transition (Connecting → Recording) bypasses the throttle")
    func statusTransitionBypasses() {
        let last = state(statusText: "Connecting", isLive: false)
        let next = state(statusText: "Recording", isLive: true)
        let result = LiveActivityUpdateThrottle.shouldPush(
            now: referenceDate.addingTimeInterval(1),  // well inside the 10s window
            lastPushedAt: referenceDate,
            previousState: last,
            nextState: next
        )
        #expect(result == true)
    }

    @Test("identical content within window is throttled (no churn)")
    func identicalIsThrottled() {
        let s = state()
        let result = LiveActivityUpdateThrottle.shouldPush(
            now: referenceDate.addingTimeInterval(2),
            lastPushedAt: referenceDate,
            previousState: s,
            nextState: s
        )
        #expect(result == false)
    }

    @Test("HR change inside the throttle window does NOT push (must wait)")
    func hrChangeInWindowThrottled() {
        let last = state(currentHRBPM: 62)
        let next = state(currentHRBPM: 70)
        let result = LiveActivityUpdateThrottle.shouldPush(
            now: referenceDate.addingTimeInterval(3),
            lastPushedAt: referenceDate,
            previousState: last,
            nextState: next
        )
        #expect(result == false)
    }

    @Test("nil HR → non-nil HR (first reading) bypasses throttle as a status-like transition")
    func firstHRReadingBypasses() {
        let last = state(currentHRBPM: nil)
        let next = state(currentHRBPM: 62)
        let result = LiveActivityUpdateThrottle.shouldPush(
            now: referenceDate.addingTimeInterval(1),
            lastPushedAt: referenceDate,
            previousState: last,
            nextState: next
        )
        #expect(result == true)
    }
}
