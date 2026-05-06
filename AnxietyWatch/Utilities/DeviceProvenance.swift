import Foundation

/// Reliability tier for a daily aggregate, based on writing-source identity and sample density.
/// See `docs/superpowers/specs/2026-05-05-cgm-spo2-provenance-design.md` for thresholds.
enum Reliability: String, Codable {
    case high
    case medium
    case low
    case insufficient
}

/// Bundle-ID classification + display-name lookup for HealthKit writing sources.
/// New device = list-entry edit.
enum DeviceProvenance {
    static let continuousGlucoseMonitors: Set<String> = [
        "com.dexcom.stelo",
        "com.dexcom.cgm",
        "com.dexcom.G6",
        "com.dexcom.G7",
        "com.abbottdiabetescare.libre2",
        "com.abbottdiabetescare.libre3"
    ]

    static let overnightPulseOximeters: Set<String> = [
        "com.emay.sleepo2",
        "com.emay.SleepO2",
        "io.wellue.health",
        "com.viatomtech.wellue.O2Ring"
    ]

    /// Apple ecosystem writers — Apple Watch HR/HRV/RR/wrist-temp samples and any manual
    /// entries written through Apple Health. Used as the "Apple Watch only" cohort for
    /// SpO₂ and as the manual-entry signal for blood pressure.
    static let appleEcosystemSources: Set<String> = [
        "com.apple.health",
        "com.apple.Health"
    ]

    static let medicalGradeBPCuffs: Set<String> = [
        "com.withings.wiscale2",
        "com.omronhealthcare.OmronConnect",
        "com.qardio.app"
    ]

    static func isContinuousGlucoseMonitor(_ bundleID: String) -> Bool {
        continuousGlucoseMonitors.contains(bundleID)
    }

    static func isOvernightPulseOximeter(_ bundleID: String) -> Bool {
        overnightPulseOximeters.contains(bundleID)
    }

    static func isAppleEcosystemSource(_ bundleID: String) -> Bool {
        appleEcosystemSources.contains(bundleID)
    }

    static func isMedicalGradeBPCuff(_ bundleID: String) -> Bool {
        medicalGradeBPCuffs.contains(bundleID)
    }

    static func displayName(for bundleID: String) -> String {
        switch bundleID {
        case "com.dexcom.stelo": return "Stelo"
        case "com.dexcom.cgm": return "Dexcom"
        case "com.dexcom.G6": return "Dexcom G6"
        case "com.dexcom.G7": return "Dexcom G7"
        case "com.abbottdiabetescare.libre2": return "FreeStyle Libre 2"
        case "com.abbottdiabetescare.libre3": return "FreeStyle Libre 3"
        case "com.emay.sleepo2", "com.emay.SleepO2": return "EMAY SleepO2"
        case "io.wellue.health", "com.viatomtech.wellue.O2Ring": return "Wellue O2Ring"
        case "com.apple.health", "com.apple.Health": return "Apple Watch"
        case "com.withings.wiscale2": return "Withings"
        case "com.omronhealthcare.OmronConnect": return "Omron"
        case "com.qardio.app": return "Qardio"
        default: return bundleID
        }
    }
}

// MARK: - Reliability classifiers

extension Reliability {
    /// Time span (max - min timestamp) of a sample collection, in seconds.
    private static func coverageSeconds(_ samples: [QuantityHealthSample]) -> TimeInterval {
        guard let first = samples.first else { return 0 }
        var minT = first.timestamp
        var maxT = first.timestamp
        for s in samples.dropFirst() {
            if s.timestamp < minT { minT = s.timestamp }
            if s.timestamp > maxT { maxT = s.timestamp }
        }
        return maxT.timeIntervalSince(minT)
    }

    /// Glucose, daily 24h window.
    /// high: ≥80% from a CGM bundle ID AND ≥200 samples AND ≥18h coverage.
    /// medium: CGM dominates 12-18h, OR mixed sources with ≥24 samples AND ≥12h.
    /// low: only spot/ambient or <24 samples.
    /// insufficient: empty.
    static func glucoseDaily(samples: [QuantityHealthSample]) -> Reliability {
        guard !samples.isEmpty else { return .insufficient }
        let cgmCount = samples.filter { DeviceProvenance.isContinuousGlucoseMonitor($0.sourceBundleID) }.count
        let cgmShare = Double(cgmCount) / Double(samples.count)
        let coverageHours = coverageSeconds(samples) / 3600

        if cgmShare >= 0.8 && samples.count >= 200 && coverageHours >= 18 {
            return .high
        }

        let cgmDominates = cgmShare >= 0.8
        if cgmDominates && coverageHours >= 12 && coverageHours < 18 {
            return .medium
        }
        if samples.count >= 24 && coverageHours >= 12 {
            return .medium
        }

        return .low
    }

