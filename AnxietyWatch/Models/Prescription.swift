import Foundation
import SwiftData

@Model
final class Prescription {
    var id: UUID
    var rxNumber: String
    /// Denormalized — preserves the name even if the definition is later deleted
    var medicationName: String
    var doseMg: Double
    /// Human-readable dose description, e.g. "10mg tablet", "0.5mg/mL"
    var doseDescription: String
    var dateFilled: Date
    /// Denormalized — preserves the name even if the pharmacy is later deleted
    var pharmacyName: String
    var notes: String
    var medication: MedicationDefinition?
    var pharmacy: Pharmacy?

    init(
        rxNumber: String,
        medicationName: String,
        doseMg: Double,
        doseDescription: String = "",
        dateFilled: Date = .now,
        pharmacyName: String = "",
        notes: String = "",
        medication: MedicationDefinition? = nil,
        pharmacy: Pharmacy? = nil
    ) {
        self.id = UUID()
        self.rxNumber = rxNumber
        self.medicationName = medicationName
        self.doseMg = doseMg
        self.doseDescription = doseDescription
        self.dateFilled = dateFilled
        self.pharmacyName = pharmacyName
        self.notes = notes
        self.medication = medication
        self.pharmacy = pharmacy
    }
}
