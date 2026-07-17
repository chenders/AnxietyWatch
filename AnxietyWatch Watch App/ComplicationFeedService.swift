import Foundation
import AnxietyWatchKit

/// Service that feeds complication state updates from the sensor pipeline.
/// Subscribes to the 10Hz throttled stream and writes to the App Group cache.
public actor ComplicationFeedService {
    
    private let writer = ComplicationCacheWriter()
    private var feedTask: Task<Void, Never>?
    
    public init() {}
    
    /// Start feeding complication updates from the sensor router.
    /// - Parameter router: The sensor router to subscribe to
    public func start(router: SensorRouter) {
        guard feedTask == nil else { return }
        
        feedTask = Task { [writer] in
            for await snapshot in await router.throttled(rate: 10) {
                guard !Task.isCancelled else { return }
                
                let state = ComplicationState(
                    latestHR: snapshot.latestHR,
                    latestSpO2: snapshot.latestSpO2,
                    alertTier: snapshot.alertTier.rawValue,
                    fusionScore: snapshot.fusionScore,
                    lastUpdate: Date()
                )
                
                await writer.submit(state)
            }
        }
    }
    
    /// Stop feeding complication updates and flush any pending writes.
    public func stop() async {
        feedTask?.cancel()
        feedTask = nil
        await writer.flush()
    }
}