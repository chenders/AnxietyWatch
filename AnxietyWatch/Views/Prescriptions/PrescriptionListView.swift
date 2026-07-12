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
        // Cache the two supply-status partitions once per body. Each was read
        // twice (the empty-state gate and its own Section), re-running
        // PrescriptionSupplyCalculator.supplyStatus over the whole
        // prescriptions table on every access (F-065).
        let active = activePrescriptions
        let expired = expiredPrescriptions
        return NavigationStack {
            List {
                if active.isEmpty && expired.isEmpty {
                    Text("No prescriptions yet. Tap + to add one.")
                        .foregroundStyle(.secondary)
                }

                if !active.isEmpty {
                    Section("Active") {
                        ForEach(active) { rx in
                            NavigationLink {
                                PrescriptionDetailView(prescription: rx)
                            } label: {
                                PrescriptionRow(prescription: rx)
                            }
                        }
                        .onDelete { offsets in
                            deleteFromFiltered(offsets, in: active)
                        }
                    }
                }

                if !expired.isEmpty {
                    Section("Recently Expired") {
                        ForEach(expired) { rx in
                            NavigationLink {
                                PrescriptionDetailView(prescription: rx)
                            } label: {
                                PrescriptionRow(prescription: rx)
                            }
                        }
                        .onDelete { offsets in
                            deleteFromFiltered(offsets, in: expired)
                        }
                    }
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

    /// Prescriptions with supply remaining or filled within the last 60 days.
    private var activePrescriptions: [Prescription] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -60, to: .now) ?? .distantPast
        return prescriptions.filter { rx in
            let status = PrescriptionSupplyCalculator.supplyStatus(for: rx)
            if status == .good || status == .warning || status == .low {
                return true
            }
            // Show recently filled even if unknown status
            let fillDate = rx.lastFillDate ?? rx.dateFilled
            return fillDate >= cutoff && status != .expired
        }
    }

    /// Recently expired prescriptions (within the last 30 days) worth tracking.
    private var expiredPrescriptions: [Prescription] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .distantPast
        return prescriptions.filter { rx in
            let status = PrescriptionSupplyCalculator.supplyStatus(for: rx)
            let fillDate = rx.lastFillDate ?? rx.dateFilled
            return status == .expired && fillDate >= cutoff
        }
    }

    private func deleteFromFiltered(_ offsets: IndexSet, in filtered: [Prescription]) {
        let snapshot = filtered
        for index in offsets {
            modelContext.delete(snapshot[index])
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
                HStack(spacing: 6) {
                    if !prescription.doseDescription.isEmpty {
                        Text(prescription.doseDescription)
                    } else if prescription.doseMg > 0 {
                        Text(String(format: "%.0fmg", prescription.doseMg))
                    }
                    if prescription.quantity > 0 {
                        Text("qty \(prescription.quantity)")
                    }
                    Text((prescription.lastFillDate ?? prescription.dateFilled).formatted(.dateTime.month().day()))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
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

#if DEBUG
#Preview {
    let container = try! PreviewHelpers.makeSeededContainer()
    PrescriptionListView()
        .modelContainer(container)
}
#endif
