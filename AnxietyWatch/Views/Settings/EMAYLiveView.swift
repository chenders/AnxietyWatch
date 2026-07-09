import SwiftData
import SwiftUI

/// Live SpO₂ / pulse readout from the EMAY SleepO2 oximeter over BLE.
/// Consumes the app-scoped `EMAYRealtimeService` (injected in
/// `AnxietyWatchApp` — the device supports one central connection, so the
/// service must have exactly one owner) but keeps the session lifecycle:
/// scans/streams on appear, stops on disappear. This is the verification
/// surface for the real-time source the CNS-depression early-warning monitor
/// will consume; it is NOT a medical device.
struct EMAYLiveView: View {
    @Environment(EMAYRealtimeService.self) private var service

    /// Only the genuinely-active states count as "running" for the toggle.
    /// Terminal/error states (`.idle`, `.failed`, `.bluetoothOff`, etc.) must
    /// show "Start" so the button doesn't offer a no-op "Stop" that would
    /// discard the informative status message and force a second tap.
    private var isRunning: Bool {
        switch service.status {
        case .scanning, .connecting, .streaming: return true
        default: return false
        }
    }

    var body: some View {
        List {
            Section { statusRow }

            Section("Live reading") {
                LabeledContent {
                    Text(service.latestReading?.spo2.map { "\($0)%" } ?? "—")
                        .font(.title2.bold().monospacedDigit())
                        .foregroundStyle(service.latestReading?.hasSpO2 == true ? .primary : .secondary)
                } label: {
                    Label("SpO₂", systemImage: "lungs.fill")
                }
                LabeledContent {
                    Text(service.latestReading?.pulseRate.map { "\($0) bpm" } ?? "—")
                        .font(.title2.bold().monospacedDigit())
                        .foregroundStyle(service.latestReading?.hasPulse == true ? .primary : .secondary)
                } label: {
                    Label("Pulse", systemImage: "heart.fill")
                }
            }

            Section {
                Button {
                    isRunning ? service.stop() : service.start()
                } label: {
                    Label(isRunning ? "Stop" : "Start", systemImage: isRunning ? "stop.circle" : "play.circle")
                }
            } footer: {
                Text("Put a finger on the sensor; values stream about once a second while connected. "
                    + "This is an early-warning data source, not a medical device — don't rely on it for diagnosis.")
            }
        }
        .navigationTitle("EMAY Oximeter")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { service.start() }
        .onDisappear { service.stop() }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack {
            Label("Status", systemImage: "dot.radiowaves.left.and.right")
            Spacer()
            if service.status == .scanning || service.status == .connecting {
                ProgressView().controlSize(.small)
            }
            Text(service.status.displayText)
                .foregroundStyle(service.status.displayColor)
        }
    }
}

extension EMAYRealtimeService.Status {
    /// Human-readable label for the status row. `.failed` echoes its own
    /// message verbatim. Extracted from the view (and out of a `private`
    /// computed property) so the mapping is unit-testable.
    var displayText: String {
        switch self {
        case .idle: return "Idle"
        case .scanning: return "Scanning…"
        case .connecting: return "Connecting…"
        case .streaming: return "Streaming"
        case .failed(let message): return message
        case .bluetoothOff: return "Bluetooth is off"
        case .bluetoothUnauthorized: return "Bluetooth permission denied"
        case .bluetoothUnsupported: return "Bluetooth unavailable"
        }
    }

    /// Semantic color for the status row, matching the app's BLE status
    /// convention (see `HRVSessionLiveView.statusBadge`): green = live,
    /// orange = in-progress, red = failure or an action-required Bluetooth
    /// state, secondary = neutral.
    var displayColor: Color {
        switch self {
        case .streaming: return .green
        case .scanning, .connecting: return .orange
        case .idle: return .secondary
        case .failed, .bluetoothUnsupported, .bluetoothOff, .bluetoothUnauthorized: return .red
        }
    }
}

#if DEBUG
#Preview {
    let container = try! PreviewHelpers.makeFullContainer()
    NavigationStack { EMAYLiveView() }
        .environment(EMAYRealtimeService(modelContext: ModelContext(container)))
        .modelContainer(container)
}
#endif
