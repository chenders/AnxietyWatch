import Foundation
import Testing
@testable import AnxietyWatchKit

@Suite("Injectable redesign feature controls")
struct FeatureFlagProviderTests {
    @Test("bundled defaults keep SQLite reads and delta sync disabled")
    func safeBundledDefaults() async {
        let suiteName = "FeatureFlagProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = UserDefaultsFeatureFlagProvider(defaults: defaults)

        #expect(await provider.isEnabled(.sqliteReads) == false)
        #expect(await provider.isEnabled(.deltaSync) == false)
    }

    @Test("local overrides expose both values for every redesign flag")
    func localOverrides() async {
        let suiteName = "FeatureFlagProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = UserDefaultsFeatureFlagProvider(defaults: defaults)

        for flag in RedesignFeature.allCases {
            defaults.set(true, forKey: flag.defaultsKey)
            #expect(await provider.isEnabled(flag) == true)

            defaults.set(false, forKey: flag.defaultsKey)
            #expect(await provider.isEnabled(flag) == false)
        }
    }

    @Test("gap production reader honors disabled and enabled providers")
    func gapReaderUsesInjectedProvider() async {
        let disabledEffects = FlagEffectRecorder()
        let disabled = CNSMonitoringCoordinator(
            router: SensorRouter(polar: nil, emay: nil, healthKit: nil),
            handlers: disabledEffects.handlers,
            featureFlags: FixedFeatureFlagProvider(enabled: [])
        )
        await disabled.process(.dataGap(range: 0...(10 * 60 * 1_000)))
        #expect(await disabledEffects.notifications.isEmpty)

        let enabledEffects = FlagEffectRecorder()
        let enabled = CNSMonitoringCoordinator(
            router: SensorRouter(polar: nil, emay: nil, healthKit: nil),
            handlers: enabledEffects.handlers,
            featureFlags: FixedFeatureFlagProvider(enabled: [.pipelineGapEvents])
        )
        await enabled.process(.dataGap(range: 0...(10 * 60 * 1_000)))
        #expect(await enabledEffects.notifications == ["Monitoring gap: 10 min without data"])
    }

    @Test("binary transport production reader honors disabled and enabled providers")
    func binaryReaderUsesInjectedProvider() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeatureFlagProviderTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = DatabaseManager(url: directory.appendingPathComponent("fictional.sqlite"))
        let hlc = HLC(nodeID: Data(repeating: 0xD4, count: 16))
        let transport = WCSessionCoordinator(session: MockWCSession())
        let sample = SampleRow(
            source: 1,
            type: 1,
            timestamp: 1_700_000_000,
            value: 72,
            extra: nil,
            hlcPhysical: 123,
            hlcLogical: 4,
            nodeID: Data(repeating: 0xD4, count: 16)
        )

        let legacy = SyncEngine(
            database: database,
            hlc: hlc,
            transport: transport,
            featureFlags: FixedFeatureFlagProvider(enabled: [])
        )
        let legacyPayload = try await legacy.encodeSamples([sample])
        #expect(try JSONDecoder().decode([SampleRow].self, from: legacyPayload) == [sample])
        #expect(try await legacy.decodeSamples(legacyPayload) == [sample])

        let binary = SyncEngine(
            database: database,
            hlc: hlc,
            transport: transport,
            featureFlags: FixedFeatureFlagProvider(enabled: [.wcBinaryFormat])
        )
        let binaryPayload = try await binary.encodeSamples([sample])
        #expect(try BinaryCodec.decodeSamplePayload(binaryPayload) == [sample])
        #expect(try await binary.decodeSamples(binaryPayload) == [sample])
        #expect(binaryPayload != legacyPayload)
    }
}

private struct FixedFeatureFlagProvider: FeatureFlagProvider {
    let enabled: Set<RedesignFeature>

    func isEnabled(_ flag: RedesignFeature) async -> Bool {
        enabled.contains(flag)
    }
}

private actor FlagEffectRecorder {
    private(set) var notifications: [String] = []

    nonisolated var handlers: CNSMonitoringCoordinator.EffectHandlers {
        CNSMonitoringCoordinator.EffectHandlers(
            notify: { [weak self] _, message in await self?.record(message) },
            haptic: { _ in },
            watchMessage: { _ in }
        )
    }

    private func record(_ message: String) {
        notifications.append(message)
    }
}
