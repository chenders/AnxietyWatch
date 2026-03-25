import Foundation
import SwiftData

/// Exports all app data as JSON or CSV.
enum DataExporter {

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - JSON Export

    struct ExportBundle: Codable {
        let exportDate: String
        let anxietyEntries: [AnxietyEntryDTO]
        let medicationDefinitions: [MedicationDefinitionDTO]
        let medicationDoses: [MedicationDoseDTO]
        let cpapSessions: [CPAPSessionDTO]
        let healthSnapshots: [HealthSnapshotDTO]
        let barometricReadings: [BarometricReadingDTO]
        let clinicalLabResults: [ClinicalLabResultDTO]
        let pharmacies: [PharmacyDTO]
        let prescriptions: [PrescriptionDTO]
        let pharmacyCallLogs: [PharmacyCallLogDTO]
    }

    static func exportJSON(from context: ModelContext, start: Date? = nil, end: Date? = nil) throws -> Data {
        let bundle = try buildBundle(from: context, start: start, end: end)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(bundle)
    }

    // MARK: - CSV Export

    /// Returns array of (filename, csvData) pairs — one per entity type.
    static func exportCSV(from context: ModelContext, start: Date? = nil, end: Date? = nil) throws -> [(String, Data)] {
        let bundle = try buildBundle(from: context, start: start, end: end)
        var files: [(String, Data)] = []

        // Anxiety entries
        var csv = "timestamp,severity,notes,tags\n"
        for e in bundle.anxietyEntries {
            let tags = e.tags.joined(separator: ";")
            csv += "\(e.timestamp),\(e.severity),\"\(escapeCsv(e.notes))\",\"\(tags)\"\n"
        }
        files.append(("anxiety_entries.csv", Data(csv.utf8)))

        // Medication definitions
        csv = "name,default_dose_mg,category,is_active\n"
        for m in bundle.medicationDefinitions {
            csv += "\"\(escapeCsv(m.name))\",\(m.defaultDoseMg),\"\(m.category)\",\(m.isActive)\n"
        }
        files.append(("medication_definitions.csv", Data(csv.utf8)))

        // Medication doses
        csv = "timestamp,medication_name,dose_mg,notes\n"
        for d in bundle.medicationDoses {
            csv += "\(d.timestamp),\"\(escapeCsv(d.medicationName))\",\(d.doseMg),\"\(escapeCsv(d.notes ?? ""))\"\n"
        }
        files.append(("medication_doses.csv", Data(csv.utf8)))

        // CPAP sessions
        csv = "date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea,source\n"
        for s in bundle.cpapSessions {
            csv += "\(s.date),\(s.ahi),\(s.totalUsageMinutes),\(s.leakRate95th),"
            csv += "\(s.pressureMin),\(s.pressureMax),\(s.pressureMean),"
            csv += "\(s.obstructiveEvents),\(s.centralEvents),\(s.hypopneaEvents),\(s.importSource)\n"
        }
        files.append(("cpap_sessions.csv", Data(csv.utf8)))

        // Health snapshots
        csv = "date,hrv_avg,hrv_min,resting_hr,sleep_total_min,sleep_deep_min,sleep_rem_min,"
        csv += "sleep_core_min,sleep_awake_min,skin_temp_dev,resp_rate,spo2_avg,"
        csv += "steps,active_cal,exercise_min,env_sound_avg,bp_sys,bp_dia,glucose_avg\n"
        for h in bundle.healthSnapshots {
            csv += "\(h.date),\(opt(h.hrvAvg)),\(opt(h.hrvMin)),\(opt(h.restingHR)),"
            csv += "\(opt(h.sleepDurationMin)),\(opt(h.sleepDeepMin)),\(opt(h.sleepREMMin)),"
            csv += "\(opt(h.sleepCoreMin)),\(opt(h.sleepAwakeMin)),\(opt(h.skinTempDeviation)),"
            csv += "\(opt(h.respiratoryRate)),\(opt(h.spo2Avg)),\(opt(h.steps)),"
            csv += "\(opt(h.activeCalories)),\(opt(h.exerciseMinutes)),\(opt(h.environmentalSoundAvg)),"
            csv += "\(opt(h.bpSystolic)),\(opt(h.bpDiastolic)),\(opt(h.bloodGlucoseAvg))\n"
        }
        files.append(("health_snapshots.csv", Data(csv.utf8)))

        // Barometric readings
        csv = "timestamp,pressure_kpa,relative_altitude_m\n"
        for b in bundle.barometricReadings {
            csv += "\(b.timestamp),\(b.pressureKPa),\(b.relativeAltitudeM)\n"
        }
        files.append(("barometric_readings.csv", Data(csv.utf8)))

        // Clinical lab results
        csv = "effective_date,loinc_code,test_name,value,unit,ref_range_low,ref_range_high,interpretation,source\n"
        for r in bundle.clinicalLabResults {
            csv += "\(r.effectiveDate),\(r.loincCode),\"\(escapeCsv(r.testName))\",\(r.value),\"\(r.unit)\","
            csv += "\(opt(r.referenceRangeLow)),\(opt(r.referenceRangeHigh)),\(opt(r.interpretation)),\"\(escapeCsv(r.sourceName ?? ""))\"\n"
        }
        files.append(("clinical_lab_results.csv", Data(csv.utf8)))

        // Pharmacies
        csv = "name,address,phone_number,latitude,longitude,notes,is_active\n"
        for p in bundle.pharmacies {
            csv += "\"\(escapeCsv(p.name))\",\"\(escapeCsv(p.address))\",\"\(escapeCsv(p.phoneNumber))\","
            csv += "\(opt(p.latitude)),\(opt(p.longitude)),\"\(escapeCsv(p.notes))\",\(p.isActive)\n"
        }
        files.append(("pharmacies.csv", Data(csv.utf8)))

        // Prescriptions
        csv = "rx_number,medication_name,dose_mg,dose_description,quantity,refills_remaining,"
        csv += "date_filled,estimated_run_out_date,pharmacy_name,notes,daily_dose_count\n"
        for rx in bundle.prescriptions {
            csv += "\"\(escapeCsv(rx.rxNumber))\",\"\(escapeCsv(rx.medicationName))\",\(rx.doseMg),"
            csv += "\"\(escapeCsv(rx.doseDescription))\",\(rx.quantity),\(rx.refillsRemaining),"
            csv += "\(rx.dateFilled),\(opt(rx.estimatedRunOutDate)),\"\(escapeCsv(rx.pharmacyName))\","
            csv += "\"\(escapeCsv(rx.notes))\",\(opt(rx.dailyDoseCount))\n"
        }
        files.append(("prescriptions.csv", Data(csv.utf8)))

        // Pharmacy call logs
        csv = "timestamp,direction,pharmacy_name,notes,duration_seconds\n"
        for c in bundle.pharmacyCallLogs {
            csv += "\(c.timestamp),\(c.direction),\"\(escapeCsv(c.pharmacyName))\","
            csv += "\"\(escapeCsv(c.notes))\",\(opt(c.durationSeconds))\n"
        }
        files.append(("pharmacy_call_logs.csv", Data(csv.utf8)))

        return files
    }

