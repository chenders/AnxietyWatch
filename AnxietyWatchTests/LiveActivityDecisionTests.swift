import Foundation
import Testing

@testable import AnxietyWatch

/// Tests for the pure `LiveActivityCoordinator.decide` helper —
/// extracted from the coordinator so its branching logic is testable
/// without standing up an `Activity<...>` instance. Each case maps a
/// (currentlyHosted, nextContent) pair to a `LiveActivityDecision`.
@Suite("LiveActivityCoordinator.decide")
struct LiveActivityDecisionTests {

    private let sample = HRVRecordingActivityAttributes.ContentState(
        currentHRBPM: 62,
        statusText: "Recording",
        isLive: true
    )

    @Test("no hosted activity + nil next → noOp (nothing to do)")
    func nothingToDo() {
        #expect(
            LiveActivityCoordinator.decide(currentlyHosted: false, nextContent: nil)
                == .noOp
        )
    }

    @Test("no hosted activity + non-nil next → startNew")
    func startsWhenNotHosted() {
        #expect(
            LiveActivityCoordinator.decide(currentlyHosted: false, nextContent: sample)
                == .startNew(sample)
        )
    }

    @Test("hosted activity + non-nil next → updateExisting")
    func updatesWhenHosted() {
        #expect(
            LiveActivityCoordinator.decide(currentlyHosted: true, nextContent: sample)
                == .updateExisting(sample)
        )
    }

    @Test("hosted activity + nil next → end")
    func endsWhenSessionDone() {
        #expect(
            LiveActivityCoordinator.decide(currentlyHosted: true, nextContent: nil)
                == .end
        )
    }

    @Test("decision is data-driven only — no implicit state lookups")
    func differentStatesProduceDifferentDecisions() {
        let connecting = HRVRecordingActivityAttributes.ContentState(
            currentHRBPM: nil,
            statusText: "Connecting",
            isLive: false
        )
        let recording = sample
        // The decision helper distinguishes content via the value, not
        // via the predicate. If currentlyHosted is the same, both
        // produce updateExisting with their respective payloads.
        #expect(
            LiveActivityCoordinator.decide(currentlyHosted: true, nextContent: connecting)
                == .updateExisting(connecting)
        )
        #expect(
            LiveActivityCoordinator.decide(currentlyHosted: true, nextContent: recording)
                == .updateExisting(recording)
        )
    }
}
