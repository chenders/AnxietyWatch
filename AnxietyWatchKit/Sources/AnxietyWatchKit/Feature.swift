import Foundation

/// Runtime rollout gates. Missing values intentionally resolve to the safe,
/// legacy path so offline installs can always communicate with older peers.
public enum Feature {
    public static var wcBinaryFormatEnabled: Bool {
        UserDefaults.standard.bool(forKey: "wc.binaryFormatEnabled")
    }
}
