import Foundation

/// Presentation mapping for `HealthKitAccessState`, extracted from the Settings
/// view body so it is unit-testable (these strings feed both the visible status
/// row and its VoiceOver `accessibilityLabel`, so a drifted case silently
/// changes what is shown AND spoken). Lives in the Views layer, not Services,
/// to keep UI copy out of the diagnostic model.
extension HealthKitAccessState {
    /// Coarse tint role, mapped to a concrete `Color` by the view. Kept as an
    /// enum (not `Color`) so the mapping stays `Equatable`-testable.
    enum Tint: Sendable, Equatable {
        case positive   // reads working
        case warning    // needs the user's attention
        case neutral    // informational, not a problem
    }

    /// SF Symbol for the status row. `.notRequested` and `.likelyRevoked`
    /// deliberately differ so a sighted skim of the icon alone distinguishes
    /// "never asked" from "was working, now isn't."
    var statusSymbolName: String {
        switch self {
        case .receiving: "checkmark.circle.fill"
        case .notRequested: "heart.slash.fill"
        case .likelyRevoked: "exclamationmark.triangle.fill"
        case .noDataYet: "circle.dashed"
        }
    }

    var statusTitle: String {
        switch self {
        case .receiving: "Receiving data"
        case .notRequested: "Access not granted"
        case .likelyRevoked: "Not receiving data"
        case .noDataYet: "No data yet"
        }
    }

    var statusDetail: String {
        switch self {
        case .receiving:
            "HealthKit reads are working."
        case .notRequested:
            "The authorization prompt hasn't been answered. Tap Request HealthKit Access below."
        case .likelyRevoked:
            "Access may have been revoked. Re-enable the types in iOS Settings, then rebuild history."
        case .noDataYet:
            "No recent health data to read yet."
        }
    }

    var statusTint: Tint {
        switch self {
        case .receiving: .positive
        case .notRequested, .likelyRevoked: .warning
        case .noDataYet: .neutral
        }
    }
}
