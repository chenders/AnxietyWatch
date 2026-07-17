import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

public enum WCSessionError: Error, Equatable {
    case activationFailed
    case notReachable
    case companionAppNotInstalled
    case sendFailed(Error)
    case timeout
    case applicationContextFailed(Error)

    public static func == (lhs: WCSessionError, rhs: WCSessionError) -> Bool {
        switch (lhs, rhs) {
        case (.activationFailed, .activationFailed),
             (.notReachable, .notReachable),
             (.companionAppNotInstalled, .companionAppNotInstalled),
             (.timeout, .timeout):
            return true
        case (.sendFailed, .sendFailed),
             (.applicationContextFailed, .applicationContextFailed):
            return true  // associated Error ignored for equality
        default:
            return false
        }
    }
}

public actor WCSessionCoordinator: NSObject {
    
    /// WCSession uses `[String: Any]` dictionaries which contain non-Sendable
    /// `Any` values — this is an inherent API limitation. Marked `@unchecked`
    /// because all dictionary values we actually use (String, Int, Double,
    /// Bool, Data) ARE Sendable; the `Any` is WCSession's framing drag.
    public struct IncomingMessage: @unchecked Sendable {
        public let payload: [String: Any]
        public let replyHandler: @Sendable ([String: Any]) -> Void
    }
    
    nonisolated(unsafe) private let session: WCSessionProtocol
    
    private var messageContinuation: AsyncStream<IncomingMessage>.Continuation?
    private var userInfoContinuation: AsyncStream<[String: Any]>.Continuation?
    private var activationContinuations: [CheckedContinuation<Void, Error>] = []
    
    public let messages: AsyncStream<IncomingMessage>
    public let userInfos: AsyncStream<[String: Any]>

    deinit {
        messageContinuation?.finish()
        userInfoContinuation?.finish()
    }

    
    public init(session: WCSessionProtocol? = nil) {
        self.session = session ?? {
#if canImport(WatchConnectivity)
            return LiveWCSessionAdapter()
#else
            return WCSession.default
#endif
        }()
        
        let (mStream, mContinuation) = AsyncStream.makeStream(of: IncomingMessage.self)
        self.messages = mStream
        self.messageContinuation = mContinuation
        
        let (uStream, uContinuation) = AsyncStream.makeStream(of: [String: Any].self)
        self.userInfos = uStream
        self.userInfoContinuation = uContinuation
        
        super.init()
        self.session.delegate = self
    }
    
    public func activate() async throws {
        if session.activationState == .activated { return }
        
        return try await withCheckedThrowingContinuation { continuation in
            let shouldActivate = self.activationContinuations.isEmpty
            self.activationContinuations.append(continuation)
            if shouldActivate { session.activate() }
        }
    }
    
    /// Sends an interactive message. Does not access mutable actor state —
    /// only delegates to the session, so it can be called from non-isolated
    /// contexts (e.g., from a sync coordinator running on a different actor).
    /// If `isReachable` is false, the payload is handed to `transferUserInfo`
    /// as a guaranteed-delivery fallback (Spec §5.2).
    ///
    /// WCSession has its own internal timeout (~7 s); no additional timeout
    /// is layered here.
    ///
    /// - Returns: The reply dictionary from the companion.
    /// - Throws: `WCSessionError.notReachable` if `!isReachable`,
    ///   `WCSessionError.sendFailed` if the send errors.
    public nonisolated func sendMessage(
        _ payload: [String: Any],
        skipFallback: Bool = false
    ) async throws -> [String: Any] {
        let session = self.session
        guard session.isReachable else {
            if !skipFallback {
                _ = session.transferUserInfo(payload)
            }
            throw WCSessionError.notReachable
        }

        return try await withCheckedThrowingContinuation { continuation in
            session.sendMessage(payload, replyHandler: { reply in
                continuation.resume(returning: reply)
            }, errorHandler: { error in
                if !skipFallback {
                    _ = session.transferUserInfo(payload)
                }
                continuation.resume(throwing: WCSessionError.sendFailed(error))
            })
        }
    }

    /// Queues a background transfer for guaranteed delivery (FIFO).
    /// Nonisolated — only touches the session, not actor state.
    @discardableResult
    public nonisolated func transferUserInfo(_ payload: [String: Any]) -> WCSessionTransfer {
        self.session.transferUserInfo(payload)
    }

    /// Queues a disk-backed historical time-series chunk (Spec §5.2).
    /// The caller owns creation of the framed binary file. WCSession keeps the
    /// transfer alive independently of process suspension.
    @discardableResult
    public nonisolated func transferFile(
        _ fileURL: URL,
        metadata: [String: Any]? = nil
    ) -> WCSessionFileTransferProtocol {
        self.session.transferFile(fileURL, metadata: metadata)
    }

    /// Push a last-writer-wins application-context dictionary (Spec §5.2).
    /// Used for settings, status, and `requires_urgent_sync` pings.
    /// Nonisolated — only touches the session, not actor state.
    public nonisolated func updateApplicationContext(_ context: [String: Any]) throws {
        let session = self.session
        do {
            try session.updateApplicationContext(context)
        } catch {
            throw WCSessionError.applicationContextFailed(error)
        }
    }
    
    internal func completeActivation(_ state: WCSessionActivationState, error: Error?) {
        if let error = error {
            for c in activationContinuations { c.resume(throwing: error) }
        } else if state == .activated {
            for c in activationContinuations { c.resume() }
        } else {
            for c in activationContinuations { c.resume(throwing: WCSessionError.activationFailed) }
        }
        activationContinuations.removeAll()
    }
    
    internal func receiveMessage(_ message: [String: Any], replyHandler: @escaping @Sendable ([String: Any]) -> Void) {
        messageContinuation?.yield(IncomingMessage(payload: message, replyHandler: replyHandler))
    }
    
    internal func receiveUserInfo(_ userInfo: [String: Any]) {
        userInfoContinuation?.yield(userInfo)
    }
}

extension WCSessionCoordinator: WCSessionDelegate {
    
    public nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task {
            await self.completeActivation(activationState, error: error)
        }
    }

    // sessionDidBecomeInactive / sessionDidDeactivate are removed from
    // WCSessionDelegate in watchOS 11+. On iOS 26+ and in stub mode
    // they still exist and must be implemented.
#if os(iOS) || !canImport(WatchConnectivity)
    public nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        // No-op
    }

    public nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
#endif
    
    public nonisolated func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        Task {
            await self.receiveMessage(message, replyHandler: replyHandler)
        }
    }
    
    public nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        Task {
            await self.receiveUserInfo(userInfo)
        }
    }
}
