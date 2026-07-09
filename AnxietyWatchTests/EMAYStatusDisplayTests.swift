import SwiftUI
import Testing

@testable import AnxietyWatch

/// Covers the `EMAYRealtimeService.Status` → display-text/color mapping used by
/// `EMAYLiveView`'s status row. Extracted from the view specifically so it can
/// be asserted here (per the project testing mandate for new behavior).
struct EMAYStatusDisplayTests {

    @Test("Each status maps to its expected label")
    func displayText() {
        #expect(EMAYRealtimeService.Status.idle.displayText == "Idle")
        #expect(EMAYRealtimeService.Status.scanning.displayText == "Scanning…")
        #expect(EMAYRealtimeService.Status.connecting.displayText == "Connecting…")
        #expect(EMAYRealtimeService.Status.streaming.displayText == "Streaming")
        #expect(EMAYRealtimeService.Status.bluetoothOff.displayText == "Bluetooth is off")
        #expect(EMAYRealtimeService.Status.bluetoothUnauthorized.displayText == "Bluetooth permission denied")
        #expect(EMAYRealtimeService.Status.bluetoothUnsupported.displayText == "Bluetooth unavailable")
    }

    @Test("A failure echoes its own message verbatim")
    func failedEchoesMessage() {
        #expect(EMAYRealtimeService.Status.failed("Connection lost").displayText == "Connection lost")
    }

    @Test("Color split matches BLE convention: green live, orange in-progress, red for BT/action-required")
    func displayColor() {
        #expect(EMAYRealtimeService.Status.streaming.displayColor == .green)
        // In-progress states are orange, matching HRVSessionLiveView.statusBadge.
        #expect(EMAYRealtimeService.Status.scanning.displayColor == .orange)
        #expect(EMAYRealtimeService.Status.connecting.displayColor == .orange)
        // Bluetooth action-required states and hard failures are red.
        #expect(EMAYRealtimeService.Status.bluetoothOff.displayColor == .red)
        #expect(EMAYRealtimeService.Status.bluetoothUnauthorized.displayColor == .red)
        #expect(EMAYRealtimeService.Status.bluetoothUnsupported.displayColor == .red)
        #expect(EMAYRealtimeService.Status.failed("boom").displayColor == .red)
        // Idle is neutral — no alarm color.
        #expect(EMAYRealtimeService.Status.idle.displayColor == .secondary)
    }
}
