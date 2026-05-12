import Foundation
import Testing

@testable import AnxietyWatch

/// Tests for the pure `pillContent(state:)` helper that decides whether
/// the recording status pill should be visible and, if so, what strings
/// it should display. Used by both the in-app pill and the Live
/// Activity. Pulling the logic out of the SwiftUI view keeps the
/// state-machine branches testable without standing up a view hierarchy.
@Suite("RecordingPillContent")
@MainActor
struct RecordingPillContentTests {

    private func state(
        status: PolarHRMState.Status,
        currentHR: Int? = nil,
        sessionStarted: Date? = nil,
        sessionElapsed: TimeInterval = 0
    ) -> PolarHRMState {
        let s = PolarHRMState()
        s.status = status
        s.currentHR = currentHR
        s.sessionStarted = sessionStarted
        s.sessionElapsed = sessionElapsed
        return s
    }

    // MARK: - Visibility gating

    @Test("hidden when idle")
    func hiddenWhenIdle() {
        #expect(RecordingPillContent.from(state: state(status: .idle)) == nil)
    }

    @Test("hidden when scanning")
    func hiddenWhenScanning() {
        #expect(RecordingPillContent.from(state: state(status: .scanning)) == nil)
    }

    @Test("hidden in any error or unavailable state")
    func hiddenInErrorStates() {
        #expect(RecordingPillContent.from(state: state(status: .bluetoothOff)) == nil)
        #expect(RecordingPillContent.from(state: state(status: .bluetoothUnauthorized)) == nil)
        #expect(RecordingPillContent.from(state: state(status: .bluetoothUnsupported)) == nil)
        #expect(RecordingPillContent.from(state: state(status: .error("any"))) == nil)
    }

    @Test("visible when connecting")
    func visibleWhenConnecting() {
        let result = RecordingPillContent.from(state: state(status: .connecting))
        #expect(result != nil)
        #expect(result?.statusText == "Connecting")
        #expect(result?.isLive == false)
        // Connecting has no session yet → no elapsed/HR
        #expect(result?.elapsedText == nil)
        #expect(result?.hrText == nil)
    }

    @Test("visible when recording")
    func visibleWhenRecording() {
        let result = RecordingPillContent.from(
            state: state(
                status: .recording,
                currentHR: 62,
                sessionStarted: Date(timeIntervalSince1970: 1_700_000_000),
                sessionElapsed: 754
            )
        )
        #expect(result != nil)
        #expect(result?.statusText == "Recording")
        #expect(result?.isLive == true)
        #expect(result?.elapsedText == "12:34")
        #expect(result?.hrText == "62 BPM")
    }

    // MARK: - HR / elapsed presence

    @Test("recording without current HR yields nil hrText (sensor warming up)")
    func recordingNoHRYet() {
        let result = RecordingPillContent.from(
            state: state(status: .recording, currentHR: nil, sessionStarted: Date(), sessionElapsed: 5)
        )
        #expect(result?.hrText == nil)
        #expect(result?.elapsedText == "0:05")
    }

    @Test("recording with zero elapsed still shows 0:00 (session just started)")
    func recordingZeroElapsed() {
        let result = RecordingPillContent.from(
            state: state(status: .recording, currentHR: 70, sessionStarted: Date(), sessionElapsed: 0)
        )
        #expect(result?.elapsedText == "0:00")
        #expect(result?.hrText == "70 BPM")
    }

    @Test("multi-hour elapsed gets H:MM:SS formatting (delegates to RecordingFormatters)")
    func recordingMultiHour() {
        let result = RecordingPillContent.from(
            state: state(status: .recording, currentHR: 58, sessionStarted: Date(), sessionElapsed: 18_192)
        )
        #expect(result?.elapsedText == "5:03:12")
    }
}
