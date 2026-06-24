import XCTest
import BridgeKit
@testable import HealthBridgeParsing

#if canImport(PDFKit) && os(macOS)
final class PDFExtractorTests: XCTestCase {
    private func fixture(_ n: String, _ ext: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(n)", withExtension: ext)))
    }
    private func fixtureText(_ n: String) throws -> String {
        try String(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(n)", withExtension: "json")),
                   encoding: .utf8)
    }

    /// In-file mock — returns canned JSON, never touches the network or a real key.
    struct MockLLMExtractor: LLMExtractor {
        let reply: String
        func extract(_ request: LLMRequest) async throws -> LLMRawResponse { .init(jsonText: reply) }
    }
    struct ThrowingLLMExtractor: LLMExtractor {
        let error: LLMError
        func extract(_ request: LLMRequest) async throws -> LLMRawResponse { throw error }
    }

    // MARK: - Error handlers first

    func testCanParseDetectsPDF() throws {
        XCTAssertTrue(PDFExtractor.canParse(try fixture("pdf-minimal", "pdf")))
        XCTAssertFalse(PDFExtractor.canParse(Data("not a pdf".utf8)))
    }

    func testExtractorErrorPropagates() async throws {
        let ex = PDFExtractor(extractor: ThrowingLLMExtractor(error: .http(status: 401)), model: "m")
        do {
            _ = try await ex.extractDocument(try fixture("pdf-minimal", "pdf"), subjectId: "s")
            XCTFail("expected LLMError to propagate")
        } catch let e as LLMError {
            XCTAssertEqual(e, .http(status: 401))
        }
    }

    func testNoTextPDFRefuses() async throws {
        let ex = PDFExtractor(extractor: MockLLMExtractor(reply: "{}"), model: "m")
        do {
            _ = try await ex.extractDocument(try fixture("pdf-no-text", "pdf"), subjectId: "s")
            XCTFail("expected ParseError.malformed")
        } catch let e as ParseError {
            guard case .malformed = e else { return XCTFail("expected .malformed") }
        }
    }

    // MARK: - Happy path

    func testHappyPathProducesObservations() async throws {
        let ex = PDFExtractor(extractor: MockLLMExtractor(reply: try fixtureText("llm-response-valid")), model: "m")
        let r = try await ex.extractDocument(try fixture("pdf-minimal", "pdf"), subjectId: "s")
        XCTAssertFalse(r.observations.isEmpty)
        let vital = try XCTUnwrap(r.observations.first { $0.category == .vital })
        XCTAssertEqual(vital.confidence, 0.9, accuracy: 1e-9)   // model confidence flows through
    }
}
#endif
