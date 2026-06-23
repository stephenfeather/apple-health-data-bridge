import XCTest
import BridgeKit
@testable import HealthBridgeParsing

final class ParserRegistryTests: XCTestCase {
    private func fixture(_ n: String, _ ext: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(n)", withExtension: ext)))
    }
    func testDetectsFHIR() throws {
        XCTAssertEqual(ParserRegistry.sourceKind(for: try fixture("observation-bodyweight", "json")), .fhir)
    }
    func testReturnsParserForFHIR() throws {
        XCTAssertNotNil(ParserRegistry.parser(for: try fixture("observation-bodyweight", "json")))
    }
    func testUnknownReturnsNil() {
        XCTAssertNil(ParserRegistry.parser(for: Data("plain text".utf8)))
        XCTAssertNil(ParserRegistry.sourceKind(for: Data("plain text".utf8)))
    }
    #if canImport(FoundationXML) || os(macOS)
    func testDetectsCCDA() throws {
        XCTAssertEqual(ParserRegistry.sourceKind(for: try fixture("ccda-minimal", "xml")), .ccda)
        XCTAssertNotNil(ParserRegistry.parser(for: try fixture("ccda-minimal", "xml")))
    }
    // No cross-detection, direction 1: a C-CDA XML must NOT be detected as FHIR.
    func testCCDAIsNotDetectedAsFHIR() throws {
        let xml = try fixture("ccda-minimal", "xml")
        XCTAssertFalse(FHIRParser.canParse(xml))
        XCTAssertNotEqual(ParserRegistry.sourceKind(for: xml), .fhir)
    }
    // No cross-detection, direction 2: a FHIR JSON must NOT be detected as C-CDA.
    func testFHIRIsNotDetectedAsCCDA() throws {
        let json = try fixture("observation-bodyweight", "json")
        XCTAssertFalse(CCDAParser.canParse(json))
        XCTAssertNotEqual(ParserRegistry.sourceKind(for: json), .ccda)
    }
    #endif
}
