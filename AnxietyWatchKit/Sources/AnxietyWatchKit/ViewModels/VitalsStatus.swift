import Foundation

/// Presentation status for live vitals cards. This is not a clinical alert tier.
public enum VitalsStatus: String, Sendable, Codable, Equatable {
    case normal
    case idle
}
