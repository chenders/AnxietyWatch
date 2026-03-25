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
    /// Total pills/units dispensed
    var quantity: Int
    var refillsRemaining: Int
    var dateFilled: Date
    /// Computed from quantity and daily dose frequency; nil if unknown
    var estimatedRunOutDate: Date?
    /// Denormalized — preserves the name even if the pharmacy is later deleted
    var pharmacyName: String
    var notes: String
    /// User-provided daily dose count when no logging history is available
    var dailyDoseCount: Double?
    var medication: MedicationDefinition?
    var pharmacy: Pharmacy?

    init(
        rxNumber: String,
        medicationName: String,
        doseMg: Double,
        doseDescription: String = "",
        quantity: Int,
        refillsRemaining: Int = 0,
        dateFilled: Date = .now,
        estimatedRunOutDate: Date? = nil,
        pharmacyName: String = "",
        notes: String = "",
        dailyDoseCount: Double? = nil,
        medication: MedicationDefinition? = nil,
        pharmacy: Pharmacy? = nil
    ) {
        self.id = UUID()
        self.rxNumber = rxNumber
        self.medicationName = medicationName
        self.doseMg = doseMg
        self.doseDescription = doseDescription
        self.quantity = quantity
        self.refillsRemaining = refillsRemaining
        self.dateFilled = dateFilled
        self.estimatedRunOutDate = estimatedRunOutDate
        self.pharmacyName = pharmacyName
        self.notes = notes
        self.dailyDoseCount = dailyDoseCount
        self.medication = medication
        self.pharmacy = pharmacy
    }
}
