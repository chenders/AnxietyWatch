import Foundation
import Testing
@testable import AnxietyWatchKit

@Suite("Clinical side-effect ownership")
struct ClinicalSideEffectOwnershipTests {
    @Test("package monitoring coordinator has no clinical effect interpreter")
    func packageCannotFireClinicalEffects() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/AnxietyWatchKit/Pipeline/CNSMonitoringCoordinator.swift"
            )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let forbidden = [
            "EffectHandlers",
            "handlers.notify",
            "handlers.haptic",
            "handlers.watchMessage",
            "private func interpret",
            "UNUserNotificationCenter",
            "WKInterfaceDevice",
            "WCSession.default",
        ]

        for token in forbidden {
            #expect(!source.contains(token), "Package coordinator still contains \(token)")
        }
    }

    @Test("package coordinator publishes state after command-producing input")
    func packagePublishesStateOnly() async {
        let coordinator = CNSMonitoringCoordinator(
            router: SensorRouter(polar: nil, emay: nil, healthKit: nil)
        )

        await coordinator.process(.hr(tMs: 1_000, bpm: 200))

        #expect(await coordinator.currentTier == .warning)
        #expect(await coordinator.currentFusionScore.overall >= 0)
    }
}
