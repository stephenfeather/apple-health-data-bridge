import Foundation
import BridgeKit

/// Bridges PDF page text + an injected `LLMExtractor` into a `ParseResult`, reusing the M1/M2
/// mapping/dedupe/validate pipeline downstream.
///
/// Sync/async boundary: `DocumentParser.parse` is synchronous and the deterministic FHIR/C-CDA
/// parsers have no async work, so `PDFExtractor` does NOT conform to `DocumentParser`. It exposes its
/// own async `extractDocument(_:subjectId:)` (the only async, network-touching path), and the CLI
/// hard-special-cases PDF via `canParse` before any registry dispatch (Task 9). This keeps the
/// deterministic protocol sync-pure.
///
/// The network is fully isolated behind the injected `LLMExtractor`, so all extraction logic is
/// unit-tested with a mock extractor — zero network, zero API key.
public struct PDFExtractor {
    private let extractor: any LLMExtractor
    private let model: String

    public init(extractor: any LLMExtractor, model: String) {
        self.extractor = extractor
        self.model = model
    }

    /// Cheap `%PDF` magic-byte detection, available on all platforms (used by CLI routing).
    public static func canParse(_ data: Data) -> Bool { PDFText.isPDF(data) }

    #if canImport(PDFKit) && os(macOS)
    /// PDF bytes → page text (incl. the D3 page-cap) → extraction prompt → injected extractor →
    /// validated contract decode → `ParseResult`.
    ///
    /// PDF/text failures throw `ParseError` (bad/over-limit/no-text PDF, malformed contract JSON);
    /// transport/auth failures from the extractor propagate as `LLMError`.
    public func extractDocument(_ data: Data, subjectId: String) async throws -> ParseResult {
        let pages = try PDFText.pages(data)                       // ParseError on bad/over-limit/no-text
        let prompt = ExtractionPrompt.make(pages: pages)
        let request = LLMRequest(pages: pages, instructions: prompt, model: model)
        let raw = try await extractor.extract(request)           // LLMError on transport/auth
        return try LLMResponseContract.decode(raw.jsonText, subjectId: subjectId)   // ParseError on malformed
    }
    #endif
}
