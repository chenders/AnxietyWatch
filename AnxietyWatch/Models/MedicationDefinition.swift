import Foundation
import SwiftData

@Model
final class MedicationDefinition {
    var id: UUID
    var name: String
    var defaultDoseMg: Double
    /// e.g. "benzodiazepine", "SSRI", "supplement"
    var category: String
    var isActive: Bool
    @Relationship(deleteRule: .nullify, inverse: \MedicationDose.medication)
    var doses: [MedicationDose]
    @Relationship(deleteRule: .nullify, inverse: \Prescription.medication)
    var prescriptions: [Prescription]

    init(
        name: String,
        defaultDoseMg: Double,
        category: String = "",
        isActive: Bool = true
    ) {
        self.id = UUID()
        self.name = name
        self.defaultDoseMg = defaultDoseMg
        self.category = category
        self.isActive = isActive
        self.doses = []
        self.prescriptions = []
    }
}
