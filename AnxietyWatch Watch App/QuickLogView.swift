import SwiftUI
import WatchKit

struct QuickLogView: View {
    @State private var selectedSeverity: Int? = nil
    @State private var showingConfirmation = false
    private let connectivity = WatchConnectivityManager.shared

    var body: some View {
        GeometryReader { geo in
            let rows = 2
            let cols = 5
            let hSpacing: CGFloat = 4
            let vSpacing: CGFloat = 6
            let buttonWidth = (geo.size.width - hSpacing * CGFloat(cols - 1)) / CGFloat(cols)
            let buttonHeight = min(buttonWidth, (geo.size.height - vSpacing) / CGFloat(rows))

            VStack(spacing: vSpacing) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: hSpacing) {
                        ForEach(0..<cols, id: \.self) { col in
                            let level = row * cols + col + 1
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
                                    .font(.title3.bold())
                                    .frame(width: buttonWidth, height: buttonHeight)
                                    .background(
                                        Circle()
                                            .fill(severityColor(level).opacity(selectedSeverity == level ? 1.0 : 0.3))
                                    )
                                    .foregroundStyle(selectedSeverity == level ? .white : severityColor(level))
                            }
                            .buttonStyle(.plain)
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
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                showingConfirmation = false
            }
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
