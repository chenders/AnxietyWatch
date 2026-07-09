import Foundation
import SwiftData

/// Which sample population a group of overnight SpO₂ metrics was actually
/// computed from (F-092). Recorded per-snapshot so clinical surfaces can
/// disclose when the avg/nadir and the T90/desaturation counts describe
/// DIFFERENT source populations — e.g. a brief oximeter connection set the
/// nadir from a handful of samples while an all-night Apple Watch spot-check
/// set the T90 from the broader mixed set. Each field is individually correct
/// against its own sufficiency gate; the hazard is presenting them together,
/// undisclosed, as one coherent overnight profile.
enum SpO2SourceBasis: String, Codable, Sendable, CaseIterable {
    /// Computed from the dedicated overnight pulse-oximeter subset only
    /// (EMAY / Wellue), after the source-precedence override.
    case oximeter
    /// Computed from the HealthKit-direct aggregate over whatever sources
    /// HealthKit reported for the window — either no oximeter covered it, or
    /// the oximeter subset was too sparse for this metric's sufficiency gate
    /// so the HK-direct value was retained. NOTE: this may in practice be
    /// Apple-Watch-only — CSV-imported oximeter sessions live only in
    /// SwiftData and never reach the HealthKit query this value comes from —
    /// so the label deliberately names the data source ("Apple Health") rather
    /// than claiming a multi-device blend, which would overstate corroboration
    /// to a clinician.
    case mixed

