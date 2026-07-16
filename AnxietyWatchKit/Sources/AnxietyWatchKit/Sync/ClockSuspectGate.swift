import Foundation

/// Observes wall-clock vs boot-anchored-monotonic divergence continuously.
/// Sets `clockSuspect = true` after sustained drift; clears after sustained
/// return to bounds. Consumers (SyncCoordinator, CNSFusionEngine) read
/// `isSuspect` synchronously via the actor.
///
/// Semantics (Spec §2.2):
/// - Sample every 30 s.
/// - Set: |wall - monotonic| > 60 s for 5 consecutive minutes → true.
/// - Clear: back within bounds for 15 consecutive minutes → false.
/// - Every set/clear emits an OSLog fault (Log.hlc) and publishes an event.
public actor ClockSuspectGate {
    
    public enum Event: Sendable, Equatable {
        case set(atMillis: Int64, divergenceMillis: Int64)
        case cleared(atMillis: Int64)
    }
    
    // Configuration
    private let wallNow: () -> Int64
    private let monotonicNow: () -> Int64
    private let driftThresholdMillis: Int64
    private let setSustainedForMillis: Int64
    private let clearSustainedForMillis: Int64
    
    // State tracking
    private var suspectFlag: Bool = false
    private var wasOutOfBounds: Bool = false
    private var outOfBoundsSince: Int64? = nil
    private var inBoundsSince: Int64? = nil
    
    // Event stream
    private let (eventStream, eventContinuation) = AsyncStream<Event>.makeStream()
    
    public init(
        wallNow: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        monotonicNow: @escaping @Sendable () -> Int64 = { HLC.defaultMonotonic() },
        driftThresholdMillis: Int64 = 60_000,
        setSustainedFor: TimeInterval = 300,   // 5 minutes
        clearSustainedFor: TimeInterval = 900  // 15 minutes
    ) {
        self.wallNow = wallNow
        self.monotonicNow = monotonicNow
        self.driftThresholdMillis = driftThresholdMillis
        self.setSustainedForMillis = Int64(setSustainedFor * 1000)
        self.clearSustainedForMillis = Int64(clearSustainedFor * 1000)
    }
    
    public var isSuspect: Bool { 
        return suspectFlag
    }
    
    /// Feed a synthetic sample (test injection point). In production, the
    /// SensorRouter or a Task-based scheduler calls this every ~30 s with
    /// current wallNow()/monotonicNow() values captured at the same instant.
    public func sample() async {
        let wallTime = wallNow()
        let monotonicTime = monotonicNow()
        let divergence = abs(wallTime - monotonicTime)

        if divergence > driftThresholdMillis {
            // Out of bounds
            if !wasOutOfBounds {
                outOfBoundsSince = wallTime
                inBoundsSince = nil
            }
            wasOutOfBounds = true

            // Check if we should set suspect flag (only if not already set)
            if !suspectFlag, let outOfBoundsSince = outOfBoundsSince {
                let durationOutOfBounds = wallTime - outOfBoundsSince
                if durationOutOfBounds >= setSustainedForMillis {
                    suspectFlag = true
                    eventContinuation.yield(.set(atMillis: wallTime, divergenceMillis: divergence))
                    Log.hlc.fault("ClockSuspectGate set: divergence=\(divergence)ms sustained for \(durationOutOfBounds/1000)s")
                }
            }
        } else {
            // In bounds
            if wasOutOfBounds {
                inBoundsSince = wallTime
                outOfBoundsSince = nil
            }
            wasOutOfBounds = false

            // Check if we should clear suspect flag (only if currently set)
            if suspectFlag, let inBoundsSince = inBoundsSince {
                let durationInBounds = wallTime - inBoundsSince
                if durationInBounds >= clearSustainedForMillis {
                    suspectFlag = false
                    eventContinuation.yield(.cleared(atMillis: wallTime))
                    Log.hlc.fault("ClockSuspectGate cleared: in bounds for \(durationInBounds/1000)s")
                }
            }
        }
    }
    
    /// AsyncStream of set/cleared transitions. **Single-consumer**: two
    /// concurrent iterators would race — each event delivered to exactly one.
    /// If T17 needs multi-consumer fan-out, wrap this in a broadcaster along
    /// the lines of `CorruptionBroadcaster` (T06d).
    public var events: AsyncStream<Event> {
        return eventStream
    }
}