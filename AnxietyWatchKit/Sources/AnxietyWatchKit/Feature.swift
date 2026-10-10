import Foundation

/// Compatibility facade for redesign rollout decisions (Spec §7.3).
///
/// Production consumers accept an injectable `FeatureFlagProvider` and route
/// reads through this facade so every decision logs only the non-sensitive
/// flag name and resolved boolean value.
public enum Feature {
    public static let defaultProvider: any FeatureFlagProvider = UserDefaultsFeatureFlagProvider()

    public static func isEnabled(
        _ flag: RedesignFeature,
        using provider: (any FeatureFlagProvider)? = nil
    ) async -> Bool {
        let enabled = await (provider ?? defaultProvider).isEnabled(flag)
        Log.migration.info("Feature flag \(flag.rawValue, privacy: .public)=\(enabled, privacy: .public)")
        return enabled
    }

    /// §3.4 Oura BLE: enable Oura Ring 5 BLE IBI streaming.
    /// Requires user-provided 16-byte key extraction. Default: false.
    public static var ouraBLEEnabled: Bool {
        UserDefaults.standard.bool(forKey: "oura.bleEnabled")
    }
}
