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
    /// When true, logging a dose opens an anxiety rating prompt + schedules a 30-min follow-up.
    /// Optional for migration — nil treated as false for existing medications.
    var promptAnxietyOnLog: Bool?
    /// Legacy nullable column retained only so existing SwiftData stores migrate safely.
    /// Product logic, export, sync, and restore intentionally ignore it.
    var cnsDepressantClass: String? = nil
    @Relationship(deleteRule: .nullify, inverse: \MedicationDose.medication)
    var doses: [MedicationDose]
    @Relationship(deleteRule: .nullify, inverse: \Prescription.medication)
    var prescriptions: [Prescription]

    init(
        name: String,
        defaultDoseMg: Double,
        category: String = "",
        isActive: Bool = true,
        promptAnxietyOnLog: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.defaultDoseMg = defaultDoseMg
        self.category = category
        self.isActive = isActive
        self.promptAnxietyOnLog = promptAnxietyOnLog
        self.doses = []
        self.prescriptions = []
    }
}
