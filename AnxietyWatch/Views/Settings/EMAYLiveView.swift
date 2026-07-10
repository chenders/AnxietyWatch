import SwiftData
import SwiftUI

/// Live SpO₂ / pulse readout from the EMAY SleepO2 oximeter over BLE.
/// Consumes the app-scoped `EMAYRealtimeService` (injected in
/// `AnxietyWatchApp` — the device supports one central connection, so the
/// service must have exactly one owner). Session lifecycle: starts on
/// appear; stops on disappear ONLY when continuous streaming is off —
/// in continuous mode the session outlives this screen (and the app's
/// foreground lifetime). This is the verification surface for the real-time
/// source the CNS-depression early-warning monitor will consume; it is NOT
/// a medical device.
struct EMAYLiveView: View {
    @Environment(EMAYRealtimeService.self) private var service

    /// Only the genuinely-active states count as "running" for the button.
    /// Terminal/error states (`.idle`, `.failed`, `.bluetoothOff`, etc.) must
    /// show "Start" so the button doesn't offer a no-op "Stop" that would
    /// discard the informative status message and force a second tap.
    /// Delegates to `Status.isActiveSession` so this stays in lockstep with
    /// the service's own re-entrancy guard.
    private var isRunning: Bool { service.status.isActiveSession }

    /// Two-way bridge for the continuous-streaming toggle: the service owns
    /// the value (UserDefaults-backed) and the start/stop side effects.
    private var continuousStreaming: Binding<Bool> {
        Binding(
            get: { service.continuousModeEnabled },
            set: { service.setContinuousMode($0) }
        )
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

            Section {
                Toggle("Continuous streaming", isOn: continuousStreaming)
            } footer: {
                Text("Keeps listening for the oximeter and records whenever it's in range, "
                    + "including in the background and across app restarts. Uses more battery. "
                    + "Stop ends the current session; monitoring re-arms at the next launch while this is on.")
            }
        }
        .navigationTitle("EMAY Oximeter")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { service.start() }
        .onDisappear {
            // In continuous mode the session deliberately outlives this
            // screen — only an explicit Stop or the toggle ends it.
            if !service.continuousModeEnabled { service.stop() }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack {
            Label("Status", systemImage: "dot.radiowaves.left.and.right")
            Spacer()
            if service.status == .scanning || service.status == .connecting
                || service.status == .waitingForDevice {
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
        case .waitingForDevice: return "Waiting for oximeter…"
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
        case .scanning, .waitingForDevice, .connecting: return .orange
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
