import SwiftUI
import SwiftData
import CoreLocation

struct AddPharmacyView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var address = ""
    @State private var phoneNumber = ""
    @State private var notes = ""
    @State private var latitude: Double?
    @State private var longitude: Double?
    @State private var showingSearch = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Pharmacy Info") {
                    TextField("Name", text: $name)
                    TextField("Address", text: $address)
                    TextField("Phone Number", text: $phoneNumber)
                        .keyboardType(.phonePad)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section {
                    Button {
                        showingSearch = true
                    } label: {
                        Label("Search Pharmacies", systemImage: "magnifyingglass")
                    }
                }
            }
            .navigationTitle("Add Pharmacy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $showingSearch) {
                PharmacySearchView { result in
                    name = result.name
                    address = result.address
                    phoneNumber = result.phoneNumber ?? ""
                    latitude = result.coordinate.latitude
                    longitude = result.coordinate.longitude
                    showingSearch = false
                }
            }
        }
    }

    private func save() {
        let pharmacy = Pharmacy(
            name: name.trimmingCharacters(in: .whitespaces),
            address: address.trimmingCharacters(in: .whitespaces),
            phoneNumber: phoneNumber.trimmingCharacters(in: .whitespaces),
            latitude: latitude,
            longitude: longitude,
            notes: notes.trimmingCharacters(in: .whitespaces)
        )
        modelContext.insert(pharmacy)
        dismiss()
    }
}
