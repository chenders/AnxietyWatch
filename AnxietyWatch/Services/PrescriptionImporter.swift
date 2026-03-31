import Foundation
import SwiftData

/// Extracts prescription records from server JSON into SwiftData models.
/// Pure mapping logic — no network, no auth.
enum PrescriptionImporter {

    enum ImportError: Error {
        case missingRxNumber
    }

    private static let isoFormatterFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Import a single prescription record from a server JSON dict.
    /// Upserts: updates existing if rx_number matches, otherwise inserts.
    /// Returns the imported or updated Prescription.
    @discardableResult
    static func importRecord(
        _ record: [String: Any],
        into context: ModelContext
    ) throws -> Prescription {
        guard let rxNumber = record["rx_number"] as? String, !rxNumber.isEmpty else {
            throw ImportError.missingRxNumber
        }

        let dateFilled = parseDate(record["date_filled"]) ?? .now
        let lastFillDate = parseDate(record["last_fill_date"])
        let estimatedRunOut = parseDate(record["estimated_run_out_date"])

        let quantity = record["quantity"] as? Int ?? 0
        let dailyDose = record["daily_dose_count"] as? Double ?? 1.0
        let daysSupply = record["days_supply"] as? Int
        let directions = record["directions"] as? String ?? ""
        let refills = record["refills_remaining"] as? Int ?? 0

        // Compute run-out: prefer server value, then daysSupply, then quantity-based
        let computedRunOut = estimatedRunOut
            ?? daysSupplyRunOut(dateFilled: dateFilled, daysSupply: daysSupply)
            ?? PrescriptionSupplyCalculator.estimateRunOutDate(
                dateFilled: dateFilled,
                quantity: quantity,
                dailyDoseCount: dailyDose
            )

        // Check for existing prescription to update (predicate-based, not full scan)
        var descriptor = FetchDescriptor<Prescription>(
            predicate: #Predicate { $0.rxNumber == rxNumber }
        )
        descriptor.fetchLimit = 1
        if let rx = try context.fetch(descriptor).first {
            return try update(rx, from: record, directions: directions, refills: refills, context: context)
        }

        // Insert new
        let rx = Prescription(
            rxNumber: rxNumber,
            medicationName: record["medication_name"] as? String ?? "",
            doseMg: record["dose_mg"] as? Double ?? 0,
            doseDescription: record["dose_description"] as? String ?? "",
            quantity: quantity,
            refillsRemaining: refills,
            dateFilled: dateFilled,
            estimatedRunOutDate: computedRunOut,
            pharmacyName: record["pharmacy_name"] as? String ?? "",
            notes: record["notes"] as? String ?? "",
            dailyDoseCount: dailyDose,
            prescriberName: record["prescriber_name"] as? String ?? "",
            ndcCode: record["ndc_code"] as? String ?? "",
            rxStatus: record["rx_status"] as? String ?? "",
            lastFillDate: lastFillDate,
            importSource: record["import_source"] as? String ?? "caprx",
            walgreensRxId: record["walgreens_rx_id"] as? String,
            directions: directions,
            daysSupply: daysSupply,
            patientPay: record["patient_pay"] as? Double,
            planPay: record["plan_pay"] as? Double,
            dosageForm: record["dosage_form"] as? String ?? "",
            drugType: record["drug_type"] as? String ?? ""
        )
        context.insert(rx)

        rx.medication = try findOrCreateMedication(
            name: rx.medicationName, doseMg: rx.doseMg, in: context
        )

        return rx
    }

    /// Import multiple records. Returns the count of added + updated.
    static func importRecords(
        _ records: [[String: Any]],
        into context: ModelContext
    ) throws -> Int {
        var count = 0
        for record in records {
            guard let _ = record["rx_number"] as? String else { continue }
            try importRecord(record, into: context)
            count += 1
        }
        return count
    }

    // MARK: - Internal (exposed for SyncService backward compatibility)

    static func findOrCreateMedication(
        name: String,
        doseMg: Double,
        in context: ModelContext
    ) throws -> MedicationDefinition? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Try exact match first (fast, predicate-based)
        var descriptor = FetchDescriptor<MedicationDefinition>(
            predicate: #Predicate { $0.name == trimmed }
        )
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            if !existing.isActive { existing.isActive = true }
            return existing
        }

        // Fallback: case-insensitive match (SwiftData predicates don't support lowercased())
        let allMeds = try context.fetch(FetchDescriptor<MedicationDefinition>())
        let lowered = trimmed.lowercased()
        if let existing = allMeds.first(where: { $0.name.lowercased() == lowered }) {
            if !existing.isActive { existing.isActive = true }
            return existing
        }

        let newMed = MedicationDefinition(name: trimmed, defaultDoseMg: doseMg)
        context.insert(newMed)
        return newMed
    }

    // MARK: - Private

    private static func update(
        _ rx: Prescription,
        from record: [String: Any],
        directions: String,
        refills: Int,
        context: ModelContext
    ) throws -> Prescription {
        if !directions.isEmpty && rx.directions.isEmpty {
            rx.directions = directions
        }
        if refills > 0 && rx.refillsRemaining == 0 {
            rx.refillsRemaining = refills
        }
        if rx.prescriberName.isEmpty {
            rx.prescriberName = record["prescriber_name"] as? String ?? ""
        }
        if rx.ndcCode.isEmpty {
            rx.ndcCode = record["ndc_code"] as? String ?? ""
        }
        if rx.rxStatus.isEmpty {
            rx.rxStatus = record["rx_status"] as? String ?? ""
        }
        // Always update cost/supply fields from newer data
        if let ds = record["days_supply"] as? Int {
            rx.daysSupply = ds
        }
        if let pp = record["patient_pay"] as? Double {
            rx.patientPay = pp
        }
        if let plp = record["plan_pay"] as? Double {
            rx.planPay = plp
        }
        let form = record["dosage_form"] as? String ?? ""
        if !form.isEmpty { rx.dosageForm = form }
        let dtype = record["drug_type"] as? String ?? ""
        if !dtype.isEmpty { rx.drugType = dtype }

        if rx.medication == nil || rx.medication?.isActive == false {
            rx.medication = try findOrCreateMedication(
                name: rx.medicationName, doseMg: rx.doseMg, in: context
            )
        }
        return rx
    }

    private static func daysSupplyRunOut(dateFilled: Date, daysSupply: Int?) -> Date? {
        guard let ds = daysSupply, ds > 0 else { return nil }
        return Calendar.current.date(byAdding: .day, value: ds, to: dateFilled)
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let str = value as? String, !str.isEmpty else { return nil }
        // Try fractional seconds first (e.g. "2024-04-01T00:00:00.000Z"),
        // then plain (e.g. "2025-12-31T00:00:00+00:00" from Python isoformat())
        return isoFormatterFractional.date(from: str)
            ?? isoFormatterPlain.date(from: str)
    }
}
