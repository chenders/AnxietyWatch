import XCTest
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif
@testable import AnxietyWatchKit

final class MockTransfer: WCSessionTransfer {
    let isTransferring: Bool = false
    func cancel() {}
}

final class MockWCSession: WCSessionProtocol {
    var delegate: WCSessionDelegate?
    var activationState: WCSessionActivationState = .notActivated
    var isReachable: Bool = true
    var isCompanionAppInstalled: Bool = true
    
    var activateCalled = false
    var messageSent: [String: Any]?
    var userInfoTransferred: [String: Any]?
    var applicationContextUpdated: [String: Any]?
    
    var mockReply: [String: Any]?
    var mockError: Error?
    var mockApplicationContextError: Error?
    
    var activationDelay: UInt64 = 10_000_000 // 10ms
    var messageDelay: UInt64 = 0
    
    func activate() {
        activateCalled = true
        Task {
            try? await Task.sleep(nanoseconds: activationDelay)
            if let delegate = delegate {
                delegate.session(WCSession.default, activationDidCompleteWith: .activated, error: nil)
            }
        }
    }
    
    func sendMessage(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?, errorHandler: ((Error) -> Void)?) {
        messageSent = message
        if messageDelay > 0 {
            let reply = mockReply
            let err = mockError
            Task {
                do {
                    try await Task.sleep(nanoseconds: messageDelay)
                    if let e = err { errorHandler?(e) }
                    else if let r = reply { replyHandler?(r) }
                    else { errorHandler?(NSError(domain: "mock", code: -1)) }
                } catch {
                    errorHandler?(error)
                }
            }
        } else {
            if let error = mockError {
                errorHandler?(error)
            } else if let reply = mockReply {
                replyHandler?(reply)
            } else {
                errorHandler?(NSError(domain: "mock", code: -1))
            }
        }
    }
    
    func transferUserInfo(_ userInfo: [String: Any]) -> WCSessionTransfer {
        userInfoTransferred = userInfo
        // Return a lightweight mock that doesn't require WCSessionUserInfoTransfer's
        // restricted init (which is unavailable on macOS without a companion device).
        return MockTransfer()
    }
    
    func updateApplicationContext(_ context: [String: Any]) throws {
        if let error = mockApplicationContextError {
            throw error
        }
        applicationContextUpdated = context
    }
}

final class WCSessionCoordinatorTests: XCTestCase {
    func testActivationSuccess() async throws {
        let mock = MockWCSession()
        let coordinator = WCSessionCoordinator(session: mock)
        mock.delegate = coordinator
        try await coordinator.activate()
        XCTAssertTrue(mock.activateCalled)
    }
    
    func testSendMessageSuccess() async throws {
        let mock = MockWCSession()
        mock.mockReply = ["success": true]
        let coordinator = WCSessionCoordinator(session: mock)
        let reply = try await coordinator.sendMessage(["test": 123])
        XCTAssertEqual(reply["success"] as? Bool, true)
    }
    
    func testSendMessageError() async {
        let mock = MockWCSession()
        mock.mockError = NSError(domain: "test", code: 1)
        let coordinator = WCSessionCoordinator(session: mock)
        do {
            _ = try await coordinator.sendMessage(["test": 123])
            XCTFail("Should throw")
        } catch WCSessionError.sendFailed { }
        catch { XCTFail("Wrong error") }
    }
    
    func testIncomingMessageRoutedToStream() async {
        let mock = MockWCSession()
        let coordinator = WCSessionCoordinator(session: mock)
        var received = false
        let task = Task {
            for await msg in await coordinator.messages {
                XCTAssertEqual(msg.payload["data"] as? String, "hello")
                msg.replyHandler(["ack": true])
                received = true
                break
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await coordinator.receiveMessage(["data": "hello"]) { reply in }
        await task.value
        XCTAssertTrue(received)
    }
    
    func testIncomingUserInfoRoutedToStream() async {
        let mock = MockWCSession()
        let coordinator = WCSessionCoordinator(session: mock)
        var received = false
        let task = Task {
            for await info in await coordinator.userInfos {
                received = true
                break
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await coordinator.receiveUserInfo(["data": "background"])
        await task.value
        XCTAssertTrue(received)
    }

    func testSendMessageFallbackWhenNotReachable() async {
        let mock = MockWCSession()
        mock.isReachable = false
        let coordinator = WCSessionCoordinator(session: mock)
        do {
            _ = try await coordinator.sendMessage(["alert": "critical"])
            XCTFail("Should throw notReachable")
        } catch let error as WCSessionError {
            XCTAssertEqual(error, .notReachable)
        } catch { XCTFail() }
        // Fallback should have called transferUserInfo
        XCTAssertEqual(mock.userInfoTransferred?["alert"] as? String, "critical")
    }

    func testSendMessageSkipFallback() async {
        let mock = MockWCSession()
        mock.isReachable = false
        let coordinator = WCSessionCoordinator(session: mock)
        do {
            _ = try await coordinator.sendMessage(["alert": "critical"], skipFallback: true)
            XCTFail("Should throw notReachable")
        } catch let error as WCSessionError {
            XCTAssertEqual(error, .notReachable)
        } catch { XCTFail() }
        XCTAssertNil(mock.userInfoTransferred)
    }

    func testUpdateApplicationContextSuccess() throws {
        let mock = MockWCSession()
        let coordinator = WCSessionCoordinator(session: mock)
        try coordinator.updateApplicationContext(["status": "ok"])
        XCTAssertEqual(mock.applicationContextUpdated?["status"] as? String, "ok")
    }

    func testUpdateApplicationContextError() {
        let mock = MockWCSession()
        mock.mockApplicationContextError = NSError(domain: "WCError", code: 7014)
        let coordinator = WCSessionCoordinator(session: mock)
        do { try coordinator.updateApplicationContext(["status": "ok"]); XCTFail("Should throw") }
        catch WCSessionError.applicationContextFailed { }
        catch { XCTFail() }
    }

    func testTransferUserInfoReturnsTransfer() {
        let mock = MockWCSession()
        let coordinator = WCSessionCoordinator(session: mock)
        let transfer = coordinator.transferUserInfo(["data": "batch"])
        XCTAssertFalse(transfer.isTransferring)
        XCTAssertEqual(mock.userInfoTransferred?["data"] as? String, "batch")
    }
}
