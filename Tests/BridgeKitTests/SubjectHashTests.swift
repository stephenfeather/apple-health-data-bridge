import XCTest
@testable import BridgeKit

final class SubjectHashTests: XCTestCase {
    func testDeterministicAndCanonical() {
        XCTAssertEqual(SubjectHash.make(name: "Jane Public", dob: "2000-01-01"),
                       SubjectHash.make(name: "  jane public ", dob: "2000-01-01"))
    }
    func testDifferentPeopleDiffer() {
        XCTAssertNotEqual(SubjectHash.make(name: "Jane Public", dob: "2000-01-01"),
                          SubjectHash.make(name: "John Sample", dob: "1980-06-15"))
    }
}
