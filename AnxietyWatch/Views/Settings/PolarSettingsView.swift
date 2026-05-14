import SwiftUI

struct PolarSettingsView: View {
    @Environment(PolarHRMService.self) private var polarService
    @Environment(RecordingPresentationCoordinator.self) private var recordingPresentation
    @State private var showingPairing = false

    var body: some View {
        Form {
            Section {
                let state = polarService.state
                if polarService.isPaired {
                    // Use the persisted name when present; fall back to a generic
                    // label so a corrupted-or-missing `pairedDeviceName` doesn't
                    // make the UI claim "Unpaired" while the underlying UUID is
                    // still on disk (and startSession would still connect).
                    let displayName = state.pairedDeviceName ?? "Polar H10"
                    LabeledContent("Paired", value: displayName)
                    switch state.status {
                    case .recording, .connecting:
                        Button {
                            recordingPresentation.showingLiveView = true
                        } label: {
                            Label("Resume Live View", systemImage: "waveform.path.ecg")
                        }
                        Button(role: .destructive) {
                            polarService.stopSession()
                        } label: {
                            Label("Stop Session", systemImage: "stop.circle.fill")
                        }
                    case .bluetoothOff:
                        Label("Bluetooth Off", systemImage: "antenna.radiowaves.left.and.right.slash")
                            .foregroundStyle(.red)
                        Text("Enable Bluetooth in iOS Settings, then return here to start a session.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            polarService.unpair()
                        } label: {
                            Label("Unpair", systemImage: "xmark.circle")
                        }
                    case .bluetoothUnauthorized:
                        Label("Bluetooth Permission Needed", systemImage: "lock.shield")
                            .foregroundStyle(.red)
                        Text("Allow Bluetooth access for Anxiety Watch in iOS Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            polarService.unpair()
                        } label: {
                            Label("Unpair", systemImage: "xmark.circle")
                        }
                    case .bluetoothUnsupported:
                        Label("Bluetooth Not Available", systemImage: "antenna.radiowaves.left.and.right.slash")
                            .foregroundStyle(.red)
                        Text("This device doesn't support Bluetooth Low Energy (the iOS Simulator falls into this case).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            polarService.unpair()
                        } label: {
                            Label("Unpair", systemImage: "xmark.circle")
                        }
                    case .error(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Button {
                            polarService.startSession()
                            // Only present the live sheet on a successful
                            // transition — startSession may synchronously bounce
                            // to .bluetoothOff / .error if preconditions aren't
                            // met, in which case inline status already shows.
                            if case .connecting = polarService.state.status { recordingPresentation.showingLiveView = true }
                            else if case .recording = polarService.state.status { recordingPresentation.showingLiveView = true }
                        } label: {
                            Label("Retry Start", systemImage: "arrow.clockwise")
                        }
                        Button(role: .destructive) {
                            polarService.unpair()
                        } label: {
                            Label("Unpair", systemImage: "xmark.circle")
                        }
                    case .idle, .scanning:
                        Button {
                            polarService.startSession()
                            if case .connecting = polarService.state.status { recordingPresentation.showingLiveView = true }
                            else if case .recording = polarService.state.status { recordingPresentation.showingLiveView = true }
                        } label: {
                            Label("Start HRV Session", systemImage: "heart.text.square.fill")
                        }
                        Button(role: .destructive) {
                            polarService.unpair()
                        } label: {
                            Label("Unpair", systemImage: "xmark.circle")
                        }
                    }
                } else {
                    Button {
                        showingPairing = true
                    } label: {
                        Label("Pair Polar H10", systemImage: "heart.text.square")
                    }
                }
            } footer: {
                Text("High-fidelity HRV via Bluetooth chest strap. Wear the strap moistened; close Polar Flow before pairing.")
            }
        }
        .navigationTitle("Polar H10")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPairing) {
            PolarPairingView(service: polarService)
        }
    }
}