    /// SpO₂, overnight noon-to-noon window.
    /// high: ≥80% from overnight oximeter AND ≥240 samples AND ≥6h coverage.
    /// medium: pulse-ox dominant 3-6h, OR mixed Apple Watch + dedicated with ≥60 samples.
    /// low: Apple Watch only, or <60 samples.
    /// insufficient: <5 samples.
    static func spo2Overnight(samples: [QuantityHealthSample]) -> Reliability {
        if samples.count < 5 { return .insufficient }
        let dedicatedCount = samples.filter { DeviceProvenance.isOvernightPulseOximeter($0.sourceBundleID) }.count
        let dedicatedShare = Double(dedicatedCount) / Double(samples.count)
        let appleWatchCount = samples.filter { DeviceProvenance.isAppleEcosystemSource($0.sourceBundleID) }.count
        let coverageHours = coverageSeconds(samples) / 3600

        if dedicatedShare >= 0.8 && samples.count >= 240 && coverageHours >= 6 {
            return .high
        }

        let dedicatedDominates = dedicatedShare >= 0.8
        if dedicatedDominates && coverageHours >= 3 && coverageHours < 6 {
            return .medium
        }
        // Mixed Apple Watch + dedicated with ≥60 samples
        if dedicatedCount > 0 && appleWatchCount > 0 && samples.count >= 60 {
            return .medium
        }

        return .low
    }

    /// Heart rate. Watch HR is sampled minute-by-minute, so dense sample
    /// counts are a meaningful proxy for coverage.
    /// high: Apple Watch source ≥50 samples.
    /// medium: Apple Watch source with reduced coverage.
    /// low: manual/unknown source.
    /// insufficient: empty.
    static func heartRate(samples: [QuantityHealthSample]) -> Reliability {
        guard !samples.isEmpty else { return .insufficient }
        let appleCount = samples.filter { DeviceProvenance.isAppleEcosystemSource($0.sourceBundleID) }.count
        let appleDominant = Double(appleCount) / Double(samples.count) >= 0.8
        if appleDominant {
            return samples.count >= 50 ? .high : .medium
        }
        return .low
    }

    /// HRV. Apple Watch logs HRV (SDNN) sparsely — a few readings per night
    /// is normal — so the high-sample threshold is much lower than HR's.
    /// high: Apple Watch source ≥3 samples.
    /// medium: Apple Watch source with 1-2 samples.
    /// low: manual/unknown source.
    /// insufficient: empty.
    static func hrv(samples: [QuantityHealthSample]) -> Reliability {
        guard !samples.isEmpty else { return .insufficient }
        let appleCount = samples.filter { DeviceProvenance.isAppleEcosystemSource($0.sourceBundleID) }.count
        let appleDominant = Double(appleCount) / Double(samples.count) >= 0.8
        if appleDominant {
            return samples.count >= 3 ? .high : .medium
        }
        return .low
    }

    /// Resting heart rate. Apple Watch writes a single daily RHR value, so
    /// presence (not density) is what matters.
    /// high: present from Apple Watch.
    /// low: present from manual/unknown source.
    /// insufficient: empty.
    static func restingHR(samples: [QuantityHealthSample]) -> Reliability {
        guard !samples.isEmpty else { return .insufficient }
        let appleCount = samples.filter { DeviceProvenance.isAppleEcosystemSource($0.sourceBundleID) }.count
        let appleDominant = Double(appleCount) / Double(samples.count) >= 0.8
        return appleDominant ? .high : .low
    }

    /// Respiratory rate. Apple Watch writes sleep-window RR samples — a
    /// handful per night is normal coverage.
    /// high: Apple Watch source ≥5 samples.
    /// medium: Apple Watch source with 1-4 samples.
    /// low: manual/unknown source.
    /// insufficient: empty.
    static func respiratoryRate(samples: [QuantityHealthSample]) -> Reliability {
        guard !samples.isEmpty else { return .insufficient }
        let appleCount = samples.filter { DeviceProvenance.isAppleEcosystemSource($0.sourceBundleID) }.count
        let appleDominant = Double(appleCount) / Double(samples.count) >= 0.8
        if appleDominant {
            return samples.count >= 5 ? .high : .medium
        }
        return .low
    }

    /// Wrist temperature. Apple Watch records one nightly value, so
    /// presence-from-Watch is the high bar.
    /// high: ≥1 sample from Apple Watch.
    /// low: present from manual/unknown source.
    /// insufficient: empty.
    static func wristTemperature(samples: [QuantityHealthSample]) -> Reliability {
        guard !samples.isEmpty else { return .insufficient }
        let appleCount = samples.filter { DeviceProvenance.isAppleEcosystemSource($0.sourceBundleID) }.count
        return appleCount >= 1 ? .high : .low
    }

    /// Blood pressure.
    /// high: source on `medicalGradeBPCuffs`.
    /// medium: unknown medical device (non-Apple, non-cuff list).
    /// low: manual entry from Apple Health.
    /// insufficient: empty.
    static func bloodPressure(samples: [QuantityHealthSample]) -> Reliability {
        guard !samples.isEmpty else { return .insufficient }
        if samples.contains(where: { DeviceProvenance.isMedicalGradeBPCuff($0.sourceBundleID) }) {
            return .high
        }
        if samples.allSatisfy({ DeviceProvenance.isAppleEcosystemSource($0.sourceBundleID) }) {
            return .low
        }
        return .medium
    }
}
