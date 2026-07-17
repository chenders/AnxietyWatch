import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Protocol abstracting a WCSession transfer object, so mocks can return
/// a test double without hitting WCSessionUserInfoTransfer's restricted init.
public protocol WCSessionTransfer: AnyObject {
    var isTransferring: Bool { get }
    func cancel()
}

public protocol WCSessionFileTransferProtocol: WCSessionTransfer {}

#if canImport(WatchConnectivity)
extension WCSessionUserInfoTransfer: WCSessionTransfer {}
extension WCSessionFileTransfer: WCSessionFileTransferProtocol {}
#endif

public protocol WCSessionProtocol: AnyObject {
    var delegate: WCSessionDelegate? { get set }
    var activationState: WCSessionActivationState { get }
    var isReachable: Bool { get }
    
    func activate()
    func sendMessage(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?, errorHandler: ((Error) -> Void)?)
    func transferUserInfo(_ userInfo: [String: Any]) -> any WCSessionTransfer
    func transferFile(_ fileURL: URL, metadata: [String: Any]?) -> any WCSessionFileTransferProtocol
    func updateApplicationContext(_ context: [String: Any]) throws
}

#if canImport(WatchConnectivity)
/// Thin wrapper that adapts real WCSession to WCSessionProtocol,
/// avoiding method-name collisions with WCSession's own
/// transferUserInfo/transferFile (which return concrete types).
public final class LiveWCSessionAdapter: WCSessionProtocol {
    private let session: WCSession

    public init(session: WCSession = .default) {
        self.session = session
    }

    public var delegate: WCSessionDelegate? {
        get { session.delegate }
        set { session.delegate = newValue }
    }
    public var activationState: WCSessionActivationState { session.activationState }
    public var isReachable: Bool { session.isReachable }

    public func activate() { session.activate() }
    public func sendMessage(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?, errorHandler: ((Error) -> Void)?) {
        session.sendMessage(message, replyHandler: replyHandler, errorHandler: errorHandler)
    }
    public func transferUserInfo(_ userInfo: [String: Any]) -> any WCSessionTransfer {
        session.transferUserInfo(userInfo)
    }
    public func transferFile(_ fileURL: URL, metadata: [String: Any]?) -> any WCSessionFileTransferProtocol {
        session.transferFile(fileURL, metadata: metadata)
    }
    public func updateApplicationContext(_ context: [String: Any]) throws {
        try session.updateApplicationContext(context)
    }
}

extension WCSession {
    /// Convenience: wrap `WCSession.default` as a protocol-conforming adapter
    /// for injection into `DependencyContainer`.
    public var asProtocol: WCSessionProtocol { LiveWCSessionAdapter(session: self) }
}
#endif
