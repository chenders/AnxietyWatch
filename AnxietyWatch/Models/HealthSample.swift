import Foundation
import SwiftData

/// Individual health reading from HealthKit. Cached for 7 days to power
/// dashboard sparklines and "latest value" displays. Daily HealthSnapshot
/// handles long-term trending.
@Model
final class HealthSample {
    var id: UUID
    var type: String
    var value: Double
    var timestamp: Date
    var source: String?

    init(type: String, value: Double, timestamp: Date, source: String? = nil) {
        self.id = UUID()
        self.type = type
        self.value = value
        self.timestamp = timestamp
        self.source = source
    }
}
