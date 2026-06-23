import XCTest
@testable import HealthBridgeParsing

#if canImport(FoundationXML) || os(macOS)
final class CDAXMLTests: XCTestCase {
    private func fixture(_ n: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(n)", withExtension: "xml")))
    }
    func testLoadsWellFormed() throws {
        XCTAssertNoThrow(try CDAXML.document(try fixture("ccda-minimal")))
    }
    func testMalformedThrows() throws {
        XCTAssertThrowsError(try CDAXML.document(try fixture("ccda-malformed"))) {
            guard case ParseError.malformed = $0 else { return XCTFail("expected .malformed, got \($0)") }
        }
    }
    func testIsClinicalDocument() throws {
        XCTAssertTrue(CDAXML.isClinicalDocument(try fixture("ccda-minimal")))
        XCTAssertFalse(CDAXML.isClinicalDocument(Data(#"{"resourceType":"Bundle"}"#.utf8)))
    }
    func testFindsSectionsByLocalNameAcrossDefaultNamespace() throws {
        let doc = try CDAXML.document(try fixture("ccda-minimal"))
        let sections = try CDAXML.elements(doc.rootElement()!, localName: "section")
        XCTAssertEqual(sections.count, 2)   // proves default-namespace XPath works
    }
    func testReadsAttribute() throws {
        let doc = try CDAXML.document(try fixture("ccda-minimal"))
        let values = try CDAXML.elements(doc.rootElement()!, localName: "value")
        XCTAssertEqual(CDAXML.attr(values.first!, "value"), "72.5")
        XCTAssertEqual(CDAXML.attr(values.first!, "unit"), "kg")
    }
}
#endif
