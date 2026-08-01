import Testing
import MetricKit
import SwiftData
import Foundation
@testable import AnxietyWatch

@MainActor
struct EnergyMetricsCollectorTests {
    @Test
    func testPayloadParsingAndPersistence() async throws {
        // Arrange
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: EnergyMetricPayload.self, configurations: config)
        let collector = EnergyMetricsCollector(modelContainer: container)

        let mockPayload = MockMetricPayload()

        let mockCPU = MockCPUMetric()
        mockCPU.mockCumulativeCPUTime = Measurement(value: 42.5, unit: .seconds)
        mockPayload.mockCPUMetrics = mockCPU

        let mockLaunch = MockAppLaunchMetric()
        let mockHistogram = MockHistogram()
        let bucket1 = MockBucket()
        bucket1.mockCount = 3
        let bucket2 = MockBucket()
        bucket2.mockCount = 5
        mockHistogram.mockBuckets = [bucket1, bucket2]
        mockLaunch.mockHistogrammedApplicationResumeTime = mockHistogram
        mockPayload.mockApplicationLaunchMetrics = mockLaunch

        let expectedDate = Date()
        mockPayload.mockTimeStampEnd = expectedDate

        // Act
        collector.didReceive([mockPayload])

        // Let background Task complete
        try await Task.sleep(nanoseconds: 100_000_000)

        // Assert
        let context = ModelContext(container)
        let fetchDescriptor = FetchDescriptor<EnergyMetricPayload>()
        let records = try context.fetch(fetchDescriptor)

        #expect(records.count == 1)
        if let record = records.first {
            #expect(abs(record.cumulativeCPUTime - 42.5) < 0.001)
            #expect(record.backgroundWakeCount == 8) // 3 + 5
            #expect(record.timestamp == expectedDate)
        }
    }
}

// MARK: - Mocks

final class MockMetricPayload: MXMetricPayload {
    var mockCPUMetrics: MXCPUMetric?
    override var cpuMetrics: MXCPUMetric? { mockCPUMetrics }

    var mockApplicationLaunchMetrics: MXAppLaunchMetric?
    override var applicationLaunchMetrics: MXAppLaunchMetric? { mockApplicationLaunchMetrics }

    var mockTimeStampEnd: Date = Date()
    override var timeStampEnd: Date { mockTimeStampEnd }

    override func jsonRepresentation() -> Data {
        return Data("{}".utf8)
    }
}

final class MockCPUMetric: MXCPUMetric {
    var mockCumulativeCPUTime: Measurement<UnitDuration> = Measurement(value: 0, unit: .seconds)
    override var cumulativeCPUTime: Measurement<UnitDuration> { mockCumulativeCPUTime }
}

final class MockAppLaunchMetric: MXAppLaunchMetric {
    var mockHistogrammedApplicationResumeTime: MXHistogram<UnitDuration>?
    override var histogrammedApplicationResumeTime: MXHistogram<UnitDuration> {
        mockHistogrammedApplicationResumeTime ?? MXHistogram<UnitDuration>()
    }
}

final class MockHistogram: MXHistogram<UnitDuration> {
    var mockBuckets: [MXHistogramBucket<UnitDuration>] = []
    override var bucketEnumerator: NSEnumerator {
        return (mockBuckets as NSArray).objectEnumerator()
    }
}

final class MockBucket: MXHistogramBucket<UnitDuration> {
    var mockCount: Int = 0
    override var bucketCount: Int { mockCount }
}
