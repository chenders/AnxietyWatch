import Foundation
import SwiftData

@Model
final class CPAPSession {
    enum ImportSource: String {
        case csv
        case caprx
        case manual
        case oscar
    }

    var source: ImportSource {
        get { ImportSource(rawValue: importSource) ?? .csv }
        set { importSource = newValue.rawValue }
    }

    var id: UUID
    #Unique<CPAPSession>([\.date])
    var date: Date
    /// Apnea-Hypopnea Index — events per hour. `nil` when the source recorded
    /// usage/leak/pressure but no scored AHI (EDF-only nights: the server
    /// stores NULL rather than a fabricated 0, F-068). Distinct from `0.0`,
    /// which is a real, perfect night. Consumers must treat `nil` as "unknown"
    /// (show "—", exclude from averages) — never coerce it to 0 (F-094).
    var ahi: Double?
    var totalUsageMinutes: Int
    /// 95th percentile leak rate in L/min (nil when not available, e.g. OSCAR CSV import)
    var leakRate95th: Double?
    var pressureMin: Double
    var pressureMax: Double
    var pressureMean: Double
    var obstructiveEvents: Int
    var centralEvents: Int
    var hypopneaEvents: Int
    /// Raw string backing the `source` enum — "csv", "oscar", "caprx", "edf", or "manual".
    var importSource: String

    // MARK: - By-session import fields (OSCAR by-session CSV)
    //
    // All eight fields below were added for the OSCAR by-session import and
    // share one contract: `nil` means "the source did not report this value"
    // — never coerce to 0 and never drop the field. A user whose machine has
    // no attached oximeter reports empty SpO2/pulse columns; another user's
    // machine may fill them. Defaults are nil so the SwiftData lightweight
    // migration adds the columns without touching existing rows.

    /// Respiratory Disturbance Index — events per hour (a rate, like AHI,
    /// not a count). Includes RERAs on top of apneas/hypopneas.
    var rdiEvents: Double?
    /// Respiratory Effort-Related Arousal count for the day (events, not a rate).
    var reraEvents: Int?
    /// Usage-weighted average SpO2 in % (machine-attached oximeter).
    var spo2Avg: Double?
    /// Minimum SpO2 in % across the day's sessions (machine-attached oximeter).
    var spo2Min: Double?
    /// Usage-weighted average pulse rate in bpm (machine-attached oximeter).
    var pulseAvg: Double?
    /// 95th percentile pressure in cmH2O (usage-weighted across sessions).
    var pressure95th: Double?
    /// Average leak rate in L/min (usage-weighted across sessions).
    var leakAvg: Double?
    /// Maximum leak rate in L/min across the day's sessions.
    var leakMax: Double?

    init(
        date: Date,
        ahi: Double?,
        totalUsageMinutes: Int,
        leakRate95th: Double? = nil,
        pressureMin: Double,
        pressureMax: Double,
        pressureMean: Double,
        obstructiveEvents: Int,
        centralEvents: Int,
        hypopneaEvents: Int,
        importSource: String,
        rdiEvents: Double? = nil,
        reraEvents: Int? = nil,
        spo2Avg: Double? = nil,
        spo2Min: Double? = nil,
        pulseAvg: Double? = nil,
        pressure95th: Double? = nil,
        leakAvg: Double? = nil,
        leakMax: Double? = nil
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
        self.rdiEvents = rdiEvents
        self.reraEvents = reraEvents
        self.spo2Avg = spo2Avg
        self.spo2Min = spo2Min
        self.pulseAvg = pulseAvg
        self.pressure95th = pressure95th
        self.leakAvg = leakAvg
        self.leakMax = leakMax
    }
}
