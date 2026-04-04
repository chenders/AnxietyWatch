import SwiftUI
import SwiftData

/// One-tap severity sheet shown when a random check-in notification is due.
struct RandomCheckInPromptView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("How are you feeling?")
                    .font(.title2.bold())
                    .padding(.top, 24)

                Text("Tap a number to log")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
                    ForEach(1...10, id: \.self) { level in
                        Button {
                            logEntry(severity: level)
                        } label: {
                            Text("\(level)")
                                .font(.title2.bold())
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .background(Color.severity(level), in: .circle)
                        }
                    }
                }
                .padding(.horizontal, 24)

                HStack {
                    ForEach(["Calm", "Mild", "Moderate", "High", "Crisis"], id: \.self) { label in
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 24)

                Spacer()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") {
                        RandomCheckInManager.dismissCheckIn()
                        dismiss()
                    }
                }
            }
        }
    }

    private func logEntry(severity: Int) {
        let entry = AnxietyEntry(
            severity: severity,
            source: "random_checkin"
        )
        modelContext.insert(entry)
        try? modelContext.save()
        RandomCheckInManager.completeCheckIn()
        dismiss()
    }
}
