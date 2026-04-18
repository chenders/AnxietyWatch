import Foundation
import SwiftData

/// Daily aggregation of HealthKit data. One row per calendar day.
/// HealthKit remains the source of truth — this is a cache for efficient trending.
@Model
final class HealthSnapshot {
    var id: UUID
    #Unique<HealthSnapshot>([\.date])
    var date: Date

    // HRV (SDNN, milliseconds)
    var hrvAvg: Double?
    var hrvMin: Double?

    // Heart rate
    var restingHR: Double?

    // Sleep (minutes)
    var sleepDurationMin: Int?
    var sleepDeepMin: Int?
    var sleepREMMin: Int?
    var sleepCoreMin: Int?
    var sleepAwakeMin: Int?

    // Overnight metrics
    var skinTempDeviation: Double?
    /// Raw absolute wrist temperature during sleep (°C, typically 35–37).
    /// skinTempDeviation is computed from the rolling baseline of this value.
    var skinTempWrist: Double?
    var respiratoryRate: Double?
    var spo2Avg: Double?

    // Activity
    var steps: Int?
    var activeCalories: Double?
    var exerciseMinutes: Int?

    // Environment
    var environmentalSoundAvg: Double?

    // Blood pressure (if available)
    var bpSystolic: Double?
    var bpDiastolic: Double?

    // Blood glucose (if available, mg/dL)
    var bloodGlucoseAvg: Double?

    // Cardiorespiratory fitness
    var vo2Max: Double?

    // Walking metrics
    var walkingHeartRateAvg: Double?
    var walkingSteadiness: Double?

    // Atrial fibrillation
    var atrialFibrillationBurden: Double?

    // Audio exposure
    var headphoneAudioExposure: Double?

    // Gait metrics
    var walkingSpeed: Double?
    var walkingStepLength: Double?
    var walkingDoubleSupportPct: Double?
    var walkingAsymmetryPct: Double?

    // Daylight and effort (iOS 17+ / watchOS 10+)
    var timeInDaylightMin: Int?
    var physicalEffortAvg: Double?

    // CPAP (matched from CPAPSession by date)
    var cpapAHI: Double?
    var cpapUsageMinutes: Int?

    // Barometric (aggregated from BarometricReading by date)
    var barometricPressureAvgKPa: Double?
    var barometricPressureChangeKPa: Double?

    init(date: Date) {
        self.id = UUID()
        // Normalize to start of day so the unique constraint works on calendar days
        self.date = Calendar.current.startOfDay(for: date)
    }
}
