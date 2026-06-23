import XCTest
import BridgeKit
@testable import HealthBridgeParsing

/// Pins the contract that M2 maps INTO the existing schema with no changes:
/// SourceKind.ccda exists, and an Observation can be constructed exactly as the FHIR path does.
final class CCDASchemaTargetTests: XCTestCase {
    func testCCDASourceKindExists() {
        XCTAssertEqual(SourceKind.ccda.rawValue, "ccda")
    }
    func testObservationConstructsForCCDA() {
        let o = Observation(
            id: "x", code: CodeableRef(system: "http://loinc.org", code: "8480-6", display: "Systolic"),
            name: "Systolic BP", value: .quantity(120), unit: "mm[Hg]",
            effectiveDate: Date(timeIntervalSince1970: 0), category: .vital,
            mapping: nil, confidence: 1.0, sourceLocator: nil)
        XCTAssertEqual(o.code?.code, "8480-6"); XCTAssertEqual(o.confidence, 1.0)
    }
    func testQualitativeValueIsString() {
        XCTAssertEqual(ObservationValue.string("Hypertension"), .string("Hypertension"))
    }
}
