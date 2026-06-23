import XCTest
@testable import BridgeKit

final class BridgeDocumentCodingTests: XCTestCase {
    private func sampleDocument() -> BridgeDocument {
        let obs = Observation(
            id: "abc123",
            code: CodeableRef(system: "http://loinc.org", code: "29463-7", display: "Body weight"),
            name: "Body weight", value: .quantity(72.5), unit: "kg",
            effectiveDate: Date(timeIntervalSince1970: 1_700_000_000), category: .vital,
            mapping: HealthKitMapping(quantityType: "HKQuantityTypeIdentifierBodyMass",
                                      canonicalUnit: "kg", convertedValue: 72.5),
            confidence: 1.0, sourceLocator: nil)
        return BridgeDocument(
            schemaVersion: 1,
            source: Source(kind: .fhir, fileName: "x.json", sha256: "deadbeef",
                           extractedAt: Date(timeIntervalSince1970: 1_700_000_000),
                           extractor: Extractor(engine: "fhir-parser", version: "0.1.0")),
            subject: SubjectRef(id: "uuid-1", label: "Jane", hash: "abcd",
                                name: "Jane Public", dob: "2000-01-01"),
            observations: [obs])
    }
    func testRoundTrip() throws {
        let original = sampleDocument()
        let decoded = try BridgeJSON.decoder.decode(BridgeDocument.self, from: BridgeJSON.encoder.encode(original))
        XCTAssertEqual(original, decoded)
    }
    func testObservationValueEncodesTagged() throws {
        let json = String(decoding: try BridgeJSON.encoder.encode(ObservationValue.quantity(72.5)), as: UTF8.self)
        XCTAssertTrue(json.contains("\"type\" : \"quantity\""))
        XCTAssertTrue(json.contains("\"value\" : 72.5"))
    }
    func testDeterministicSortedKeys() throws {
        let json = String(decoding: try BridgeJSON.encoder.encode(sampleDocument()), as: UTF8.self)
        XCTAssertTrue(json.range(of: "\"category\"")!.lowerBound < json.range(of: "\"confidence\"")!.lowerBound)
    }
}
