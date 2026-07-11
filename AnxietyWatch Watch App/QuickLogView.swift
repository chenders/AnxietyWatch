import SwiftUI
import WatchKit

struct QuickLogView: View {
    @State private var selectedSeverity: Int? = nil
    @State private var showingConfirmation = false
    private let connectivity = WatchConnectivityManager.shared

    var body: some View {
        GeometryReader { geo in
            let layout = QuickLogLayout(size: geo.size)

            // Rows are spread with Spacers so the large circles fill the whole
            // height; the short final row is centred by the HStack.
            VStack(spacing: 0) {
                let rows = QuickLogLayout.rowsOfLevels()
                ForEach(rows.indices, id: \.self) { index in
                    if index > 0 { Spacer(minLength: QuickLogLayout.spacing) }
                    HStack(spacing: QuickLogLayout.spacing) {
                        ForEach(rows[index], id: \.self) { level in
                            severityButton(level: level, layout: layout)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            if showingConfirmation {
                confirmationOverlay
            }
        }
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// One severity target: a large circle with a heavy number filling it.
    /// Bigger circles — reachable without fine motor control — are what make
    /// the right number easy to hit with shaky hands or impaired vision.
    private func severityButton(level: Int, layout: QuickLogLayout) -> some View {
        Button {
            selectedSeverity = level
            let source: String? = connectivity.pendingRandomCheckIn ? "random_checkin" : nil
            connectivity.sendAnxietyEntry(severity: level, source: source)
            if connectivity.pendingRandomCheckIn {
                connectivity.pendingRandomCheckIn = false
            }
            WKInterfaceDevice.current().play(.success)
            showingConfirmation = true
        } label: {
            Text("\(level)")
                .font(.system(size: layout.fontSize, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.5)
                .foregroundStyle(severityTextColor(level))
                .frame(width: layout.diameter, height: layout.diameter)
                .background(Circle().fill(severityColor(level)))
                .overlay {
                    // Selection is shown with a ring, not an opacity change, so
                    // the number keeps its full contrast in every state. The
                    // ring reuses the number's contrast color rather than a
                    // fixed white — a white stroke on the light fills (yellow
                    // especially) is nearly invisible, which would make the
                    // selected state unreadable exactly where it matters.
                    if selectedSeverity == level {
                        Circle().strokeBorder(severityTextColor(level), lineWidth: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(level), \(severityLabel(level))")
    }

    // MARK: - Confirmation

    private var confirmationOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Logged")
                .font(.headline)
            if let s = selectedSeverity {
                Text("\(s) — \(severityLabel(s))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .task {
            try? await Task.sleep(for: .seconds(1.5))
            showingConfirmation = false
        }
    }

    // MARK: - Severity Helpers

    /// watchOS-local color mapping matching the shared SeverityColor.swift
    /// (can't share the file directly between iOS and watchOS targets)
    private func severityColor(_ level: Int) -> Color {
        switch level {
        case 1...2: return .green
        case 3...4: return .yellow
        case 5...6: return .orange
        case 7...8: return .red
        default: return Color(red: 0.6, green: 0.0, blue: 0.0)
        }
    }

    /// High-contrast text color for the number sitting on a full-opacity
    /// severity fill. Dark text on the light fills (green/yellow/orange), light
    /// text on the dark fills (red/dark red) — chosen so every number clears
    /// WCAG AA for large text against its circle (the same-hue text on 9/10 was
    /// the failing case). Matches the bands in `severityColor`.
    private func severityTextColor(_ level: Int) -> Color {
        switch level {
        case 1...6: return .black
        default: return .white
        }
    }

    private func severityLabel(_ level: Int) -> String {
        switch level {
        case 1...2: return "Calm"
        case 3...4: return "Mild"
        case 5...6: return "Moderate"
        case 7...8: return "High"
        default: return "Crisis"
        }
    }
}
