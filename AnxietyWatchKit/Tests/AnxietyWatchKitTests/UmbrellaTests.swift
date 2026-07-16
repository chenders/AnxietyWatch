import XCTest
@testable import AnxietyWatchKit

final class UmbrellaTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(AnxietyWatchKit.version, "0.1.0-redesign")
    }
}