import Foundation
import MetricKit
import SwiftData
import os

@MainActor
final class EnergyMetricsCollector: NSObject, MXMetricManagerSubscriber {
    private let modelContainer: ModelContainer
    private let logger = Logger(subsystem: "com.anxietywatch", category: "EnergyMetrics")

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        super.init()
    }

    func start() {
        MXMetricManager.shared.add(self)
        logger.info("Started EnergyMetricsCollector")
    }

    func stop() {
        MXMetricManager.shared.remove(self)
        logger.info("Stopped EnergyMetricsCollector")
    }

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        Task { @MainActor in
            let context = ModelContext(self.modelContainer)
            for payload in payloads {
                let cpuTime = payload.cpuMetrics?.cumulativeCPUTime.converted(to: .seconds).value ?? 0.0

                var wakeCount = 0
                if let histogram = payload.applicationLaunchMetrics?.histogrammedApplicationResumeTime {
                    for bucket in histogram.bucketEnumerator {
                        if let bucket = bucket as? MXHistogramBucket<UnitDuration> {
                            wakeCount += bucket.bucketCount
                        }
                    }
                }

                let record = EnergyMetricPayload(
                    timestamp: payload.timeStampEnd,
                    cumulativeCPUTime: cpuTime,
                    backgroundWakeCount: wakeCount,
                    payloadJSON: payload.jsonRepresentation()
                )
                context.insert(record)
                self.logger.info("Saved EnergyMetricPayload: \(cpuTime)s CPU, \(wakeCount) wakes")
            }
            do {
                try context.save()
            } catch {
                self.logger.error("Failed to save energy metrics: \(error.localizedDescription)")
            }
        }
    }
}
