import XCTest
import BridgeKit
@testable import HealthBridgeParsing

private struct StubParser: DocumentParser {
    static func canParse(_ data: Data) -> Bool { !data.isEmpty }
    func parse(_ data: Data, subjectId: String) throws -> ParseResult {
        guard !data.isEmpty else { throw ParseError.malformed("empty") }
        return ParseResult(observations: [], skipped: [Skip(reason: .noCode, label: "x")])
    }
}

final class DocumentParserTests: XCTestCase {
    func testCanParse() { XCTAssertTrue(StubParser.canParse(Data([0x7b]))); XCTAssertFalse(StubParser.canParse(Data())) }
    func testParseThrowsOnEmpty() {
        XCTAssertThrowsError(try StubParser().parse(Data(), subjectId: "s")) { XCTAssertEqual($0 as? ParseError, .malformed("empty")) }
    }
    func testParseResultCarriesSkips() throws {
        XCTAssertEqual(try StubParser().parse(Data([0x7b]), subjectId: "s").skipped.first?.reason, .noCode)
    }
}