    /// Short label for clinical surfaces (card footnote, PDF annotation).
    var label: String {
        switch self {
        case .oximeter: return "pulse oximeter"
        case .mixed: return "Apple Health"
        }
    }
}

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
    /// Lowest SpO2 (%) during overnight window — single most clinically
    /// interesting value. Populated with the preferred (overnight oximeter)
    /// nadir when an EMAY/Wellue device covered the window; falls back to
    /// the opportunistic (Apple Watch) nadir only when no dedicated device
    /// was present. See `DeviceProvenance.partition(samples:metricType:)`.
    var spo2NadirOvernight: Double?
    /// Apple-Watch-only nadir for the same window — kept separately so the
    /// trends chart can plot a second line showing the Apple Watch source
    /// for nights where both devices have data. Nil when no opportunistic
    /// SpO2 samples exist for the window.
    var spo2NadirOpportunistic: Double?
    /// Minutes spent below 90% during overnight window (T90 — hypoxic burden).
    /// Computed from the preferred (oximeter) subset when it clears the
    /// continuous-monitoring sufficiency gate; otherwise retains the
    /// HealthKit-direct mixed-source value (F-023). Which basis was used is
    /// recorded in `spo2BurdenBasis` and can differ from `spo2AggregateBasis`
    /// (F-092).
    var spo2TimeBelow90Min: Int?
    /// Rough ODI-style desaturation event count overnight. Not clinical-grade ODI4 —
    /// manufacturer-app reports remain authoritative; this is for trending only.
    /// Same source basis as `spo2TimeBelow90Min` — see `spo2BurdenBasis`.
    var spo2DesatsCount: Int?

    /// Source basis for `spo2Avg` / `spo2NadirOvernight` (F-092). Stored as
    /// the `SpO2SourceBasis` raw value; use `spo2AggregateBasis` for typed
    /// access. Nil when no avg/nadir was computed for the window.
    var spo2AggregateSource: String?
    /// Source basis for `spo2TimeBelow90Min` / `spo2DesatsCount` (F-092).
    /// Can differ from `spo2AggregateSource` on a night where a sparse
    /// oximeter set the nadir but only the mixed HK-direct set was dense
    /// enough for the burden stats. Nil when no T90/desats were computed.
    var spo2BurdenSource: String?

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
    /// Glucose standard deviation (mg/dL) — variability magnitude.
    var glucoseStdDev: Double?
    /// Coefficient of variation (%) — normalized glycemic variability; clinical target <36%.
    var glucoseCV: Double?
    /// Lowest reading of the day (mg/dL).
    var glucoseMin: Double?
    /// Highest reading of the day (mg/dL).
    var glucoseMax: Double?

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

    // Sensor-derived (from Ultra 3 sensor capture session)
    var nocturnalHRDip: Double?         // 1 - (sleepHR / wakingHR); <0.1 = impaired
    var tremorBandPowerAvg: Double?     // Daily avg 4–12Hz spectral power
    var breathingRateAvg: Double?       // Daily avg breaths/min from accelerometer
    var fidgetIndexAvg: Double?         // Daily avg 0.5–4Hz spectral power

    /// JSON-encoded `[metricFamily: {reliability, sources}]` describing the
    /// reliability tier and per-bundle-ID sample counts for this day. Computed
    /// by `SnapshotAggregator` from the local `QuantityHealthSample` mirror.
    /// Surfaced in the Claude prompt and Glucose Detail UI.
    var dataQuality: String?

    /// Dirty flag for sync. `SnapshotAggregator.aggregateDay` flips this to
    /// `false` only when re-aggregation actually changes an aggregate field
    /// (compared via `SnapshotFingerprint`), not on every touch — today's
    /// snapshot would otherwise re-upload on every observer trigger and
    /// app launch. Sync uploads all rows where `!syncedToServer` (regardless
    /// of date) and the post-upload step flips it back to `true`.
    ///
    /// Default `true` so SwiftData lightweight migration treats existing rows
    /// (which were uploaded with the prior date-range-filtered sync path) as
    /// clean. Re-aggregation with new precedence logic produces different
    /// field values, the fingerprint diff catches it, and the row gets
    /// re-uploaded — closing the gap where the old date-range filter
    /// silently dropped past-day corrections from the sync payload.
    var syncedToServer: Bool = true

    /// Monotonic counter bumped by `SnapshotAggregator.aggregateDay`
    /// alongside every `syncedToServer = false` flip — i.e. exactly when a
    /// fingerprint diff fires. Sync includes this value in the payload and
    /// the post-upload `flagSnapshotsSynced` step only marks a row clean if
    /// its current `pendingSyncVersion` STILL matches the uploaded value.
    ///
    /// Closes the race where `sync()` is suspended on
    /// `URLSession.shared.data(for:)` while
    /// `HealthDataCoordinator.scheduleRefresh` runs `aggregateDay` on the
    /// main actor: the in-flight aggregation can mutate snapshot fields
    /// after the payload was built but before `flagSnapshotsSynced` runs.
    /// Without this token, the post-upload flip would mark the row
    /// `syncedToServer = true` and the new changes would only re-sync the
    /// next time some other mutation happened to bump the dirty flag.
    var pendingSyncVersion: Int = 0

    init(date: Date) {
        self.id = UUID()
        // Normalize to start of day so the unique constraint works on calendar days
        self.date = Calendar.current.startOfDay(for: date)
        // Freshly-created snapshots must reach the server. The property
        // default of `true` exists only so SwiftData lightweight migration
        // doesn't mark every pre-existing row dirty on first launch.
        self.syncedToServer = false
    }

    // MARK: - SpO₂ source-provenance (F-092)

    /// Typed accessor for `spo2AggregateSource` (avg/nadir basis).
    var spo2AggregateBasis: SpO2SourceBasis? {
        get { spo2AggregateSource.flatMap(SpO2SourceBasis.init(rawValue:)) }
        set { spo2AggregateSource = newValue?.rawValue }
    }

    /// Typed accessor for `spo2BurdenSource` (T90/desats basis).
    var spo2BurdenBasis: SpO2SourceBasis? {
        get { spo2BurdenSource.flatMap(SpO2SourceBasis.init(rawValue:)) }
        set { spo2BurdenSource = newValue?.rawValue }
    }

    /// True when the avg/nadir and the T90/desat counts were computed from
    /// DIFFERENT source populations and BOTH are present — the F-092 case a
    /// clinical surface must disclose. When either basis is nil (that metric
    /// group wasn't computed) there is nothing to reconcile, so it is not a
    /// divergence.
    var spo2SourcesDiverge: Bool {
        guard let agg = spo2AggregateBasis, let burden = spo2BurdenBasis else { return false }
        return agg != burden
    }
}
