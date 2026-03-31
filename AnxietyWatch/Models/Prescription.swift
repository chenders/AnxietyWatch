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
    /// Prescriber name from pharmacy records
    var prescriberName: String = ""
    /// National Drug Code — unique identifier for medication packaging
    var ndcCode: String = ""
    /// Prescription status, e.g. "Retail Pickup", "active", "expired"
    var rxStatus: String = ""
    /// Most recent fill date (may differ from dateFilled for multi-fill prescriptions)
    var lastFillDate: Date?
    /// Origin of this record: "manual" (user-entered) or "walgreens" (auto-imported)
    var importSource: String = "manual"
    /// Walgreens internal prescription ID for deduplication
    var walgreensRxId: String?
    /// Prescription directions, e.g. "Take 1 tablet by mouth daily"
    var directions: String = ""
    /// Days of medication supply from PBM (more authoritative than quantity-based estimate)
    var daysSupply: Int?
    /// Patient copay amount from PBM claims
    var patientPay: Double?
    /// Insurance payment amount from PBM claims
    var planPay: Double?
    /// Dosage form: tablet, capsule, solution, etc.
    var dosageForm: String = ""
    /// Drug type: brand, generic, specialty
    var drugType: String = ""
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
        prescriberName: String = "",
        ndcCode: String = "",
        rxStatus: String = "",
        lastFillDate: Date? = nil,
        importSource: String = "manual",
        walgreensRxId: String? = nil,
        directions: String = "",
        daysSupply: Int? = nil,
        patientPay: Double? = nil,
        planPay: Double? = nil,
        dosageForm: String = "",
        drugType: String = "",
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
        self.prescriberName = prescriberName
        self.ndcCode = ndcCode
        self.rxStatus = rxStatus
        self.lastFillDate = lastFillDate
        self.importSource = importSource
        self.walgreensRxId = walgreensRxId
        self.directions = directions
        self.daysSupply = daysSupply
        self.patientPay = patientPay
        self.planPay = planPay
        self.dosageForm = dosageForm
        self.drugType = drugType
        self.medication = medication
        self.pharmacy = pharmacy
    }
}
