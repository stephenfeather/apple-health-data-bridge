import Foundation
#if canImport(PDFKit) && os(macOS)
import PDFKit
#endif

/// PDFKit-backed page-text extraction for the PDF/LLM path.
///
/// The cheap `%PDF` magic-byte sniff (`isPDF`) is pure byte work and is available on every platform
/// (it is what the CLI/registry uses to recognize a PDF). The text-extracting `pages(_:)` requires
/// PDFKit and is therefore macOS-guarded — mirroring the M2 XML path, keeping all PHI-bearing parse
/// logic off the iOS writer (M1/M2 discipline; T3).
public enum PDFText {
    /// D3 large-PDF cap: documents over this page count are refused rather than chunk-merged.
    public static let maxPages = 30

    /// Cheap, framework-free `%PDF` prefix check for `canParse`. Does NOT open or parse the document.
    public static func isPDF(_ data: Data) -> Bool {
        data.starts(with: Data("%PDF".utf8))
    }

    #if canImport(PDFKit) && os(macOS)
    /// Extract per-page text, preserving page order.
    ///
    /// Throws `ParseError.malformed` when:
    /// - the bytes are not a PDF / `PDFDocument` will not open them;
    /// - the document exceeds `maxPages` (D3) — checked BEFORE any text extraction so an oversized
    ///   PDF is rejected cheaply;
    /// - every page yields empty/whitespace-only text (no extractable text layer — e.g. a scanned
    ///   or image-only PDF; OCR is out of scope for M3).
    public static func pages(_ data: Data) throws -> [String] {
        guard isPDF(data), let doc = PDFDocument(data: data) else {
            throw ParseError.malformed("not a readable PDF")
        }
        guard doc.pageCount <= maxPages else {
            throw ParseError.malformed("PDF exceeds \(maxPages)-page limit; refusing")
        }
        let texts = (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
        guard texts.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ParseError.malformed("no extractable text")
        }
        return texts
    }
    #endif
}
