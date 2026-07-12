#if DEBUG
import Foundation
import SwiftData
import HealthKit
import os

/// Populates the store with obviously-fictional demo data for README /
/// marketing screenshots of the app as it exists today. DEBUG + simulator
/// only, triggered by the `-seedDemoData` launch argument (see `SeedDemoMode`).
///
/// Distinct from `-autoRestoreFromServer` (which pulls the owner's REAL server
/// data with shifted dates): this seeds synthetic values so nothing personal
/// appears in published screenshots. All values are illustrative; medication
/// names are public drug names per the project's fictional-data rules.
///
/// Dates anchor to `.now` so the app renders as "current". The seeder is
/// idempotent (only runs on an empty store), marks backfill done, and resolves
/// the restore-migration gate so the Dashboard renders immediately without the
/// "Restore vs Start Fresh" prompt.
enum DemoSeeder {
    private static let backfillKey = "hasBackfilledSnapshots_v3"
    private static let appleSource = "com.apple.health"

    @MainActor
    static func seedIfNeeded(container: ModelContainer) {
        let context = ModelContext(container)
        guard SyncService.restoreGuardTablesAreEmpty(context) else { return }

        // Don't let HealthKit backfill / the migration gate interfere.
        UserDefaults.standard.set(true, forKey: backfillKey)
        RestoreMigrationGate.resolve()

        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: today)! }

        seedMedications(context, cal: cal, today: today, day: day)
        seedSnapshots(context, day: day)
        seedCPAP(context, day: day)
        seedAnxiety(context, cal: cal, today: today)
        seedHealthSamples(context, cal: cal, today: today)
        seedSleepStages(context, cal: cal, day: day)
        seedBarometric(context, cal: cal, today: today)
        seedPolarNights(context, cal: cal, today: today)
        seedCorrelations(context)

        do { try context.save() } catch {
            Log.data.error("[DemoSeeder] save failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Medications, pharmacy, prescription

    @MainActor
    private static func seedMedications(_ ctx: ModelContext, cal: Calendar, today: Date, day: (Int) -> Date) {
        // Deliberately generic, common medications — NOT the maintainer's real
        // regimen — so published demo screenshots don't showcase it.
        let prn = MedicationDefinition(name: "Hydroxyzine 25mg", defaultDoseMg: 25,
                                       category: "anxiolytic", isActive: true, promptAnxietyOnLog: true)
        let sert = MedicationDefinition(name: "Sertraline 50mg", defaultDoseMg: 50,
                                        category: "SSRI", isActive: true)
        ctx.insert(prn); ctx.insert(sert)

        // Daily Sertraline (mornings) + intermittent PRN Hydroxyzine.
        for n in 0..<30 {
            let morning = cal.date(byAdding: .hour, value: 8, to: day(n))!
            ctx.insert(MedicationDose(timestamp: morning, medicationName: "Sertraline 50mg",
                                      doseMg: 50, isPRN: false, medication: sert))
            if n % 4 == 1 {   // PRN a couple times a week
                let evening = cal.date(byAdding: .hour, value: 21, to: day(n))!
                ctx.insert(MedicationDose(timestamp: evening, medicationName: "Hydroxyzine 25mg",
                                          doseMg: 25, isPRN: true, medication: prn))
            }
        }
        // A dose within the last few hours drives the "Last Medication" row.
        ctx.insert(MedicationDose(timestamp: cal.date(byAdding: .hour, value: -3, to: .now)!,
                                  medicationName: "Sertraline 50mg", doseMg: 50, isPRN: false, medication: sert))

        let pharmacy = Pharmacy(name: "Test Pharmacy #12345",
                                address: "100 Example Blvd, Anytown, ST 00000", phoneNumber: "555-0100")
        ctx.insert(pharmacy)
        ctx.insert(Prescription(rxNumber: "9999999-00001", medicationName: "Sertraline 50mg",
                                doseMg: 50, dateFilled: day(6),
                                pharmacyName: "Test Pharmacy #12345",
                                medication: sert, pharmacy: pharmacy))
    }

    // MARK: - Daily HealthSnapshots (baselines, sleep, glucose, BP, etc.)

    private static func seedSnapshots(_ ctx: ModelContext, day: (Int) -> Date) {
        for n in 0..<60 {
            let s = HealthSnapshot(date: day(n))
            let wobble = sin(Double(n) / 4)
            // HRV: healthy ~38-52, but the last 3 nights dip to fire the baseline alert.
            s.hrvAvg = n < 3 ? 24 + Double(n) : 45 + wobble * 6
            s.restingHR = n < 3 ? 70 - Double(n) : 60 + cos(Double(n) / 5) * 3
            let dur = 420 + Int(wobble * 40)
            s.sleepDurationMin = dur
            s.sleepDeepMin = 65 + (n % 4) * 4
            s.sleepREMMin = 90 + (n % 5) * 4
            s.sleepCoreMin = 220 + (n % 6) * 6
            s.sleepAwakeMin = 20 + (n % 3) * 6
            s.respiratoryRate = 14.2 + wobble * 0.6
            s.spo2Avg = 96 + cos(Double(n) / 6)
            s.spo2NadirOvernight = 89 + Double(n % 3)
            s.spo2TimeBelow90Min = 3 + (n % 5)
            s.spo2DesatsCount = 4 + (n % 6)
            s.spo2AggregateBasis = .oximeter
            s.spo2BurdenBasis = .oximeter
            s.steps = 5200 + (n % 6) * 1200
            s.activeCalories = 340 + Double(n % 5) * 55
            s.exerciseMinutes = 18 + (n % 4) * 10
            s.bloodGlucoseAvg = 98 + cos(Double(n) / 7) * 6
            s.glucoseMin = 80 + Double(n % 4)
            s.glucoseMax = 128 + Double(n % 6) * 5
            s.glucoseCV = 20 + Double(n % 5)
            s.glucoseStdDev = 17 + Double(n % 4)
            if n % 2 == 0 {   // BP on alternating days
                s.bpSystolic = 118 + Double(n % 5)
                s.bpDiastolic = 75 + Double(n % 4)
            }
            s.barometricPressureAvgKPa = 101.0 + wobble * 0.6
            s.barometricPressureChangeKPa = wobble * 0.4
            s.environmentalSoundAvg = 58 + Double(n % 6)
            if n == 0 { s.atrialFibrillationBurden = 0.002 }
            s.syncedToServer = true
            ctx.insert(s)
        }
    }

    // MARK: - CPAP nights (most recent shares date with most-recent snapshot)

    private static func seedCPAP(_ ctx: ModelContext, day: (Int) -> Date) {
        for n in 0..<20 {
            let s = CPAPSession(date: day(n), ahi: 1.8 + Double(n % 5) * 0.6,
                                totalUsageMinutes: 400 + (n % 4) * 18, leakRate95th: 13 + Double(n % 5) * 2,
                                pressureMin: 6, pressureMax: 12, pressureMean: 9.4 + Double(n % 3) * 0.2,
                                obstructiveEvents: 1 + n % 5, centralEvents: n % 2, hypopneaEvents: 1 + n % 3,
                                importSource: "oscar")
            s.spo2Avg = 94 + Double(n % 3)
            s.pulseAvg = 59 + Double(n % 4)
            ctx.insert(s)
        }
    }

    // MARK: - Anxiety entries

    private static func seedAnxiety(_ ctx: ModelContext, cal: Calendar, today: Date) {
        let tagSets = [["work"], ["sleep"], ["social", "caffeine"], ["work", "sleep"], []]
        for i in 0..<20 {
            let ts = cal.date(byAdding: .hour, value: -(i * 34 + 4), to: .now)!
            let severity = 2 + Int(abs(sin(Double(i))) * 6)
            let source = i % 7 == 0 ? "random_checkin" : "user"
            ctx.insert(AnxietyEntry(timestamp: ts, severity: severity, notes: "",
                                    tags: tagSets[i % tagSets.count], source: source))
        }
    }

    // MARK: - HealthSample (7-day vitals tiles + today sparklines)

    private static func seedHealthSamples(_ ctx: ModelContext, cal: Calendar, today: Date) {
        func sample(_ type: String, _ value: Double, _ ts: Date) {
            ctx.insert(HealthSample(type: type, value: value, timestamp: ts, source: appleSource))
        }
        // Today's intraday points for the HR + SpO2 sparklines.
        for h in stride(from: 7, through: 22, by: 2) {
            let ts = cal.date(byAdding: .hour, value: h, to: today)!
            sample(HKQuantityTypeIdentifier.heartRate.rawValue, 64 + Double((h * 7) % 22), ts)
            sample(HKQuantityTypeIdentifier.oxygenSaturation.rawValue, 0.96 + Double(h % 3) * 0.01, ts)
        }
        // Daily points over the last week for the remaining tiles.
        for n in 0..<7 {
            let ts = cal.date(byAdding: .hour, value: 9, to: cal.date(byAdding: .day, value: -n, to: today)!)!
            sample(HKQuantityTypeIdentifier.restingHeartRate.rawValue, 66 + Double(n % 4), ts)
            sample(HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue, 30 + Double(n % 5), ts)
            sample(HKQuantityTypeIdentifier.respiratoryRate.rawValue, 14 + Double(n % 2) * 0.5, ts)
            sample(HKQuantityTypeIdentifier.walkingHeartRateAverage.rawValue, 98 + Double(n % 5) * 2, ts)
            sample(HKQuantityTypeIdentifier.bloodGlucose.rawValue, 96 + Double(n % 4) * 3, ts)
            sample(HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue, 120, ts)
            sample(HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue, 78, ts)
        }
        let recent = cal.date(byAdding: .hour, value: 10, to: today)!
        sample(HKQuantityTypeIdentifier.vo2Max.rawValue, 41, recent)
        sample(HKQuantityTypeIdentifier.appleWalkingSteadiness.rawValue, 0.82, recent)
    }

    // MARK: - Sleep stages for the last 3 nights (noon-to-noon window)

    private static func seedSleepStages(_ ctx: ModelContext, cal: Calendar, day: (Int) -> Date) {
        let stages: [(String, Int)] = [
            ("inBed", 460), ("asleepCore", 120), ("asleepDeep", 55), ("asleepREM", 90),
            ("awake", 20), ("asleepCore", 100), ("asleepREM", 40)
        ]
        for n in 0..<3 {
            // Night belonging to snapshot day(n): prior evening ~22:30 into the morning.
            var cursor = cal.date(byAdding: .minute, value: -90, to: day(n))!   // 22:30 previous day
            for (stage, minutes) in stages {
                let end = cursor.addingTimeInterval(Double(minutes) * 60)
                ctx.insert(SleepStageEvent(startTime: cursor, endTime: end, stage: stage,
                                           sourceBundleID: appleSource, sourceName: "Apple Watch",
                                           syncedToServer: true))
                if stage != "inBed" { cursor = end }   // inBed spans the whole night in parallel
            }
        }
    }

    // MARK: - Barometric readings (last 30 days, every 2 hours)

    private static func seedBarometric(_ ctx: ModelContext, cal: Calendar, today: Date) {
        // 30 days so the Barometric trend card fills the 30-day window. A slow
        // diurnal wave plus a weather-front pressure drop/recovery mid-window
        // gives the line some shape instead of a flat band. Date math goes
        // through Calendar (not raw 86400/3600 arithmetic) so a DST boundary in
        // the window doesn't drift the timestamps.
        let days = 30
        let steps = days * 12   // one reading every 2 hours
        let start = cal.date(byAdding: .day, value: -days, to: today)!
        let frontCenter = Double(steps) * 0.6
        for i in 0..<steps {
            let ts = cal.date(byAdding: .hour, value: i * 2, to: start)!
            let diurnal = sin(Double(i) / 6) * 0.4
            let front = -1.6 * exp(-pow((Double(i) - frontCenter) / 18, 2))   // passing front
            ctx.insert(BarometricReading(timestamp: ts,
                                         pressureKPa: 101.3 + diurnal + front,
                                         relativeAltitudeM: cos(Double(i) / 6) * 4))
        }
    }

    // MARK: - Polar H10 overnight HRV nights (last 28 nights)

    private static func seedPolarNights(_ ctx: ModelContext, cal: Calendar, today: Date) {
        // One overnight session per night so the RMSSD / HF-Power overnight
        // trend cards (one point per night) and the SDNN chart's purple Polar
        // overlay fill the window. Readings are every 3 minutes — enough for a
        // faithful overnight aggregate without materializing per-second rows.
        for nightIdx in 0..<28 {
            let nightsAgo = nightIdx + 1
            let midnight = cal.date(byAdding: .day, value: -nightsAgo, to: today)!
            let bedTime = cal.date(byAdding: .hour, value: 23, to: midnight)!   // ~23:00
            let minutes = 360 + (nightIdx % 3) * 15   // >3h so it clears the overnight threshold

            // Healthy parasympathetic baselines with a slow wobble, dipping over
            // the three most recent nights. EVERY overlaid series feeding a chart
            // gets the same dip — rmssd, hf AND sdnn — so the RMSSD/HF cards and
            // the SDNN chart's Polar overlay all agree with the Dashboard's
            // "HRV below baseline" story instead of one line staying flat.
            let recentDip = nightsAgo <= 3 ? -16.0 : 0
            let hfBase = 56 + sin(Double(nightIdx) / 5) * 8 + recentDip
            let rmssdBase = 44 + sin(Double(nightIdx) / 5) * 6 + recentDip * 0.5
            let sdnnBase = 52 + sin(Double(nightIdx) / 5) * 7 + recentDip

            let session = SensorSession(startTime: bedTime, batteryAtStart: 80 + nightIdx % 15)
            session.endTime = bedTime.addingTimeInterval(Double(minutes) * 60)
            session.source = PolarHRMService.sourceLabel
            // Match the real recorder's summary schema (hrMean + rmssdMean +
            // rrCount) so the Dashboard's "Last session" card renders fully.
            session.summaryJSON = "{\"hrMean\": \(57 + nightIdx % 6), "
                + "\"rmssdMean\": \(Int(rmssdBase.rounded())), \"rrCount\": \(minutes * 55)}"
            session.syncedToServer = true
            ctx.insert(session)

            for m in stride(from: 0, to: minutes, by: 3) {
                let sentinel = (m % 24) == 0
                let hf = sentinel ? 0 : max(4, hfBase + sin(Double(m) / 30) * 10)
                let lf = sentinel ? 0 : hf * 1.8 + cos(Double(m) / 30) * 15
                ctx.insert(HRVReading(timestamp: bedTime.addingTimeInterval(Double(m) * 60),
                                      rmssd: max(6, rmssdBase + Double(m % 8) - 3),
                                      sdnn: max(10, sdnnBase + Double(m % 10) - 5), pnn50: 10 + Double(m % 5),
                                      lfPower: lf, hfPower: hf, lfHfRatio: (sentinel || hf == 0) ? 0 : lf / hf,
                                      sensorSessionID: session.id, source: PolarHRMService.sourceLabel))
            }
        }
    }

    // MARK: - Correlation insights (synthetic computed results)

    private static func seedCorrelations(_ ctx: ModelContext) {
        // The correlation compute job doesn't run in demo mode, so seed
        // plausible results directly to render the populated Insights list.
        // Illustrative strengths/directions only — not real findings.
        let now = Date.now
        func corr(_ name: String, _ r: Double, _ p: Double, _ n: Int, abnormal: Double, normal: Double) {
            ctx.insert(PhysiologicalCorrelation(signalName: name, correlation: r, pValue: p,
                                                sampleCount: n, meanSeverityWhenAbnormal: abnormal,
                                                meanSeverityWhenNormal: normal, computedAt: now))
        }
        corr("sleep_duration_min", -0.61, 0.001, 28, abnormal: 6.2, normal: 3.2)
        corr("hrv_avg", -0.57, 0.002, 28, abnormal: 6.0, normal: 3.4)
        corr("resting_hr", 0.46, 0.008, 28, abnormal: 5.5, normal: 3.6)
        corr("sleep_quality_ratio", -0.44, 0.01, 28, abnormal: 5.6, normal: 3.5)
        corr("cpap_ahi", 0.39, 0.02, 20, abnormal: 5.2, normal: 3.9)
        corr("steps", -0.33, 0.04, 28, abnormal: 5.1, normal: 4.0)
    }
}
#endif
