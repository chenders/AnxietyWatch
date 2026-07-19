import Foundation

enum HealthKitGraceGate {
    static let minimumInterval: TimeInterval = 48 * 60 * 60
    private static let key = "healthKitFirstAuthorizedAt"

    static func hasElapsed(firstAuthorizedAt: Date?, now: Date,
                           minimum: TimeInterval = minimumInterval) -> Bool {
        guard let firstAuthorizedAt else { return false }
        return now.timeIntervalSince(firstAuthorizedAt) >= minimum
    }

    @discardableResult
    static func recordFirstAuthorizedIfNeeded(now: Date, defaults: UserDefaults) -> Date {
        if let existing = defaults.object(forKey: key) as? Date { return existing }
        defaults.set(now, forKey: key)
        return now
    }

    static func firstAuthorizedAt(defaults: UserDefaults) -> Date? {
        defaults.object(forKey: key) as? Date
    }
}
