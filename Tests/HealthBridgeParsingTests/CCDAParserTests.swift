import XCTest
import BridgeKit
@testable import HealthBridgeParsing

#if canImport(FoundationXML) || os(macOS)
final class CCDAParserTests: XCTestCase {
    private func fixture(_ n: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(n)", withExtension: "xml")))
    }
    private func parse(_ n: String) throws -> ParseResult { try CCDAParser().parse(try fixture(n), subjectId: "s") }

    func testCanParseDetectsCCDA() throws {
        XCTAssertTrue(CCDAParser.canParse(try fixture("ccda-minimal")))
        XCTAssertFalse(CCDAParser.canParse(Data(#"{"resourceType":"Observation"}"#.utf8)))
    }
    // Error handler first: malformed XML throws, not returns empty.
    func testMalformedThrows() throws {
        XCTAssertThrowsError(try parse("ccda-malformed")) {
            guard case ParseError.malformed = $0 else { return XCTFail("expected .malformed") }
        }
    }
    func testHL7TimestampUTC() {
        // "20250319093000+0000" -> 2025-03-19T09:30:00Z = 1_742_376_600
        XCTAssertEqual(CCDAParser.date(fromHL7TS: "20250319093000+0000")?.timeIntervalSince1970 ?? -1,
                       1_742_376_600, accuracy: 1)
    }
    func testHL7DateOnlyResolvesUTCMidnight() {
        // "20250319" -> 2025-03-19T00:00:00Z = 1_742_342_400, regardless of machine TZ.
        XCTAssertEqual(CCDAParser.date(fromHL7TS: "20250319")?.timeIntervalSince1970 ?? -1,
                       1_742_342_400, accuracy: 1)
    }
    func testParsesSingleVital() throws {
        let o = try XCTUnwrap(parse("ccda-minimal").observations.first { $0.code?.code == "29463-7" })
        XCTAssertEqual(o.code?.system, "http://loinc.org")
        XCTAssertEqual(o.name, "Body weight")
        XCTAssertEqual(o.value, .quantity(72.5)); XCTAssertEqual(o.unit, "kg")
        XCTAssertEqual(o.category, .vital); XCTAssertEqual(o.confidence, 1.0); XCTAssertNil(o.mapping)
        XCTAssertEqual(o.effectiveDate.timeIntervalSince1970, 1_742_376_600, accuracy: 1)
    }
    func testIdMatchesFHIRPathForSameContent() throws {
        // Same subject+LOINC+date+value+unit must yield the same id as the FHIR path (shared derive()).
        let o = try XCTUnwrap(parse("ccda-minimal").observations.first { $0.code?.code == "29463-7" })
        let expected = ObservationID.derive(subjectId: "s", system: "http://loinc.org", code: "29463-7",
                                            effectiveDate: o.effectiveDate, rawValue: "72.5", unit: "kg")
        XCTAssertEqual(o.id, expected)
    }
    // Regression (PR #1 crash): a large integral value must NOT trap String(Int(d)) and must
    // stringify via the SHARED helper identically to the FHIR path.
    func testLargeIntegralValueDoesNotTrap() throws {
        let o = try XCTUnwrap(parse("ccda-large-value").observations.first { $0.code?.code == "29463-7" })
        XCTAssertEqual(o.value, .quantity(1e20))
        // id is derived with the shared stableNumberString(1e20); compute the expected raw the same way.
        let expected = ObservationID.derive(subjectId: "s", system: "http://loinc.org", code: "29463-7",
                                            effectiveDate: o.effectiveDate, rawValue: stableNumberString(1e20), unit: "kg")
        XCTAssertEqual(o.id, expected)
    }
    func testStableNumberStringGuardsLargeIntegral() {
        // Shared single-source-of-truth helper: integral but > Int.max -> Double string, no trap.
        XCTAssertEqual(stableNumberString(1e20), String(1e20))
        XCTAssertEqual(stableNumberString(72), "72")
        XCTAssertEqual(stableNumberString(72.5), "72.5")
    }
    // MARK: multi-patient refusal (PHI-safety parity with M1)
    func testRefusesMultiplePatients() throws {
        XCTAssertThrowsError(try parse("ccda-multi-patient")) {
            guard case ParseError.malformed(let m) = $0 else { return XCTFail("expected .malformed") }
            XCTAssertTrue(m.lowercased().contains("patient"), m)
        }
    }
    func testAcceptsSinglePatient() throws {
        XCTAssertNoThrow(try parse("ccda-minimal"))   // exactly one recordTarget
    }
    // Adversarial: refusal keys on the COUNT of patients in the document, NOT the subjectId arg —
    // a 2-patient doc must refuse no matter which subject was selected (the exact cross-patient leak risk).
    func testRefusalIsIndependentOfSubjectId() throws {
        let data = try fixture("ccda-multi-patient")
        for subject in ["jane", "john", "", "anyone"] {
            XCTAssertThrowsError(try CCDAParser().parse(data, subjectId: subject)) {
                guard case ParseError.malformed = $0 else { return XCTFail("expected .malformed for subject=\(subject)") }
            }
        }
    }
}
#endif
