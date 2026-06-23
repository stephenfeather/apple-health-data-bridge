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
}
