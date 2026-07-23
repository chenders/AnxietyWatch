import Foundation

/// Defines the complication data written out for the extension to display.
public struct ComplicationState: Sendable, Codable, Equatable {
    public var latestHR: Int?
    public var latestSpO2: Int?
    public var alertTier: String
    public var fusionScore: Double
    public var lastUpdate: Date?

    public init(
        latestHR: Int? = nil,
        latestSpO2: Int? = nil,
        alertTier: String,
        fusionScore: Double,
        lastUpdate: Date? = nil
    ) {
        self.latestHR = latestHR
        self.latestSpO2 = latestSpO2
        self.alertTier = alertTier
        self.fusionScore = fusionScore
        self.lastUpdate = lastUpdate
    }
}

/// Actor responsible for debouncing state changes and flushing them
/// atomically to the App Group container for the Complication extension.
public actor ComplicationCacheWriter {
    // Must match the App Group in the Watch app + Widgets entitlements (and the
    // Widgets' reader). This is the WATCH complication path: the Watch app writes
    // via this cache and the watchOS Widgets read it, both entitled for this
    // group. (Previously hardcoded the pre-rebrand `group.com.anxietywatch`,
    // which no target is entitled for anymore — the watch complication silently
    // never updated, and a release build would hard-fail in `init`.)
    public static let appGroupIdentifier = "group.com.groundeffectsoftware.AnxietyWatch.watch"

    private var pending: ComplicationState?
    private var timerTask: Task<Void, Never>?

    /// The directory where the plist is written. Overridable for tests.
    private let containerURL: URL

    public init(containerURL: URL? = nil) {
        if let url = containerURL {
            self.containerURL = url
        } else if let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) {
            self.containerURL = url
        } else {
            // The App Group container is unavailable, and this is EXPECTED in
            // several normal cases — the iOS app target has no App Group
            // entitlement (and can't feed a watchOS complication across the
            // device boundary anyway), and the simulator / XCTest host lack it
            // too. So this must NOT crash: no `fatalError` (would crash release
            // device builds) and no `assertionFailure` (would crash every DEBUG
            // app launch + the app test suite, since the iOS app always lands
            // here). A glanceable complication cache degrades to a throwaway
            // temp directory (it simply won't update) in every build config.
            self.containerURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ComplicationCacheFallback")
            try? FileManager.default.createDirectory(at: self.containerURL, withIntermediateDirectories: true)
        }
    }

    /// Submits a new state. Coalesces rapid updates, writing only the
    /// trailing edge after a 500ms debounce window.
    public func submit(_ state: ComplicationState) {
        pending = state
        if timerTask == nil {
            timerTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                if !Task.isCancelled {
                    await self.flush()
                }
            }
        }
    }

    /// Flushes any pending state to disk atomically and clears the debounce timer.
    public func flush() async {
        guard let state = pending else {
            timerTask = nil
            return
        }
        pending = nil
        timerTask = nil

        let tmp = containerURL.appendingPathComponent("complication.plist.tmp")
        let dst = containerURL.appendingPathComponent("complication.plist")

        do {
            let data = try PropertyListEncoder().encode(state)
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(dst, withItemAt: tmp)
        } catch {
            // In a production app, we might log this with OSLog.
            // For now, silent fail is acceptable for complication cache.
        }
    }

    /// Returns the currently pending state (mostly for testing).
    public var pendingState: ComplicationState? {
        return pending
    }
}
