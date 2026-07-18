import SwiftUI

/// Dashboard provenance card for the full-app demo's hardware-free EMAY
/// stream. It is intentionally absent outside that mode; the production live
/// oximeter remains available from Settings.
struct EMAYLiveCardView: View {
    @Environment(EMAYRealtimeService.self) private var service

    var body: some View {
        if service.isFullAppDemoSimulated, let elapsed = service.fullAppDemoElapsed {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("EMAY Oximeter", systemImage: "lungs.fill")
                        .font(.headline)
                    Spacer()
                    Label("Streaming", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }

                Text("Simulated · \(RecordingFormatters.formatElapsed(elapsed)) elapsed")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 28) {
                    metric(
                        service.latestReading?.spo2.map { "\($0)%" } ?? "—",
                        label: "SpO₂"
                    )
                    metric(
                        service.latestReading?.pulseRate.map { "\($0) bpm" } ?? "—",
                        label: "Pulse"
                    )
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .padding(.horizontal)
            .accessibilityIdentifier("demo.emay.dashboard")
        }
    }

    private func metric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2)
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
