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
        seedJournalAndSongs(context, cal: cal)
        seedLabResults(context, cal: cal)
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

    private struct SleepFixture {
        let inBed: Int, latency: Int, awake: Int, deep: Int, rem: Int, core: Int
        var asleep: Int { deep + rem + core }
    }

    /// Deterministic, non-periodic-looking nightly architecture. Every consumer
    /// uses this helper so total sleep and stages reconcile exactly.
    private static func sleepFixture(_ n: Int) -> SleepFixture {
        let stress = 0.65 * sin(Double(n) * 0.73) + 0.35 * cos(Double(n) * 0.19)
        let disruption = (10...12).contains(n) ? 1.0 : 0
        let weekend = [1, 2].contains(n % 7) ? 1.0 : 0
        let inBed = Int((468 + 24 * weekend - 18 * stress - 48 * disruption + 17 * sin(Double(n) * 1.37)).rounded())
        let latency = max(5, min(40, Int((14 + 7 * max(0, stress) + 10 * disruption + 4 * cos(Double(n) * 1.11)).rounded())))
        let awake = max(9, min(68, Int((24 + 10 * max(0, stress) + 9 * disruption + 7 * sin(Double(n) * 0.91)).rounded())))
        let asleep = max(290, inBed - latency - awake)
        let deep = Int((Double(asleep) * max(0.12, min(0.21, 0.17 - 0.015 * stress + 0.018 * sin(Double(n) * 1.61)))).rounded())
        let rem = Int((Double(asleep) * max(0.18, min(0.28, 0.225 + 0.017 * cos(Double(n) * 1.23)))).rounded())
        return SleepFixture(inBed: inBed, latency: latency, awake: awake, deep: deep, rem: rem, core: asleep - deep - rem)
    }

    private static func seedSnapshots(_ ctx: ModelContext, day: (Int) -> Date) {
        for n in 0..<84 {
            let s = HealthSnapshot(date: day(n))
            let sleep = sleepFixture(n)
            let stress = 0.65 * sin(Double(n) * 0.73) + 0.35 * cos(Double(n) * 0.19)
            let disruption = (10...12).contains(n) ? 1.0 : 0
            let recovery = -0.55 * stress - 0.4 * disruption + 0.2 * sin(Double(n) * 0.31)
            s.hrvAvg = max(29, min(68, 48 + recovery * 7 + 2.8 * sin(Double(n) * 1.47)))
            s.restingHR = max(55, min(75, 62 + stress * 3 + disruption * 3 + 1.4 * cos(Double(n) * 1.17)))
            s.sleepDurationMin = sleep.asleep
            s.sleepDeepMin = sleep.deep; s.sleepREMMin = sleep.rem; s.sleepCoreMin = sleep.core
            s.sleepAwakeMin = sleep.awake
            s.respiratoryRate = max(12.7, min(16.7, 14.2 + stress * 0.45 + disruption * 0.35 + 0.25 * sin(Double(n) * 1.9)))
            let avgSpO2 = max(94.9, min(97.4, 96.3 - disruption * 0.35 + 0.35 * cos(Double(n) * 1.29)))
            let nadir = avgSpO2 - (2.7 + disruption * 1.2 + 0.8 * abs(sin(Double(n) * 0.83)))
            s.spo2Avg = avgSpO2; s.spo2NadirOvernight = nadir
            s.spo2TimeBelow90Min = nadir < 90 ? max(1, Int(((90 - nadir) * 1.2).rounded())) : 0
            s.spo2DesatsCount = max(1, Int((3 + disruption * 3 + 2 * abs(sin(Double(n) * 1.07))).rounded()))
            s.spo2AggregateBasis = .oximeter; s.spo2BurdenBasis = .oximeter
            let steps = max(2100, min(14200, Int((7000 - stress * 1100 - disruption * 1400 + 2300 * sin(Double(n) * 1.41)).rounded())))
            s.steps = steps
            s.exerciseMinutes = max(0, min(75, Int((Double(steps - 3500) / 220 + 7 * cos(Double(n) * 0.9)).rounded())))
            s.activeCalories = max(250, min(800, 225 + Double(steps) * 0.035 + Double(s.exerciseMinutes ?? 0) * 3.0))
            let glucose = max(89, min(112, 98 + stress * 2.2 + disruption * 3 + 2.4 * cos(Double(n) * 1.31)))
            let glucoseSD = max(12, min(24, 16 + stress * 1.8 + 1.5 * sin(Double(n))))
            s.bloodGlucoseAvg = glucose; s.glucoseStdDev = glucoseSD; s.glucoseCV = 100 * glucoseSD / glucose
            s.glucoseMin = max(72, glucose - glucoseSD); s.glucoseMax = min(148, glucose + 1.6 * glucoseSD)
            if ![3, 8, 15, 22, 31, 44, 58, 71].contains(n) {
                let dia = max(67, min(87, 75 + stress * 2 + 2 * sin(Double(n) * 1.7)))
                s.bpDiastolic = dia; s.bpSystolic = max(dia + 36, min(dia + 58, 118 + stress * 3 + 4 * cos(Double(n) * 1.13)))
            }
            s.barometricPressureAvgKPa = 101.2 + sin(Double(n) * 0.28) * 0.8
            s.barometricPressureChangeKPa = cos(Double(n) * 0.28) * 0.35
            s.environmentalSoundAvg = 56 + Double((n * 7) % 11)
            if n == 0 { s.atrialFibrillationBurden = 0.002 }
            s.syncedToServer = true
            ctx.insert(s)
        }
    }

    // MARK: - CPAP nights (most recent shares date with most-recent snapshot)

    private static func seedCPAP(_ ctx: ModelContext, day: (Int) -> Date) {
        for n in 0..<70 where ![2, 11, 27, 48].contains(n) {
            let sleep = sleepFixture(n)
            let disruption = (10...12).contains(n) ? 1.0 : 0
            let usage = max(250, sleep.asleep - 8 - (n * 13 % 24))
            let ahi = max(0.5, min(6.5, 2.1 + disruption * 1.8 + 0.7 * sin(Double(n) * 1.21)))
            let totalEvents = max(1, Int((ahi * Double(usage) / 60).rounded()))
            let central = totalEvents / 12
            let obstructive = Int((Double(totalEvents - central) * 0.43).rounded())
            let hypopnea = totalEvents - central - obstructive
            let leak = n == 16 ? 36.0 : max(8, min(29, 15 + 5 * sin(Double(n) * 0.87)))
            let s = CPAPSession(date: day(n), ahi: ahi, totalUsageMinutes: usage,
                                leakRate95th: leak, pressureMin: 6, pressureMax: 12,
                                pressureMean: 8.9 + disruption * 0.4 + 0.3 * cos(Double(n)),
                                obstructiveEvents: obstructive, centralEvents: central,
                                hypopneaEvents: hypopnea, importSource: "oscar")
            s.spo2Avg = 96.1 - disruption * 0.4 + 0.25 * cos(Double(n) * 1.3)
            s.pulseAvg = 60 + disruption * 3 + 2 * sin(Double(n) * 0.7)
            ctx.insert(s)
        }
    }

    // MARK: - Journal and recurring songs

    private static func seedJournalAndSongs(_ ctx: ModelContext, cal: Calendar) {
        let paper = Song(title: "Paper Satellites", artist: "The North Window", album: "Small Signals")
        let staticSummer = Song(title: "Static Summer", artist: "Harbor Lines", album: "Low Tide Radio")
        let hallway = Song(title: "Blue Hallway", artist: "Small Hours", album: "After Midnight")
        for song in [paper, staticSummer, hallway] { ctx.insert(song) }

        let rows: [(Int, Int, Int, String, [String], Song?, String?)] = [
            (0, 9, 3, "A little keyed up before the first meeting. A short task list helped.", ["work","morning"], nil, nil),
            (1, 16, 5, "Several messages arrived at once and I felt scattered.", ["work","overloaded"], nil, nil),
            (1, 17, 5, "A chorus has been looping in my head since lunch.", ["work","song-stuck"], paper, "Chorus repeating; neutral at first."),
            (3, 22, 4, "Tired but still mentally rehearsing tomorrow.", ["sleep","anticipation"], nil, nil),
            (5, 10, 2, "Quiet morning. Slept longer and feel more settled.", ["weekend","sleep"], nil, nil),
            (8, 15, 6, "Presentation ended, but the physical tension lingered.", ["work","presentation"], nil, nil),
            (8, 16, 5, "Shoulders feel less tight. Still a little distracted.", ["follow-up","work"], nil, nil),
            (12, 8, 4, "Rushed start after waking later than planned.", ["morning","sleep"], nil, nil),
            (12, 13, 3, "The same melody returned while making lunch.", ["song-stuck","midday"], staticSummer, "First recurrence this week."),
            (16, 18, 2, "A walk helped me shift out of work mode.", ["walk","evening"], nil, nil),
            (20, 21, 4, "Thinking about the upcoming week more than I want to.", ["anticipation","sleep"], nil, nil),
            (24, 10, 6, "Hard to focus while switching between several small tasks.", ["work","focus"], nil, nil),
            (24, 11, 4, "Follow-up: attention is steadier, though I still feel restless.", ["follow-up","work"], nil, nil),
            (29, 14, 3, "A short song fragment is stuck after hearing a similar melody.", ["song-stuck","music"], hallway, "Short fragment repeated for about 20 minutes."),
            (34, 13, 1, "Relaxed afternoon doing ordinary errands.", ["weekend","errands"], nil, nil),
            (40, 20, 7, "Busy day without much downtime. Thoughts feel crowded.", ["work","fatigue","evening"], nil, nil),
            (40, 21, 5, "Follow-up: less intense, but still reviewing the day.", ["follow-up","fatigue"], nil, nil),
            (47, 8, 3, "Woke earlier than expected. Mild tension, no clear trigger.", ["sleep","morning"], nil, nil),
            (48, 9, 4, "That same chorus returned again this morning.", ["song-stuck","recurrence"], paper, "Second logged recurrence, several weeks later."),
            (55, 17, 2, "Prepared a few things for tomorrow and feel reasonably settled.", ["planning","evening"], nil, nil)
        ]
        for (daysAgo, hour, severity, note, tags, song, occurrenceNote) in rows {
            let base = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: .now))!
            let ts = cal.date(byAdding: .minute, value: (daysAgo * 17) % 50, to: cal.date(byAdding: .hour, value: hour, to: base)!)!
            let entry = AnxietyEntry(timestamp: ts, severity: severity, notes: note, tags: tags,
                                     isFollowUp: tags.contains("follow-up"), source: daysAgo % 6 == 0 ? "random_checkin" : "user")
            ctx.insert(entry)
            if let song {
                let occurrence = SongOccurrence(timestamp: ts, source: entry.source == "random_checkin" ? "checkin" : "journal")
                occurrence.notes = occurrenceNote; occurrence.song = song; occurrence.anxietyEntry = entry
                ctx.insert(occurrence)
            }
        }
    }

    private static func seedLabResults(_ ctx: ModelContext, cal: Calendar) {
        let values: [(String,String,Double,String,Double,Double)] = [
            ("3016-3","Thyroid Stimulating Hormone",1.62,"mIU/L",0.4,4.0),
            ("3024-7","Free Thyroxine",1.18,"ng/dL",0.8,1.8),
            ("14979-9","Vitamin D, 25-Hydroxy",38,"ng/mL",30,100),
            ("2132-9","Vitamin B12",472,"pg/mL",200,900),
            ("2601-3","Magnesium",2.0,"mg/dL",1.7,2.2),
            ("2276-4","Ferritin",64,"ng/mL",30,300),
            ("2345-7","Fasting Glucose",94,"mg/dL",70,100),
            ("4548-4","Hemoglobin A1c",5.2,"%",0,5.7),
            ("30522-7","High-Sensitivity CRP",0.8,"mg/L",0,3.0)
        ]
        for (i, row) in values.enumerated() {
            ctx.insert(ClinicalLabResult(loincCode: row.0, testName: row.1, value: row.2, unit: row.3,
                effectiveDate: cal.date(byAdding: .day, value: -(2 + i % 3), to: .now)!,
                referenceRangeLow: row.4, referenceRangeHigh: row.5, interpretation: "N",
                sourceName: "Demo Regional Laboratory", healthKitSampleUUID: "demo-lab-\(i)"))
        }
    }

    // MARK: - HealthSample (7-day vitals tiles + today sparklines)

    private static func seedHealthSamples(_ ctx: ModelContext, cal: Calendar, today: Date) {
        func sample(_ type: String, _ value: Double, _ ts: Date) {
            ctx.insert(HealthSample(type: type, value: value, timestamp: ts, source: appleSource))
        }
        // Recent intraday points for the HR + SpO2 sparklines. Anchor the
        // newest observation near now so screenshots never imply a future
        // reading when captured before the former fixed 22:00 endpoint.
        let currentHour = cal.component(.hour, from: .now)
        for hoursAgo in stride(from: 14, through: 0, by: -2) {
            let ts = cal.date(byAdding: .hour, value: -hoursAgo, to: .now)!
            sample(HKQuantityTypeIdentifier.heartRate.rawValue, 64 + Double((hoursAgo * 7) % 22), ts)
            sample(HKQuantityTypeIdentifier.oxygenSaturation.rawValue, 0.96 + Double(hoursAgo % 3) * 0.01, ts)
        }
        // Daily points over the last week for the remaining tiles. Today's
        // value is also near now, avoiding a future-dated 09:00 sample.
        for n in 0..<7 {
            let dayDate = cal.date(byAdding: .day, value: -n, to: today)!
            let hour = n == 0 ? currentHour : 9
            let ts = cal.date(byAdding: .hour, value: hour, to: dayDate)!
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
        for n in 0..<14 {
            let sleep = sleepFixture(n)
            let bedTime = cal.date(byAdding: .minute, value: -(90 + (n * 11) % 45), to: day(n))!
            let inBedEnd = bedTime.addingTimeInterval(Double(sleep.inBed) * 60)
            ctx.insert(SleepStageEvent(startTime: bedTime, endTime: inBedEnd, stage: "inBed",
                                       sourceBundleID: appleSource, sourceName: "Apple Watch", syncedToServer: true))
            var cursor = bedTime
            func insert(_ stage: String, _ minutes: Int) {
                guard minutes > 0 else { return }
                let end = cursor.addingTimeInterval(Double(minutes) * 60)
                ctx.insert(SleepStageEvent(startTime: cursor, endTime: end, stage: stage,
                                           sourceBundleID: appleSource, sourceName: "Apple Watch", syncedToServer: true))
                cursor = end
            }
            insert("awake", sleep.latency)
            let core1 = sleep.core * 3 / 5, deep1 = sleep.deep * 2 / 3, rem1 = sleep.rem * 2 / 5
            insert("asleepCore", core1); insert("asleepDeep", deep1)
            insert("asleepCore", sleep.core - core1); insert("asleepREM", rem1)
            insert("asleepDeep", sleep.deep - deep1); insert("awake", sleep.awake)
            insert("asleepREM", sleep.rem - rem1)
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
