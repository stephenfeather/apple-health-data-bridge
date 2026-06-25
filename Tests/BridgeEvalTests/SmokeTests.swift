import XCTest
@testable import bridge_eval

final class SmokeTests: XCTestCase {
    func testVersionIsPresent() {
        XCTAssertEqual(BridgeEvalVersion.current, "0.1.0")
    }
}
