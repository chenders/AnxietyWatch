// AnxietyWatch/Views/Settings/HRVSessionLiveView.swift
import SwiftUI

/// Live view shown while a Polar H10 session is recording. Intentionally
/// low-fidelity in Phase 2 — the user said they want to iterate on UI
/// once the data is flowing.
struct HRVSessionLiveView: View {
    let service: PolarHRMService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let state = service.state
        NavigationStack {
            VStack(spacing: 32) {
                statusBadge(for: state.status)

                VStack(spacing: 8) {
                    Text(state.currentHR.map { "\($0)" } ?? "—")
                        .font(.system(size: 96, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(.primary)
                    Text("bpm")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                Divider()
                    .padding(.horizontal)

                HStack(spacing: 32) {
                    metricCell(
                        label: "Last-minute RMSSD",
                        value: state.lastMinuteRMSSD.map { String(format: "%.0f ms", $0) } ?? "—"
                    )
                    metricCell(
                        label: "Elapsed",
                        value: RecordingFormatters.formatElapsed(state.sessionElapsed)
                    )
                }

                Spacer()

                // Only offer Stop when there's actually something to stop.
                // For .bluetoothOff/.unauthorized/.unsupported/.error the
                // user needs to dismiss and use the Close button (Settings'
                // section will offer recovery guidance) — tapping Stop in
                // those states would just paper over the real status with
                // .idle.
                if state.status == .recording || state.status == .connecting {
                    Button(role: .destructive) {
                        service.stopSession()
                        dismiss()
                    } label: {
                        Text("Stop Session")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .padding(.horizontal)
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 16)
            .navigationTitle("HRV Session")
            .navigationBarTitleDisplayMode(.inline)
            // Swipe-to-dismiss is intentionally allowed during recording.
            // The persistent RecordingStatusPill at the root of ContentView
            // is now the always-visible session indicator and re-entry
            // point, so dismissing this sheet no longer loses track of the
            // in-progress session. The user can journal, browse Trends,
            // etc. with the pill as their tether back.
            .toolbar {
                // Always offer an explicit dismiss affordance — VoiceOver
                // and keyboard users can't reach the swipe-to-dismiss
                // gesture, so without this they'd have no way to leave the
                // sheet without ending the session. Label switches from
                // "Hide" (recording continues; pill is the re-entry path)
                // to "Close" (session already ended; pill is gone).
                ToolbarItem(placement: .cancellationAction) {
                    let isLive = state.status == .recording || state.status == .connecting
                    Button(isLive ? "Hide" : "Close") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func statusBadge(for status: PolarHRMState.Status) -> some View {
        let (text, color, icon): (String, Color, String) = {
            switch status {
            case .recording: return ("Recording", .green, "record.circle.fill")
            case .connecting: return ("Connecting…", .orange, "antenna.radiowaves.left.and.right")
            case .scanning: return ("Scanning…", .orange, "magnifyingglass")
            case .idle: return ("Idle", .secondary, "circle")
            case .bluetoothOff: return ("Bluetooth Off", .red, "antenna.radiowaves.left.and.right.slash")
            case .bluetoothUnauthorized: return ("Bluetooth Permission Needed", .red, "lock.shield")
            case .bluetoothUnsupported: return ("Bluetooth Not Available", .red, "antenna.radiowaves.left.and.right.slash")
            case .error(let m): return (m, .red, "exclamationmark.triangle.fill")
            }
        }()
        Label(text, systemImage: icon)
            .foregroundStyle(color)
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func metricCell(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2)
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

}
