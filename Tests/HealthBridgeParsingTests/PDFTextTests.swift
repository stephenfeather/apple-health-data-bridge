import XCTest
@testable import HealthBridgeParsing

#if canImport(PDFKit) && os(macOS)
final class PDFTextTests: XCTestCase {
    private func fixture(_ n: String, _ ext: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(n)", withExtension: ext)))
    }

    func testIsPDFMagicBytes() throws {
        XCTAssertTrue(PDFText.isPDF(try fixture("pdf-minimal", "pdf")))
        XCTAssertFalse(PDFText.isPDF(try fixture("not-a-pdf", "bin")))
    }

    func testNonPDFThrows() throws {   // error handler first
        XCTAssertThrowsError(try PDFText.pages(try fixture("not-a-pdf", "bin"))) {
            guard case ParseError.malformed = $0 else { return XCTFail("expected .malformed") }
        }
    }

    func testOverPageLimitThrows() throws {   // D3 — refusal before happy path
        XCTAssertThrowsError(try PDFText.pages(try fixture("pdf-over-limit", "pdf"))) {
            guard case ParseError.malformed(let m) = $0 else { return XCTFail("expected .malformed") }
            XCTAssertTrue(m.lowercased().contains("page") || m.contains("\(PDFText.maxPages)"), m)
        }
    }

    func testNoTextPDFThrows() throws {
        XCTAssertThrowsError(try PDFText.pages(try fixture("pdf-no-text", "pdf"))) {
            guard case ParseError.malformed(let m) = $0 else { return XCTFail("expected .malformed") }
            XCTAssertTrue(m.lowercased().contains("text"), m)
        }
    }

    func testExtractsPageText() throws {
        let pages = try PDFText.pages(try fixture("pdf-minimal", "pdf"))
        XCTAssertEqual(pages.count, 1)
        XCTAssertTrue(pages[0].contains("72.5"))
    }

    func testTwoPagesPreserveOrder() throws {
        let pages = try PDFText.pages(try fixture("pdf-two-page", "pdf"))
        XCTAssertEqual(pages.count, 2)
    }
}
#endif
