import Foundation
import Testing
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif
@testable import AnxietyWatchKit

@Suite("WCSession delegate router")
struct WCSessionDelegateRouterTests {
    @Test("iPhone startup keeps the router as the effective delegate")
    func phoneStartupKeepsOneEffectiveDelegate() async throws {
        let session = RouterTestWCSession()
        let router = WCSessionDelegateRouter(session: session)
        let packageHandler = RouterTestDelegate()
        let legacyHandler = RouterTestDelegate()

        try router.register(packageHandler, id: "package")
        try router.register(legacyHandler, id: "legacy-phone")
        await router.activate()

        #expect(session.delegateIdentity == router.delegateIdentity)
        #expect(session.activationCount == 1)
    }

    @Test("watch startup keeps the router as the effective delegate")
    func watchStartupKeepsOneEffectiveDelegate() async throws {
        let session = RouterTestWCSession()
        let router = WCSessionDelegateRouter(session: session)
        let packageHandler = RouterTestDelegate()
        let legacyHandler = RouterTestDelegate()

        try router.register(packageHandler, id: "package")
        try router.register(legacyHandler, id: "legacy-watch")
        await router.activate()

        #expect(session.delegateIdentity == router.delegateIdentity)
        #expect(session.activationCount == 1)
    }

    @Test("duplicate handler identities are rejected")
    func duplicateHandlerIDsAreRejected() throws {
        let router = WCSessionDelegateRouter(session: RouterTestWCSession())

        try router.register(RouterTestDelegate(), id: "legacy")

        #expect(throws: WCSessionDelegateRouterError.duplicateHandlerID("legacy")) {
            try router.register(RouterTestDelegate(), id: "legacy")
        }
    }

    @Test("callbacks fan out in registration order and reply only once")
    func callbacksFanOutInRegistrationOrder() async throws {
        let session = RouterTestWCSession()
        let router = WCSessionDelegateRouter(session: session)
        let callbackOrder = RouterTestCallbackOrder()
        let first = RouterTestDelegate(id: "first", callbackOrder: callbackOrder)
        let second = RouterTestDelegate(id: "second", callbackOrder: callbackOrder)

        try router.register(first, id: "first")
        try router.register(second, id: "second")
        await router.activate()

        session.deliverActivation()
        session.deliverUserInfo(["kind": "history"])
        var replies: [[String: Any]] = []
        session.deliverMessage(["kind": "status"]) { replies.append($0) }

        #expect(callbackOrder.values == [
            "first.activation", "second.activation",
            "first.userInfo", "second.userInfo",
            "first.message", "second.message"
        ])
        #expect(first.lastUserInfo?["kind"] as? String == "history")
        #expect(second.lastUserInfo?["kind"] as? String == "history")
        #expect(replies.count == 1)
        #expect(replies.first?["handler"] as? String == "first")
    }
}

private final class RouterTestWCSession: WCSessionProtocol {
    var delegate: WCSessionDelegate?
    var activationState: WCSessionActivationState = .notActivated
    var isReachable = true
    private(set) var activationCount = 0

    var delegateIdentity: ObjectIdentifier? {
        delegate.map(ObjectIdentifier.init)
    }

    func activate() {
        activationCount += 1
    }

    func deliverActivation() {
        delegate?.session(
            WCSession.default,
            activationDidCompleteWith: .activated,
            error: nil
        )
    }

    func deliverMessage(
        _ message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
#if canImport(WatchConnectivity)
        delegate?.session?(
            WCSession.default,
            didReceiveMessage: message,
            replyHandler: replyHandler
        )
#else
        delegate?.session(
            WCSession.default,
            didReceiveMessage: message,
            replyHandler: replyHandler
        )
#endif
    }

    func deliverUserInfo(_ userInfo: [String: Any]) {
#if canImport(WatchConnectivity)
        delegate?.session?(WCSession.default, didReceiveUserInfo: userInfo)
#else
        delegate?.session(WCSession.default, didReceiveUserInfo: userInfo)
#endif
    }

    func sendMessage(
        _ message: [String: Any],
        replyHandler: (([String: Any]) -> Void)?,
        errorHandler: ((Error) -> Void)?
    ) {}

    func transferUserInfo(_ userInfo: [String: Any]) -> any WCSessionTransfer {
        RouterTestTransfer()
    }

    func transferFile(
        _ fileURL: URL,
        metadata: [String: Any]?
    ) -> any WCSessionFileTransferProtocol {
        RouterTestFileTransfer()
    }

    func updateApplicationContext(_ context: [String: Any]) throws {}
}

private final class RouterTestTransfer: WCSessionTransfer {
    var isTransferring = false
    func cancel() {}
}

private final class RouterTestFileTransfer: WCSessionFileTransferProtocol {
    var isTransferring = false
    func cancel() {}
}

private final class RouterTestCallbackOrder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private final class RouterTestDelegate: NSObject, WCSessionDelegate {
    private let id: String?
    private let callbackOrder: RouterTestCallbackOrder?
    private(set) var lastUserInfo: [String: Any]?

    init(id: String? = nil, callbackOrder: RouterTestCallbackOrder? = nil) {
        self.id = id
        self.callbackOrder = callbackOrder
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let id {
            callbackOrder?.append("\(id).activation")
        }
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let id else { return }
        callbackOrder?.append("\(id).message")
        replyHandler(["handler": id])
    }

    func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any]
    ) {
        lastUserInfo = userInfo
        if let id {
            callbackOrder?.append("\(id).userInfo")
        }
    }

#if os(iOS) || !canImport(WatchConnectivity)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {}
#endif
}
