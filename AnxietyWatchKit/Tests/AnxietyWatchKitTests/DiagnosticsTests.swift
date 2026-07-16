import XCTest
@testable import AnxietyWatchKit

final class DiagnosticsTests: XCTestCase {
    
    func testLoggersExist() {
        // Just referencing each logger to ensure they compile
        _ = Log.storage
        _ = Log.sync
        _ = Log.hlc
        _ = Log.ble
        _ = Log.pipeline
        _ = Log.transport
        _ = Log.wc
        _ = Log.panic
        _ = Log.migration
        _ = Log.diag
    }
    
    func testSignpostersExist() {
        // Just referencing each signposter to ensure they compile
        _ = Signposts.storage
        _ = Signposts.sync
        _ = Signposts.hlc
        _ = Signposts.ble
        _ = Signposts.pipeline
        _ = Signposts.transport
        _ = Signposts.wc
        _ = Signposts.panic
        _ = Signposts.migration
        _ = Signposts.diag
    }
    
    func testSignpostEmitEvent() {
        // Test that emitEvent executes without crashing
        Signposts.storage.emitEvent("test")
    }
}