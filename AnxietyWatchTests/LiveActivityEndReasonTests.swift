import Foundation
import Testing

@testable import AnxietyWatch

/// Tests for the pure `LiveActivityCoordinator.isUnexpectedEnd` helper.
/// "Unexpected" determines whether ending a Live Activity should also
/// fire a banner alert (so a user with the phone in their pocket gets
/// a heads-up that their session dropped) vs. silently ending (when
/// the user themselves tapped Stop).
@Suite("LiveActivityCoordinator.isUnexpectedEnd")
@MainActor
struct LiveActivityEndReasonTests {

    @Test("idle is user-initiated (Stop tapped) — not unexpected")
    func idleIsExpected() {
        #expect(LiveActivityCoordinator.isUnexpectedEnd(status: .idle) == false)
    }

    @Test("scanning is between sessions — not unexpected")
    func scanningIsExpected() {
        #expect(LiveActivityCoordinator.isUnexpectedEnd(status: .scanning) == false)
    }

    @Test("error state is unexpected (BLE drop, sensor fault, etc.)")
    func errorIsUnexpected() {
        #expect(LiveActivityCoordinator.isUnexpectedEnd(status: .error("any reason")) == true)
    }

    @Test("Bluetooth-off is unexpected (the user turned BT off mid-session)")
    func bluetoothOffIsUnexpected() {
        #expect(LiveActivityCoordinator.isUnexpectedEnd(status: .bluetoothOff) == true)
    }

    @Test("Bluetooth-unauthorized is unexpected (permission revoked)")
    func bluetoothUnauthorizedIsUnexpected() {
        #expect(LiveActivityCoordinator.isUnexpectedEnd(status: .bluetoothUnauthorized) == true)
    }

    @Test("Bluetooth-unsupported is unexpected (rare; should never happen mid-session but defensively classify)")
    func bluetoothUnsupportedIsUnexpected() {
        #expect(LiveActivityCoordinator.isUnexpectedEnd(status: .bluetoothUnsupported) == true)
    }

    @Test("connecting / recording are not end states — predicate returns false (not unexpected, because not ending)")
    func runningStatesAreNotUnexpected() {
        #expect(LiveActivityCoordinator.isUnexpectedEnd(status: .connecting) == false)
        #expect(LiveActivityCoordinator.isUnexpectedEnd(status: .recording) == false)
    }
}
