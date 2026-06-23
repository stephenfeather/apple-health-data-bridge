import XCTest
@testable import BridgeKit

final class ValidationTests: XCTestCase {
    private let goodSha = String(repeating: "a", count: 64)
    private let goodUUID = "11111111-1111-1111-1111-111111111111"

    private func doc(_ obs: [Observation], schemaVersion: Int = 1, sha: String? = nil,
                     subjectId: String? = nil, hash: String = "h") -> BridgeDocument {
        BridgeDocument(schemaVersion: schemaVersion,
            source: Source(kind: .fhir, fileName: "f.json", sha256: sha ?? goodSha,
                           extractedAt: Date(timeIntervalSince1970: 0), extractor: Extractor(engine: "x", version: "1")),
            subject: SubjectRef(id: subjectId ?? goodUUID, label: "L", hash: hash), observations: obs)
    }
    private func obs(_ id: String = "a", name: String = "x", value: ObservationValue = .quantity(1),
                     mapping: HealthKitMapping? = nil, confidence: Double = 1.0) -> Observation {
        Observation(id: id, code: nil, name: name, value: value, unit: "kg",
                    effectiveDate: Date(timeIntervalSince1970: 0), category: .vital,
                    mapping: mapping, confidence: confidence, sourceLocator: nil)
    }
    private func errors(_ d: BridgeDocument) -> Bool { validate(d).contains { $0.severity == .error } }

    func testValid() { XCTAssertFalse(errors(doc([obs()]))) }
    func testWrongSchema() { XCTAssertTrue(errors(doc([obs()], schemaVersion: 99))) }
    func testBadShaLength() { XCTAssertTrue(errors(doc([obs()], sha: "abc"))) }
    func testEmptySubjectId() { XCTAssertTrue(errors(doc([obs()], subjectId: ""))) }
    func testInvalidSubjectUUID() { XCTAssertTrue(errors(doc([obs()], subjectId: "not-a-uuid"))) }
    func testEmptySubjectHash() { XCTAssertTrue(errors(doc([obs()], hash: ""))) }
    func testDuplicateIDs() { XCTAssertTrue(validate(doc([obs("a"), obs("a")])).contains { $0.message.contains("duplicate") }) }
    func testEmptyObservationId() { XCTAssertTrue(errors(doc([obs("")]))) }
    func testConfidenceOutOfRange() { XCTAssertTrue(errors(doc([obs(confidence: 1.5)]))) }
    func testEmptyObservationName() { XCTAssertTrue(errors(doc([obs(name: "")]))) }
    func testNonFiniteValue() { XCTAssertTrue(errors(doc([obs(value: .quantity(.nan))]))) }
    func testMappingOnString() {
        XCTAssertTrue(errors(doc([obs(value: .string("p"), mapping: HealthKitMapping(quantityType: "X", canonicalUnit: "kg", convertedValue: 1))])))
    }
    func testNonFiniteConverted() {
        XCTAssertTrue(errors(doc([obs(mapping: HealthKitMapping(quantityType: "X", canonicalUnit: "kg", convertedValue: .infinity))])))
    }
    func testEmptyMappingField() {
        XCTAssertTrue(errors(doc([obs(mapping: HealthKitMapping(quantityType: "", canonicalUnit: "kg", convertedValue: 1))])))
    }
    func testEmptyObservationsWarns() {
        let issues = validate(doc([]))
        XCTAssertTrue(issues.contains { $0.severity == .warning })
        XCTAssertFalse(issues.contains { $0.severity == .error })
    }
}
