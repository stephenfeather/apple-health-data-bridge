import XCTest
import BridgeKit
@testable import HealthBridgeParsing

/// Pins that M3 maps INTO the existing schema with no changes: SourceKind.pdf exists,
/// and an Observation carries a model confidence (<1) and a populated SourceLocator that round-trip.
final class PDFSchemaTargetTests: XCTestCase {
    func testPDFSourceKindExists() {
        XCTAssertEqual(SourceKind.pdf.rawValue, "pdf")
    }

    func testObservationCarriesConfidenceAndLocator() throws {
        let o = Observation(
            id: "x",
            code: CodeableRef(system: "http://loinc.org", code: "29463-7", display: "Body weight"),
            name: "Body weight", value: .quantity(72.5), unit: "kg",
            effectiveDate: Date(timeIntervalSince1970: 0), category: .vital,
            mapping: nil, confidence: 0.82, sourceLocator: SourceLocator(page: 2, snippet: "Weight 72.5 kg"))
        let data = try BridgeJSON.encoder.encode(o)
        let back = try BridgeJSON.decoder.decode(Observation.self, from: data)
        XCTAssertEqual(back.confidence, 0.82, accuracy: 1e-9)
        XCTAssertEqual(back.sourceLocator?.page, 2)
        XCTAssertEqual(back.sourceLocator?.snippet, "Weight 72.5 kg")
    }

    /// T3 sentinel — UN-guarded (no `#if os(macOS)` around the test): fails loudly if the PDF path
    /// was compiled OUT on the platform that is supposed to run it. On macOS the guarded path MUST
    /// be present; on Linux it is legitimately absent (and the test records that M3 was NOT exercised),
    /// so a Linux run can never masquerade as a passing M3 run. Tighten the macOS assertion once
    /// `PDFText` exists (Task 2): replace the `true` with `PDFText.isPDF(Data("%PDF".utf8))`.
    func testPDFPathIsCompiledInOnMacOS() {
        #if os(macOS)
        // Touches the guarded PDF path for real: if PDFText compiled out on macOS this fails to build/run.
        XCTAssertTrue(PDFText.isPDF(Data("%PDF".utf8)), "M3 PDF path compiled in on macOS")
        #else
        // Not macOS: M3 PDF path is intentionally compiled out. This run did NOT exercise M3 —
        // the macOS green gate (T3) is the authoritative one. Marked, not silently green.
        print("NOTE: M3 PDF path compiled out (non-macOS) — M3 NOT exercised on this runner (T3).")
        #endif
    }
}
