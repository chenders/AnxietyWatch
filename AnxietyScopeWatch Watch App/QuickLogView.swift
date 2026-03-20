import SwiftUI
import WatchKit

struct QuickLogView: View {
    @State private var severity: Double = 5
    @State private var showingConfirmation = false
    private let connectivity = WatchConnectivityManager.shared

    var body: some View {
        VStack(spacing: 8) {
            Spacer()

            Text("\(Int(severity))")
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .foregroundStyle(severityColor)
                .contentTransition(.numericText())
                .animation(.snappy, value: Int(severity))

            Text("Anxiety Level")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                let level = Int(severity)
                connectivity.sendAnxietyEntry(severity: level)
                WKInterfaceDevice.current().play(.success)
                showingConfirmation = true
            } label: {
                Label("Log", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity)
            }
            .tint(severityColor)
        }
        .focusable()
        .digitalCrownRotation(
            $severity,
            from: 1,
            through: 10,
            by: 1,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .alert("Logged", isPresented: $showingConfirmation) {
            Button("OK") {}
        } message: {
            Text("Anxiety level \(Int(severity)) sent to iPhone")
        }
        .navigationTitle("Quick Log")
    }

    private var severityColor: Color {
        switch Int(severity) {
        case 1...3: return .green
        case 4...6: return .yellow
        case 7...8: return .orange
        default: return .red
        }
    }
}
