import Foundation
import SwiftData

@Model
final class CPAPSession {
    enum ImportSource: String {
        case csv
        case caprx
        case manual
    }

    var source: ImportSource {
        get { ImportSource(rawValue: importSource) ?? .csv }
        set { importSource = newValue.rawValue }
    }

    var id: UUID
    var date: Date
    /// Apnea-Hypopnea Index — events per hour
    var ahi: Double
    var totalUsageMinutes: Int
    /// 95th percentile leak rate in L/min
    var leakRate95th: Double
    var pressureMin: Double
    var pressureMax: Double
    var pressureMean: Double
    var obstructiveEvents: Int
    var centralEvents: Int
    var hypopneaEvents: Int
    /// "sd_card" or "resmed_cloud"
    var importSource: String

    init(
        date: Date,
        ahi: Double,
        totalUsageMinutes: Int,
        leakRate95th: Double,
        pressureMin: Double,
        pressureMax: Double,
        pressureMean: Double,
        obstructiveEvents: Int,
        centralEvents: Int,
        hypopneaEvents: Int,
        importSource: String
    ) {
        self.id = UUID()
        // Normalize to start of day so filtering aligns with HealthSnapshot
        self.date = Calendar.current.startOfDay(for: date)
        self.ahi = ahi
        self.totalUsageMinutes = totalUsageMinutes
        self.leakRate95th = leakRate95th
        self.pressureMin = pressureMin
        self.pressureMax = pressureMax
        self.pressureMean = pressureMean
        self.obstructiveEvents = obstructiveEvents
        self.centralEvents = centralEvents
        self.hypopneaEvents = hypopneaEvents
        self.importSource = importSource
    }
}
