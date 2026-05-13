import Foundation
import Testing

@testable import AnxietyWatch

/// Tests for the pure `ContentState.from(state:)` helper that maps a
/// `PolarHRMState` to a Live Activity ContentState (or nil when the
/// activity should be ended). Mirrors the in-app pill's
/// `RecordingPillContent.from(state:)` so the two surfaces stay in
/// sync — the user should see the same "recording vs connecting"
/// classification on the Lock Screen as in the in-app pill.
@Suite("HRVRecordingActivityAttributes.ContentState.from")
@MainActor
struct HRVRecordingActivityAttributesTests {

    private func state(
        status: PolarHRMState.Status,
        currentHR: Int? = nil
    ) -> PolarHRMState {
        let s = PolarHRMState()
        s.status = status
        s.currentHR = currentHR
        return s
    }

    @Test("returns nil for idle (activity should end / not exist)")
    func nilForIdle() {
        #expect(HRVRecordingActivityAttributes.ContentState.from(state: state(status: .idle)) == nil)
    }

    @Test("returns nil for scanning (no in-progress session)")
    func nilForScanning() {
        #expect(HRVRecordingActivityAttributes.ContentState.from(state: state(status: .scanning)) == nil)
    }

    @Test("returns nil for any error / unavailable state")
    func nilForErrorStates() {
        #expect(HRVRecordingActivityAttributes.ContentState.from(state: state(status: .bluetoothOff)) == nil)
        #expect(HRVRecordingActivityAttributes.ContentState.from(state: state(status: .bluetoothUnauthorized)) == nil)
        #expect(HRVRecordingActivityAttributes.ContentState.from(state: state(status: .bluetoothUnsupported)) == nil)
        #expect(HRVRecordingActivityAttributes.ContentState.from(state: state(status: .error("any"))) == nil)
    }

    @Test("returns a connecting ContentState before HR streams")
    func connectingHasNoHR() {
        let result = HRVRecordingActivityAttributes.ContentState.from(
            state: state(status: .connecting, currentHR: nil)
        )
        #expect(result?.statusText == "Connecting")
        #expect(result?.currentHRBPM == nil)
        #expect(result?.isLive == false)
    }

    @Test("suppresses HR during connecting even if the sensor streamed a beat early (parity with the in-app pill)")
    func connectingSuppressesEarlyHR() {
        let result = HRVRecordingActivityAttributes.ContentState.from(
            state: state(status: .connecting, currentHR: 62)
        )
        #expect(result?.statusText == "Connecting")
        #expect(result?.currentHRBPM == nil)
        #expect(result?.isLive == false)
    }

    @Test("returns a recording ContentState with HR when available")
    func recordingWithHR() {
        let result = HRVRecordingActivityAttributes.ContentState.from(
            state: state(status: .recording, currentHR: 62)
        )
        #expect(result?.statusText == "Recording")
        #expect(result?.currentHRBPM == 62)
        #expect(result?.isLive == true)
    }

    @Test("returns a recording ContentState with nil HR while sensor is warming up")
    func recordingNoHRYet() {
        let result = HRVRecordingActivityAttributes.ContentState.from(
            state: state(status: .recording, currentHR: nil)
        )
        #expect(result?.statusText == "Recording")
        #expect(result?.currentHRBPM == nil)
        #expect(result?.isLive == true)
    }
}
