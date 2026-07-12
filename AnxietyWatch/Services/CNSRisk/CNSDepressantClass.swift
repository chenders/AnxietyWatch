import Foundation

/// Drug classes whose logged doses arm the CNS-depression monitor, with the
/// spec §14.1 pharmacokinetic monitoring windows. Windows are deliberately
/// shorter than elimination half-lives (a multi-day alert = alarm fatigue);
/// they cover the peak respiratory-depression risk period.
enum CNSDepressantClass: String, CaseIterable, Sendable {
    case benzodiazepine
    case opioidIR
    case opioidER
    case methadoneOrUnknownLongActing

    /// Monitoring window measured from the logged dose time (spec §14.1).
    var doseWindow: TimeInterval {
        switch self {
        case .benzodiazepine: 12 * 3600
        case .opioidIR: 8 * 3600
        case .opioidER: 24 * 3600
        case .methadoneOrUnknownLongActing: 72 * 3600
        }
    }
}
