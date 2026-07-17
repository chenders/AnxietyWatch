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

#if canImport(WatchConnectivity)
extension WCSessionUserInfoTransfer: WCSessionTransfer {}
#endif

public protocol WCSessionProtocol: AnyObject {
    var delegate: WCSessionDelegate? { get set }
    var activationState: WCSessionActivationState { get }
    var isReachable: Bool { get }
    var isCompanionAppInstalled: Bool { get }
    
    func activate()
    func sendMessage(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?, errorHandler: ((Error) -> Void)?)
    func transferUserInfo(_ userInfo: [String: Any]) -> WCSessionTransfer
    func updateApplicationContext(_ context: [String: Any]) throws
}

#if canImport(WatchConnectivity)
extension WCSession: WCSessionProtocol {
    // transferUserInfo already exists on WCSession returning
    // WCSessionUserInfoTransfer, which conforms to WCSessionTransfer.
    // Swift's covariant return type bridging satisfies the protocol.
}
#endif
