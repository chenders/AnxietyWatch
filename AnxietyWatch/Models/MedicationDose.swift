import Foundation
import SwiftData

@Model
final class MedicationDose {
    var id: UUID
    var timestamp: Date
    /// Denormalized — preserves the name even if the definition is later deleted
    var medicationName: String
    var doseMg: Double
    var notes: String?
    /// True if taken as-needed (PRN), false if on a timed schedule
    var isPRN: Bool
    var medication: MedicationDefinition?

    init(
        timestamp: Date = .now,
        medicationName: String,
        doseMg: Double,
        notes: String? = nil,
        isPRN: Bool = true,
        medication: MedicationDefinition? = nil
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.medicationName = medicationName
        self.doseMg = doseMg
        self.notes = notes
        self.isPRN = isPRN
        self.medication = medication
    }
}
