import SwiftUI
import SwiftData

struct PrescriptionListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Prescription.dateFilled, order: .reverse)
    private var prescriptions: [Prescription]
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                if prescriptions.isEmpty {
                    Text("No prescriptions yet. Tap + to add one.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(prescriptions) { rx in
                        NavigationLink {
                            PrescriptionDetailView(prescription: rx)
                        } label: {
                            PrescriptionRow(prescription: rx)
                        }
                    }
                    .onDelete(perform: deletePrescriptions)
                }
            }
            .navigationTitle("Prescriptions")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddPrescriptionView()
            }
        }
    }

    private func deletePrescriptions(offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(prescriptions[index])
        }
    }
}

// MARK: - Row

private struct PrescriptionRow: View {
    let prescription: Prescription

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(prescription.medicationName)
                    .font(.headline)
                if !prescription.rxNumber.isEmpty {
                    Text("Rx# \(prescription.rxNumber)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            SupplyBadge(prescription: prescription)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Supply Badge

struct SupplyBadge: View {
    let prescription: Prescription

    var body: some View {
        let status = PrescriptionSupplyCalculator.supplyStatus(for: prescription)
        let days = PrescriptionSupplyCalculator.daysRemaining(for: prescription)

        HStack(spacing: 4) {
            Circle()
                .fill(color(for: status))
                .frame(width: 8, height: 8)
            Text(label(status: status, days: days))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func color(for status: PrescriptionSupplyCalculator.SupplyStatus) -> Color {
        switch status {
        case .good:    return .green
        case .warning: return .yellow
        case .low:     return .red
        case .expired: return .gray
        case .unknown: return .secondary
        }
    }

    private func label(
        status: PrescriptionSupplyCalculator.SupplyStatus,
        days: Int?
    ) -> String {
        guard let days else { return "Unknown" }
        switch status {
        case .expired:
            return "Expired"
        default:
            return "\(days)d left"
        }
    }
}
