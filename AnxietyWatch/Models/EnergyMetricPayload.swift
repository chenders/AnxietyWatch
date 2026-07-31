import SwiftData
import Foundation
import MetricKit

@Model
final class EnergyMetricPayload {
    var timestamp: Date
    var cumulativeCPUTime: TimeInterval
    var backgroundWakeCount: Int
    var payloadJSON: Data

    init(
        timestamp: Date,
        cumulativeCPUTime: TimeInterval,
        backgroundWakeCount: Int,
        payloadJSON: Data
    ) {
        self.timestamp = timestamp
        self.cumulativeCPUTime = cumulativeCPUTime
        self.backgroundWakeCount = backgroundWakeCount
        self.payloadJSON = payloadJSON
    }
}
