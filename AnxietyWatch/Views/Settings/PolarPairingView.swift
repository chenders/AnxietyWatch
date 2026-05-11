// AnxietyWatch/Views/Settings/PolarPairingView.swift
import SwiftUI

/// First-time pairing flow: scans for peripherals advertising the standard
/// Heart Rate Service (0x180D), lets the user pick one, persists the UUID
/// via `PolarHRMService.pair(_:)`, then dismisses.
struct PolarPairingView: View {
    let service: PolarHRMService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let state = service.state
        NavigationStack {
            // Body branches are factored into @ViewBuilder helpers because
            // CI's Xcode 16.4 chokes on `Group { switch }` with mixed view
            // types in a way newer Xcodes don't (the compiler misattributes
            // the failure as a MapContentBuilder error). Helpers sidestep
            // that without changing semantics.
            content(for: state)
            .navigationTitle("Pair Polar H10")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        service.stopScan()
                        dismiss()
                    }
                }
            }
            .onAppear {
                service.startScan()
            }
            .onDisappear {
                service.stopScan()
            }
        }
    }

    @ViewBuilder
    private func content(for state: PolarHRMState) -> some View {
        switch state.status {
        case .bluetoothOff:
            ContentUnavailableView(
                "Bluetooth Off",
                systemImage: "antenna.radiowaves.left.and.right.slash",
                description: Text("Turn Bluetooth on in iOS Settings, then come back here.")
            )
        case .bluetoothUnauthorized:
            ContentUnavailableView(
                "Bluetooth Permission Needed",
                systemImage: "lock.shield",
                description: Text("Allow Bluetooth access in iOS Settings → Anxiety Watch, then return here to pair.")
            )
        case .bluetoothUnsupported:
            ContentUnavailableView(
                "Bluetooth Not Available",
                systemImage: "antenna.radiowaves.left.and.right.slash",
                description: Text(
                    "This device doesn't support Bluetooth Low Energy. " +
                    "Pairing isn't available here (the iOS Simulator falls into this case too)."
                )
            )
        case .scanning where state.discoveredPeripherals.isEmpty:
            scanningView()
        default:
            discoveredList(for: state)
        }
    }

    @ViewBuilder
    private func scanningView() -> some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Scanning for Polar H10…")
                .foregroundStyle(.secondary)
            Text("Make sure the strap is moistened and worn, and that Polar Flow isn't connected.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    @ViewBuilder
    private func discoveredList(for state: PolarHRMState) -> some View {
        List {
            Section {
                ForEach(state.discoveredPeripherals) { p in
                    Button {
                        service.pair(.init(id: p.id, name: p.name))
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.red)
                            VStack(alignment: .leading) {
                                Text(p.name)
                                    .foregroundStyle(.primary)
                                Text(p.id.uuidString)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Discovered devices")
            } footer: {
                Text("Tap a device to pair. Anxiety Watch will remember it for future sessions.")
            }

            if case .error(let message) = state.status {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}
