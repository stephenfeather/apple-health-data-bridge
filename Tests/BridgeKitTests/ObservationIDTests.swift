import XCTest
@testable import BridgeKit

final class ObservationIDTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    func testDeterministic() {
        let a = ObservationID.derive(subjectId: "s", system: "http://loinc.org", code: "29463-7",
                                     effectiveDate: date, rawValue: "72.5", unit: "kg")
        let b = ObservationID.derive(subjectId: "s", system: "http://loinc.org", code: "29463-7",
                                     effectiveDate: date, rawValue: "72.5", unit: "kg")
        XCTAssertEqual(a, b); XCTAssertEqual(a.count, 64)
    }
    func testValueChangesID() {
        let a = ObservationID.derive(subjectId: "s", system: nil, code: nil, effectiveDate: date, rawValue: "72.5", unit: "kg")
        let b = ObservationID.derive(subjectId: "s", system: nil, code: nil, effectiveDate: date, rawValue: "73.0", unit: "kg")
        XCTAssertNotEqual(a, b)
    }
    func testSubjectChangesID() {
        let a = ObservationID.derive(subjectId: "s1", system: nil, code: nil, effectiveDate: date, rawValue: "x", unit: nil)
        let b = ObservationID.derive(subjectId: "s2", system: nil, code: nil, effectiveDate: date, rawValue: "x", unit: nil)
        XCTAssertNotEqual(a, b)
    }
    func testSameContentSameSubjectSameID() {
        // Cross-file: identical clinical content for the same subject -> identical id (no documentKey).
        let a = ObservationID.derive(subjectId: "s", system: "http://loinc.org", code: "29463-7",
                                     effectiveDate: date, rawValue: "72.5", unit: "kg")
        let b = ObservationID.derive(subjectId: "s", system: "http://loinc.org", code: "29463-7",
                                     effectiveDate: date, rawValue: "72.5", unit: "kg")
        XCTAssertEqual(a, b)
    }
}
