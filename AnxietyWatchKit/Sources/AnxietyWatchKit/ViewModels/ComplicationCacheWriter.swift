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
    public static let appGroupIdentifier = "group.com.anxietywatch"
    
    private var pending: ComplicationState?
    private var timerTask: Task<Void, Never>?
    
    /// The directory where the plist is written. Overridable for tests.
    private let containerURL: URL
    
    public init(containerURL: URL? = nil) {
        if let url = containerURL {
            self.containerURL = url
        } else if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier) {
            self.containerURL = url
        } else {
#if targetEnvironment(simulator)
            // Simulator may lack the App Group entitlement. Fall back to
            // a temp directory for development — complication won't update
            // on the watch face, but the pipeline still works.
            self.containerURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ComplicationSimFallback")
            try? FileManager.default.createDirectory(at: self.containerURL, withIntermediateDirectories: true)
#else
            fatalError("App Group entitlement missing for \(Self.appGroupIdentifier)")
#endif
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
