import Foundation
import Testing

@testable import AnxietyWatch

struct AS11StreamModelsTests {
    @Test(
        "Missing and unknown AS11 states fail safe to stream stalled",
        arguments: [nil, "UNKNOWN_STATE"] as [String?]
    )
    func invalidStateFailsSafe(rawValue: String?) {
        #expect(AS11StreamState(from: rawValue) == .streamStalled)
    }
}
