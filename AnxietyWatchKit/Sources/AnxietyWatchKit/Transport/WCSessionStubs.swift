#if !canImport(WatchConnectivity)
import Foundation

public enum WCSessionActivationState: Int, @unchecked Sendable {
    case notActivated
    case inactive
    case activated
}

public protocol WCSessionDelegate: NSObjectProtocol {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?)
    func sessionDidBecomeInactive(_ session: WCSession)
    func sessionDidDeactivate(_ session: WCSession)
    func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void)
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any])
}

public class WCSessionUserInfoTransfer: NSObject, WCSessionTransfer {
    public var isTransferring: Bool { false }
    public func cancel() {}
}

public class WCSessionFileTransfer: NSObject, WCSessionFileTransferProtocol {
    public var isTransferring: Bool { false }
    public func cancel() {}
}

public class WCSession: NSObject {
    public static let `default` = WCSession()
    public weak var delegate: WCSessionDelegate?
    public var activationState: WCSessionActivationState = .notActivated
    public var isReachable: Bool = false
    public var isCompanionAppInstalled: Bool = false
    
    public func activate() {}
    public func sendMessage(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?, errorHandler: ((Error) -> Void)?) {}
    public func transferUserInfo(_ userInfo: [String: Any]) -> WCSessionTransfer { WCSessionUserInfoTransfer() }
    public func transferFile(_ fileURL: URL, metadata: [String: Any]?) -> WCSessionFileTransferProtocol { WCSessionFileTransfer() }
    public func updateApplicationContext(_ context: [String: Any]) throws {}
}

extension WCSession: WCSessionProtocol {}
#endif
