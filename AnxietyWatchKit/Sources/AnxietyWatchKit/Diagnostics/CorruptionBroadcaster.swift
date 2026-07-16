import Foundation

/// A minimal fan-out helper so both DiagnosticsScreen (§8.4) and MetricKitReporter (§8.2)
/// can subscribe to the same underlying CorruptionEvent stream. AsyncStream itself is
/// single-consumer; this wraps it in an actor that owns one input task and rebroadcasts.
public actor CorruptionBroadcaster {
    public typealias Event = DatabaseManager.CorruptionEvent

    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    public init() {}

    /// Publish an event to all current subscribers. Called by the owning DatabaseManager
    /// (or an integration layer) whenever a CorruptionEvent is produced.
    /// If a continuation is already terminated (subscriber dropped without cancel),
    /// self-prune it so the map does not grow unboundedly.
    public func publish(_ event: Event) {
        var terminatedIDs: [UUID] = []
        for (id, cont) in continuations {
            if case .terminated = cont.yield(event) {
                terminatedIDs.append(id)
            }
        }
        for id in terminatedIDs {
            continuations.removeValue(forKey: id)
        }
    }

    /// Attach a new subscriber. Returns a stream and a cancellation token; drop the
    /// token to detach. If the consumer drops the stream without calling cancel(),
    /// the continuation's `onTermination` hook still detaches so there is no leak.
    public func subscribe() -> (stream: AsyncStream<Event>, cancel: @Sendable () -> Void) {
        let id = UUID()
        var localCont: AsyncStream<Event>.Continuation!
        let stream = AsyncStream<Event> { cont in
            localCont = cont
            cont.onTermination = { [weak self] _ in
                Task { await self?.detach(id) }
            }
        }
        continuations[id] = localCont
        return (stream, { [weak self] in
            Task { await self?.detach(id) }
        })
    }

    private func detach(_ id: UUID) {
        if let c = continuations.removeValue(forKey: id) {
            c.finish()
        }
    }

    /// Finalize all subscribers (e.g. on shutdown).
    public func closeAll() {
        for cont in continuations.values { cont.finish() }
        continuations.removeAll()
    }
}
