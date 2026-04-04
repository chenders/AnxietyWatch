import Foundation
import SwiftData

@Model
final class PhysiologicalCorrelation {
    #Unique<PhysiologicalCorrelation>([\.signalName])

    var id: UUID
    var signalName: String
    var correlation: Double
    var pValue: Double
    var sampleCount: Int
    var meanSeverityWhenAbnormal: Double?
    var meanSeverityWhenNormal: Double?
    var computedAt: Date

    var displayName: String {
        switch signalName {
        case "hrv_avg": return "Heart Rate Variability"
        case "resting_hr": return "Resting Heart Rate"
        case "sleep_duration_min": return "Sleep Duration"
        case "sleep_quality_ratio": return "Sleep Quality"
        case "steps": return "Daily Steps"
        case "cpap_ahi": return "CPAP AHI"
        case "barometric_pressure_change_kpa": return "Barometric Change"
        default: return signalName
        }
    }

    var strength: String {
        let absR = abs(correlation)
        if absR > 0.5 { return "Strong" }
        if absR > 0.3 { return "Moderate" }
        return "Weak"
    }

    var direction: String {
        correlation > 0 ? "positive" : "inverse"
    }

    var isSignificant: Bool { pValue < 0.05 }

    init(
        signalName: String,
        correlation: Double,
        pValue: Double,
        sampleCount: Int,
        meanSeverityWhenAbnormal: Double? = nil,
        meanSeverityWhenNormal: Double? = nil,
        computedAt: Date = .now
    ) {
        self.id = UUID()
        self.signalName = signalName
        self.correlation = correlation
        self.pValue = pValue
        self.sampleCount = sampleCount
        self.meanSeverityWhenAbnormal = meanSeverityWhenAbnormal
        self.meanSeverityWhenNormal = meanSeverityWhenNormal
        self.computedAt = computedAt
    }
}
