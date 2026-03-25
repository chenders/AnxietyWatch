import SwiftUI
import SwiftData

struct PharmacyListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        filter: #Predicate<Pharmacy> { $0.isActive },
        sort: \Pharmacy.name
    )
    private var pharmacies: [Pharmacy]
    @State private var showingAddPharmacy = false

    var body: some View {
        NavigationStack {
            List {
                if pharmacies.isEmpty {
                    Text("No pharmacies added. Tap + to add one.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pharmacies) { pharmacy in
                        NavigationLink(value: pharmacy) {
                            PharmacyRow(pharmacy: pharmacy)
                        }
                    }
                    .onDelete(perform: deactivatePharmacies)
                }
            }
            .navigationTitle("Pharmacies")
            .navigationDestination(for: Pharmacy.self) { pharmacy in
                PharmacyDetailView(pharmacy: pharmacy)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddPharmacy = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddPharmacy) {
                AddPharmacyView()
            }
        }
    }

    /// Deactivate rather than delete — preserves call log and prescription history.
    private func deactivatePharmacies(offsets: IndexSet) {
        for index in offsets {
            pharmacies[index].isActive = false
        }
    }
}

// MARK: - Row Subview

private struct PharmacyRow: View {
    let pharmacy: Pharmacy

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pharmacy.name)
                .font(.headline)
            if !pharmacy.address.isEmpty {
                Text(pharmacy.address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !pharmacy.phoneNumber.isEmpty {
                Text(pharmacy.phoneNumber)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
