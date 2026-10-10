import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

public enum WCSessionDelegateRouterError: Error, Equatable, Sendable {
    case duplicateHandlerID(String)
}

/// Owns the session delegate slot while forwarding callbacks to registered
/// transport handlers. Production startup does not install this router until
/// every legacy callback is represented behind it.
public final class WCSessionDelegateRouter: NSObject, @unchecked Sendable {
    private struct HandlerEntry {
        let id: String
        let delegate: WCSessionDelegate
    }

    private let session: WCSessionProtocol
    private let handlersLock = NSLock()
    private var handlers: [HandlerEntry] = []

    public init(session: WCSessionProtocol? = nil) {
        self.session = session ?? {
#if canImport(WatchConnectivity)
            LiveWCSessionAdapter()
#else
            WCSession.default
#endif
        }()
        super.init()
    }

    /// Registers a callback handler under a stable identity.
    ///
    /// Registration is serialized so concurrent startup paths cannot install
    /// the same logical handler twice.
    public func register(_ handler: WCSessionDelegate, id: String) throws {
        handlersLock.lock()
        defer { handlersLock.unlock() }

        guard !handlers.contains(where: { $0.id == id }) else {
            throw WCSessionDelegateRouterError.duplicateHandlerID(id)
        }
        handlers.append(HandlerEntry(id: id, delegate: handler))
    }

    /// Claims the sole delegate slot and activates the shared session.
    public func activate() async {
        session.delegate = self
        session.activate()
    }

    /// Stable identity exposed for startup ownership assertions.
    internal var delegateIdentity: ObjectIdentifier {
        ObjectIdentifier(self)
    }

    private func handlerSnapshot() -> [WCSessionDelegate] {
        handlersLock.lock()
        defer { handlersLock.unlock() }
        return handlers.map(\.delegate)
    }
}

extension WCSessionDelegateRouter: WCSessionDelegate {
    public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        for handler in handlerSnapshot() {
            handler.session(
                session,
                activationDidCompleteWith: activationState,
                error: error
            )
        }
    }

#if os(iOS) || !canImport(WatchConnectivity)
    public func sessionDidBecomeInactive(_ session: WCSession) {
        for handler in handlerSnapshot() {
            handler.sessionDidBecomeInactive(session)
        }
    }

    public func sessionDidDeactivate(_ session: WCSession) {
        for handler in handlerSnapshot() {
            handler.sessionDidDeactivate(session)
        }
    }
#endif

    public func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let replyGate = WCSessionReplyGate(replyHandler: replyHandler)
        for handler in handlerSnapshot() {
#if canImport(WatchConnectivity)
            handler.session?(
                session,
                didReceiveMessage: message,
                replyHandler: replyGate.reply
            )
#else
            handler.session(
                session,
                didReceiveMessage: message,
                replyHandler: replyGate.reply
            )
#endif
        }
    }

    public func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any]
    ) {
        for handler in handlerSnapshot() {
#if canImport(WatchConnectivity)
            handler.session?(session, didReceiveUserInfo: userInfo)
#else
            handler.session(session, didReceiveUserInfo: userInfo)
#endif
        }
    }
}

private final class WCSessionReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private let replyHandler: ([String: Any]) -> Void
    private var didReply = false

    init(replyHandler: @escaping ([String: Any]) -> Void) {
        self.replyHandler = replyHandler
    }

    func reply(_ payload: [String: Any]) {
        lock.lock()
        guard !didReply else {
            lock.unlock()
            return
        }
        didReply = true
        lock.unlock()
        replyHandler(payload)
    }
}