    // MARK: - Private

    private static func buildBundle(from context: ModelContext, start: Date?, end: Date?) throws -> ExportBundle {
        let entries = try context.fetch(FetchDescriptor<AnxietyEntry>(sortBy: [SortDescriptor(\.timestamp)]))
        let defs = try context.fetch(FetchDescriptor<MedicationDefinition>(sortBy: [SortDescriptor(\.name)]))
        let doses = try context.fetch(FetchDescriptor<MedicationDose>(sortBy: [SortDescriptor(\.timestamp)]))
        let cpap = try context.fetch(FetchDescriptor<CPAPSession>(sortBy: [SortDescriptor(\.date)]))
        let snapshots = try context.fetch(FetchDescriptor<HealthSnapshot>(sortBy: [SortDescriptor(\.date)]))
        let barometric = try context.fetch(FetchDescriptor<BarometricReading>(sortBy: [SortDescriptor(\.timestamp)]))
        let labResults = try context.fetch(FetchDescriptor<ClinicalLabResult>(sortBy: [SortDescriptor(\.effectiveDate)]))
        let pharmacies: [Pharmacy] = (try? context.fetch(FetchDescriptor<Pharmacy>(sortBy: [SortDescriptor(\.name)]))) ?? []
        let prescriptionsAll: [Prescription] = (try? context.fetch(FetchDescriptor<Prescription>(sortBy: [SortDescriptor(\.dateFilled)]))) ?? []
        let callLogs: [PharmacyCallLog] = (try? context.fetch(FetchDescriptor<PharmacyCallLog>(sortBy: [SortDescriptor(\.timestamp)]))) ?? []

        func inRange(_ date: Date) -> Bool {
            if let s = start, date < s { return false }
            if let e = end, date > e { return false }
            return true
        }

        return ExportBundle(
            exportDate: isoFormatter.string(from: .now),
            anxietyEntries: entries.filter { inRange($0.timestamp) }.map { e in
                AnxietyEntryDTO(timestamp: isoFormatter.string(from: e.timestamp),
                                severity: e.severity, notes: e.notes, tags: e.tags)
            },
            medicationDefinitions: defs.map { m in
                MedicationDefinitionDTO(name: m.name, defaultDoseMg: m.defaultDoseMg,
                                        category: m.category, isActive: m.isActive)
            },
            medicationDoses: doses.filter { inRange($0.timestamp) }.map { d in
                MedicationDoseDTO(timestamp: isoFormatter.string(from: d.timestamp),
                                  medicationName: d.medicationName, doseMg: d.doseMg, notes: d.notes)
            },
            cpapSessions: cpap.filter { inRange($0.date) }.map { s in
                CPAPSessionDTO(date: isoFormatter.string(from: s.date), ahi: s.ahi,
                               totalUsageMinutes: s.totalUsageMinutes, leakRate95th: s.leakRate95th,
                               pressureMin: s.pressureMin, pressureMax: s.pressureMax,
                               pressureMean: s.pressureMean, obstructiveEvents: s.obstructiveEvents,
                               centralEvents: s.centralEvents, hypopneaEvents: s.hypopneaEvents,
                               importSource: s.importSource)
            },
            healthSnapshots: snapshots.filter { inRange($0.date) }.map { h in
                HealthSnapshotDTO(date: isoFormatter.string(from: h.date), hrvAvg: h.hrvAvg,
                                  hrvMin: h.hrvMin, restingHR: h.restingHR,
                                  sleepDurationMin: h.sleepDurationMin, sleepDeepMin: h.sleepDeepMin,
                                  sleepREMMin: h.sleepREMMin, sleepCoreMin: h.sleepCoreMin,
                                  sleepAwakeMin: h.sleepAwakeMin, skinTempDeviation: h.skinTempDeviation,
                                  respiratoryRate: h.respiratoryRate, spo2Avg: h.spo2Avg,
                                  steps: h.steps, activeCalories: h.activeCalories,
                                  exerciseMinutes: h.exerciseMinutes,
                                  environmentalSoundAvg: h.environmentalSoundAvg,
                                  bpSystolic: h.bpSystolic, bpDiastolic: h.bpDiastolic,
                                  bloodGlucoseAvg: h.bloodGlucoseAvg)
            },
            barometricReadings: barometric.filter { inRange($0.timestamp) }.map { b in
                BarometricReadingDTO(timestamp: isoFormatter.string(from: b.timestamp),
                                     pressureKPa: b.pressureKPa, relativeAltitudeM: b.relativeAltitudeM)
            },
            clinicalLabResults: labResults.filter { inRange($0.effectiveDate) }.map { r in
                ClinicalLabResultDTO(
                    effectiveDate: isoFormatter.string(from: r.effectiveDate),
                    loincCode: r.loincCode, testName: r.testName,
                    value: r.value, unit: r.unit,
                    referenceRangeLow: r.referenceRangeLow, referenceRangeHigh: r.referenceRangeHigh,
                    interpretation: r.interpretation, sourceName: r.sourceName)
            },
            pharmacies: pharmacies.map { p in
                PharmacyDTO(name: p.name, address: p.address, phoneNumber: p.phoneNumber,
                            latitude: p.latitude, longitude: p.longitude,
                            notes: p.notes, isActive: p.isActive)
            },
            prescriptions: prescriptionsAll.filter { inRange($0.dateFilled) }.map { rx in
                PrescriptionDTO(rxNumber: rx.rxNumber, medicationName: rx.medicationName,
                                doseMg: rx.doseMg, doseDescription: rx.doseDescription,
                                quantity: rx.quantity, refillsRemaining: rx.refillsRemaining,
                                dateFilled: isoFormatter.string(from: rx.dateFilled),
                                estimatedRunOutDate: rx.estimatedRunOutDate.map { isoFormatter.string(from: $0) },
                                pharmacyName: rx.pharmacyName, notes: rx.notes,
                                dailyDoseCount: rx.dailyDoseCount,
                                prescriberName: rx.prescriberName, ndcCode: rx.ndcCode,
                                rxStatus: rx.rxStatus,
                                lastFillDate: rx.lastFillDate.map { isoFormatter.string(from: $0) },
                                importSource: rx.importSource, walgreensRxId: rx.walgreensRxId,
                                directions: rx.directions)
            },
            pharmacyCallLogs: callLogs.filter { inRange($0.timestamp) }.map { c in
                PharmacyCallLogDTO(timestamp: isoFormatter.string(from: c.timestamp),
                                   direction: c.direction, pharmacyName: c.pharmacyName,
                                   notes: c.notes, durationSeconds: c.durationSeconds)
            }
        )
    }

