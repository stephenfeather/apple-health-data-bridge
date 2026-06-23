import XCTest
import BridgeKit
import HealthBridgeConfig
@testable import healthbridge

final class BridgeBuilderTests: XCTestCase {
    private func fixture(_ n: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(n)", withExtension: "json")))
    }
    private let subject = SubjectRef(id: "11111111-1111-1111-1111-111111111111", label: "Jane",
                                     hash: "h", name: "Jane Public", dob: "2000-01-01")
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    private func entry(_ name: String, _ dob: String, key: String = "jane") -> SubjectEntry {
        SubjectEntry(key: key, subjectId: "uuid", label: "L", name: name, dob: dob)
    }

    func testBuildsValidSubjectBoundDocument() throws {
        let r = try BridgeBuilder.build(data: try fixture("bundle-vitals-and-labs"), fileName: "f.json", subject: subject, now: fixedNow)
        XCTAssertEqual(r.document.subject.id, subject.id)
        XCTAssertEqual(r.document.observations.count, 2)
        XCTAssertEqual(try XCTUnwrap(r.document.observations.first { $0.code?.code == "29463-7" }).mapping?.quantityType,
                       "HKQuantityTypeIdentifierBodyMass")
        XCTAssertNil(try XCTUnwrap(r.document.observations.first { $0.code?.code == "1742-6" }).mapping)
        XCTAssertFalse(validate(r.document).contains { $0.severity == .error })
    }
    func testDedupes() throws {
        XCTAssertEqual(try BridgeBuilder.build(data: try fixture("bundle-duplicate"), fileName: "d.json", subject: subject, now: fixedNow).document.observations.count, 1)
    }
    func testDeterministicWithFixedClock() throws {
        let d = try fixture("bundle-vitals-and-labs")
        let a = try BridgeJSON.encoder.encode(BridgeBuilder.build(data: d, fileName: "f.json", subject: subject, now: fixedNow).document)
        let b = try BridgeJSON.encoder.encode(BridgeBuilder.build(data: d, fileName: "f.json", subject: subject, now: fixedNow).document)
        XCTAssertEqual(a, b)
    }
    func testCrossCheckMatch() throws {
        XCTAssertEqual(PatientMatch.check(data: try fixture("patient-bundle"), subject: entry("Jane Public", "2000-01-01")), .match)
    }
    func testCrossCheckMismatch() throws {
        XCTAssertEqual(PatientMatch.check(data: try fixture("patient-bundle-mismatch"), subject: entry("Jane Public", "2000-01-01")), .mismatch)
    }
    func testCrossCheckNoPatient() throws {
        XCTAssertEqual(PatientMatch.check(data: try fixture("bundle-duplicate"), subject: entry("Jane Public", "2000-01-01")), .noPatient)
    }
    func testCrossCheckFlexibleMiddleName() throws {
        // Roster "Jane Public" should still match a document Patient "Jane Q Public" (first+last tokens).
        XCTAssertEqual(PatientMatch.check(data: try fixture("patient-bundle"), subject: entry("Jane Q Public", "2000-01-01")), .match)
    }
}
