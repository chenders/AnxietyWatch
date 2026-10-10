import Foundation

/// Independently reversible controls for each redesign phase.
public enum RedesignFeature: String, CaseIterable, Sendable {
    case pipelineGapEvents
    case sqliteReads
    case wcBinaryFormat
    case deltaSync

    /// Stable local override key. Missing values always fall back to the
    /// bundled safe default instead of inheriting an unrelated boolean.
    public var defaultsKey: String {
        switch self {
        case .pipelineGapEvents: "pipeline.gapEventsEnabled"
        case .sqliteReads: "storage.sqliteReadsEnabled"
        case .wcBinaryFormat: "wc.binaryFormatEnabled"
        case .deltaSync: "sync.deltaEnabled"
        }
    }

    /// Shipping defaults remain on the legacy path until their independent
    /// rollout evidence is complete.
    public var bundledDefault: Bool { false }
}

public protocol FeatureFlagProvider: Sendable {
    func isEnabled(_ flag: RedesignFeature) async -> Bool
}

/// Reads local overrides while retaining explicit, safe bundled defaults.
/// `UserDefaults` is documented as thread-safe; unchecked Sendable is needed
/// because Foundation does not express that guarantee on every supported SDK.
public final class UserDefaultsFeatureFlagProvider: FeatureFlagProvider, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func isEnabled(_ flag: RedesignFeature) async -> Bool {
        guard defaults.object(forKey: flag.defaultsKey) != nil else {
            return flag.bundledDefault
        }
        return defaults.bool(forKey: flag.defaultsKey)
    }
}