    private static func escapeCsv(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "\"\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func opt<T>(_ value: T?) -> String {
        value.map { "\($0)" } ?? ""
    }

    // MARK: - DTOs

    struct AnxietyEntryDTO: Codable {
        let timestamp: String; let severity: Int; let notes: String; let tags: [String]
    }
    struct MedicationDefinitionDTO: Codable {
        let name: String; let defaultDoseMg: Double; let category: String; let isActive: Bool
    }
    struct MedicationDoseDTO: Codable {
        let timestamp: String; let medicationName: String; let doseMg: Double; let notes: String?
    }
    struct CPAPSessionDTO: Codable {
        let date: String; let ahi: Double; let totalUsageMinutes: Int; let leakRate95th: Double
        let pressureMin: Double; let pressureMax: Double; let pressureMean: Double
        let obstructiveEvents: Int; let centralEvents: Int; let hypopneaEvents: Int
        let importSource: String
    }
    struct HealthSnapshotDTO: Codable {
        let date: String; let hrvAvg: Double?; let hrvMin: Double?; let restingHR: Double?
        let sleepDurationMin: Int?; let sleepDeepMin: Int?; let sleepREMMin: Int?
        let sleepCoreMin: Int?; let sleepAwakeMin: Int?; let skinTempDeviation: Double?
        let respiratoryRate: Double?; let spo2Avg: Double?; let steps: Int?
        let activeCalories: Double?; let exerciseMinutes: Int?
        let environmentalSoundAvg: Double?; let bpSystolic: Double?
        let bpDiastolic: Double?; let bloodGlucoseAvg: Double?
    }
    struct BarometricReadingDTO: Codable {
        let timestamp: String; let pressureKPa: Double; let relativeAltitudeM: Double
    }
    struct ClinicalLabResultDTO: Codable {
        let effectiveDate: String; let loincCode: String; let testName: String
        let value: Double; let unit: String
        let referenceRangeLow: Double?; let referenceRangeHigh: Double?
        let interpretation: String?; let sourceName: String?
    }
    struct PharmacyDTO: Codable {
        let name: String; let address: String; let phoneNumber: String
        let latitude: Double?; let longitude: Double?
        let notes: String; let isActive: Bool
    }
    struct PrescriptionDTO: Codable {
        let rxNumber: String; let medicationName: String; let doseMg: Double
        let doseDescription: String; let quantity: Int; let refillsRemaining: Int
        let dateFilled: String; let estimatedRunOutDate: String?
        let pharmacyName: String; let notes: String; let dailyDoseCount: Double?
        let prescriberName: String; let ndcCode: String; let rxStatus: String
        let lastFillDate: String?; let importSource: String; let walgreensRxId: String?
        let directions: String
    }
    struct PharmacyCallLogDTO: Codable {
        let timestamp: String; let direction: String; let pharmacyName: String
        let notes: String; let durationSeconds: Int?
    }
}
