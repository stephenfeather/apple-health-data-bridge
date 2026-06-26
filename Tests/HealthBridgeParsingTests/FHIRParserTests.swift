import XCTest
import BridgeKit
@testable import HealthBridgeParsing

final class FHIRParserTests: XCTestCase {
    private func fixture(_ n: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(n)", withExtension: "json")))
    }
    private func parse(_ n: String) throws -> ParseResult { try FHIRParser().parse(try fixture(n), subjectId: "s") }

    func testCanParseDetectsFHIR() throws {
        XCTAssertTrue(FHIRParser.canParse(try fixture("observation-bodyweight")))
        XCTAssertFalse(FHIRParser.canParse(Data("<ClinicalDocument/>".utf8)))
    }
    func testParsesSingleObservation() throws {
        let o = try XCTUnwrap(parse("observation-bodyweight").observations.first)
        XCTAssertEqual(o.code?.code, "29463-7"); XCTAssertEqual(o.code?.system, "http://loinc.org")
        XCTAssertEqual(o.name, "Body weight"); XCTAssertEqual(o.value, .quantity(72.5)); XCTAssertEqual(o.unit, "kg")
        XCTAssertEqual(o.category, .vital); XCTAssertEqual(o.confidence, 1.0); XCTAssertNil(o.mapping)
        XCTAssertEqual(o.effectiveDate.timeIntervalSince1970, 1_742_391_000, accuracy: 1)
    }
    func testParsesBundle() throws {
        let r = try parse("bundle-vitals-and-labs")
        XCTAssertEqual(r.observations.count, 2)
        XCTAssertEqual(r.observations.first?.category, .vital); XCTAssertEqual(r.observations.last?.category, .lab)
    }
    func testBloodPressurePanelYieldsTwoMappableComponents() throws {
        let r = try parse("bp-panel")
        XCTAssertEqual(r.observations.count, 2)
        let codes = Set(r.observations.compactMap { $0.code?.code })
        XCTAssertEqual(codes, ["8480-6", "8462-4"])
        for o in r.observations {
            XCTAssertNotNil(MappingTable.resolve(loinc: o.code?.code, value: o.value, unit: o.unit))
        }
    }
    func testDateOnlyResolvesUTCMidnight() throws {
        // "2025-03-19" -> 2025-03-19T00:00:00Z = 1_742_342_400, regardless of machine TZ.
        let o = try XCTUnwrap(parse("observation-dateonly").observations.first)
        XCTAssertEqual(o.effectiveDate.timeIntervalSince1970, 1_742_342_400, accuracy: 1)
    }
    func testLOINCNotFirstCodingIsChosen() throws {
        XCTAssertEqual(try parse("observation-loinc-not-first").observations.first?.code?.code, "29463-7")
    }
    func testValueStringObservation() throws {
        let o = try XCTUnwrap(parse("observation-string").observations.first)
        XCTAssertEqual(o.value, .string("positive")); XCTAssertNil(o.unit)
    }
    func testNoValueIsSkipped() throws {
        let r = try parse("observation-novalue")
        XCTAssertEqual(r.observations.count, 0)
        XCTAssertEqual(r.skipped.first?.reason, .unrepresentableValue)
    }
    func testDropsAndRecordsCodeless() throws {
        let r = try parse("observation-nocode")
        XCTAssertEqual(r.observations.count, 0)
        XCTAssertEqual(r.skipped.first?.reason, .noCode); XCTAssertEqual(r.skipped.first?.label, "Free text only")
    }
    func testMalformedThrows() { XCTAssertThrowsError(try FHIRParser().parse(Data("{ not".utf8), subjectId: "s")) }
    func testHugeValueDoesNotCrash() throws {
        // 1e20 is integral but overflows Int — stableNumberString must not trap.
        let o = try XCTUnwrap(parse("observation-hugevalue").observations.first)
        XCTAssertEqual(o.value, .quantity(1e20))
    }

    // MARK: - Plausible-date guard adoption (parity with the LLM path)
    // The bundle carries Patient.birthDate 2000-01-01 plus three weight observations:
    // 1995-06-01 (before DOB), 2099-01-01 (after now), 2010-05-05 (plausible). `now` is pinned.
    private static let fixedNow = LLMResponseContract.parseDate("2026-06-24")!

    func testFHIRDropsObservationBeforeDOB() throws {   // error handler
        let r = try FHIRParser(now: Self.fixedNow).parse(try fixture("fhir-implausible-dates"), subjectId: "s")
        XCTAssertFalse(r.observations.contains { $0.value == .quantity(70) },
                       "1995-06-01 obs predates DOB 2000-01-01 and must be dropped")
        XCTAssertTrue(r.skipped.contains { $0.reason == .implausibleDate && $0.detail == .dateBeforeDOB })
    }
    func testFHIRDropsObservationAfterNow() throws {   // error handler
        let r = try FHIRParser(now: Self.fixedNow).parse(try fixture("fhir-implausible-dates"), subjectId: "s")
        XCTAssertFalse(r.observations.contains { $0.value == .quantity(71) },
                       "2099-01-01 obs is after now and must be dropped")
        XCTAssertTrue(r.skipped.contains { $0.reason == .implausibleDate && $0.detail == .dateAfterNow })
    }
    func testFHIRKeepsPlausibleObservation() throws {   // happy path
        let r = try FHIRParser(now: Self.fixedNow).parse(try fixture("fhir-implausible-dates"), subjectId: "s")
        XCTAssertEqual(r.observations.count, 1)
        XCTAssertEqual(r.observations.first?.value, .quantity(72), "only the 2010-05-05 obs is plausible")
        XCTAssertEqual(r.skipped.filter { $0.reason == .implausibleDate }.count, 2)
    }
    func testFHIRNilDOBKeepsPlausibleObservation() throws {   // nil-DOB guard
        // No Patient resource → dob resolves to nil. A plausible effectiveDate must NOT be over-rejected.
        let r = try FHIRParser(now: Self.fixedNow).parse(try fixture("fhir-nil-dob"), subjectId: "s")
        XCTAssertEqual(r.observations.count, 1,
                       "observation with plausible date and nil DOB must pass through")
        XCTAssertEqual(r.observations.first?.value, .quantity(73))
    }
}
