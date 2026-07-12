import SwiftUI
import SwiftData

struct PrescriptionListView: View, Equatable {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Prescription.dateFilled, order: .reverse)
    private var prescriptions: [Prescription]

    // Trivially Equatable (no identity inputs — all state is @Query/@State);
    // paired with `.equatable()` at the NavigationLink call site so SwiftUI
    // dedupes rebuilds. See CLAUDE.md render-pitfall #2.
    static func == (lhs: PrescriptionListView, rhs: PrescriptionListView) -> Bool { true }
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
                    .onDelete(perform: delete)
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

    private func delete(_ offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(prescriptions[index])
        }
    }

}

// MARK: - Row

private struct PrescriptionRow: View {
    let prescription: Prescription

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(prescription.medicationName)
                .font(.headline)
            HStack(spacing: 6) {
                if !prescription.doseDescription.isEmpty {
                    Text(prescription.doseDescription)
                } else if prescription.doseMg > 0 {
                    Text(String(format: "%.0fmg", prescription.doseMg))
                }
                Text(prescription.dateFilled.formatted(.dateTime.month().day()))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

#if DEBUG
#Preview {
    let container = try! PreviewHelpers.makeSeededContainer()
    PrescriptionListView()
        .modelContainer(container)
}
#endif
