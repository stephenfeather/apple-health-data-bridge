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
    /// validated contract decode → `PDFExtraction` (the `ParseResult` PLUS the model-extracted patient
    /// identity, surfaced so the CLI can verify it against the bound subject — wrong-file protection).
    ///
    /// PDF/text failures throw `ParseError` (bad/over-limit/no-text PDF, malformed contract JSON);
    /// transport/auth failures from the extractor propagate as `LLMError`.
    public func extractDocument(_ data: Data, subjectId: String,
                                subjectDOB: Date? = nil, now: Date = Date()) async throws -> PDFExtraction {
        let pages = try PDFText.pages(data)                       // ParseError on bad/over-limit/no-text
        let prompt = ExtractionPrompt.make(pages: pages)
        let request = LLMRequest(pages: pages, instructions: prompt, model: model)
        let raw = try await extractor.extract(request)           // LLMError on transport/auth
        // D4 single-subject binding parity: refuse a PDF whose response reports >1 distinct patient,
        // before mapping any observations into the selected subject (double-protection vs M1/M2).
        guard try LLMResponseContract.distinctPatientCount(raw.jsonText) <= 1 else {
            throw ParseError.malformed("multiple patients in PDF — refusing")
        }
        let patient = try LLMResponseContract.extractedPatient(raw.jsonText)
        // subjectDOB (verified roster DOB) + now drive the plausible-date guard inside decode.
        // deferred (#3): truncation-as-error
        let result = try LLMResponseContract.decode(raw.jsonText, subjectId: subjectId,
                                                    subjectDOB: subjectDOB, now: now)   // ParseError on malformed
        return PDFExtraction(result: result, extractedPatient: patient, meta: raw.meta)
    }
    #endif
}

/// The PDF extraction outcome: the parsed observations/skips PLUS the model-extracted patient identity
/// (UNTRUSTED — the CLI compares it to the bound subject to catch a wrong-file import).
public struct PDFExtraction {
    public let result: ParseResult
    public let extractedPatient: (name: String, dob: String)?
    /// Provider response meta (#3) — additive observability for the CLI verbose log; nil when absent.
    public let meta: LLMResponseMeta?
    public init(result: ParseResult, extractedPatient: (name: String, dob: String)?,
                meta: LLMResponseMeta? = nil) {
        self.result = result
        self.extractedPatient = extractedPatient
        self.meta = meta
    }
}
