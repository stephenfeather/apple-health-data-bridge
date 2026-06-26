import XCTest
import HealthBridgeParsing
@testable import bridge_eval

/// Cross-platform loader tests for the `pages.txt` input path. They write a REAL fixture into a temp
/// dir (zero PDFKit, zero network) and exercise the `resolveCaseInput` seam over both arms. The `.pdf`
/// arm is proven existence-only: arbitrary bytes are written to `input.pdf` and never parsed.
private struct StubExtractor: LLMExtractor {
    let json: String
    func extract(_ request: LLMRequest) async throws -> LLMRawResponse {
        LLMRawResponse(jsonText: json, meta: nil)
    }
}

final class PagesTextLoaderTests: XCTestCase {
    private func makeTempCaseDir(_ caseName: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-eval-pagestxt-\(UUID().uuidString)")
        let caseDir = root.appendingPathComponent(caseName)
        try FileManager.default.createDirectory(at: caseDir, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - resolveCaseInput seam (real dir, both arms)

    func testResolveCaseInputPagesOnly() throws {
        let root = try makeTempCaseDir("promptonly")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("page one\u{000C}page two",
                  to: root.appendingPathComponent("promptonly/pages.txt"))

        let resolved = try Fixtures.resolveCaseInput(root: root.path, caseName: "promptonly")
        guard case let .pages(pages, raw) = resolved else { return XCTFail("expected .pages, got \(resolved)") }
        XCTAssertEqual(pages, ["page one", "page two"])
        XCTAssertFalse(raw.isEmpty)
    }

    func testResolveCaseInputPDFWinsWithoutParsing() throws {
        let root = try makeTempCaseDir("both")
        defer { try? FileManager.default.removeItem(at: root) }
        // Arbitrary, NON-PDF bytes — existence-only check must NOT parse them.
        try write("this is not a pdf at all", to: root.appendingPathComponent("both/input.pdf"))
        try write("p1\u{000C}p2", to: root.appendingPathComponent("both/pages.txt"))

        let resolved = try Fixtures.resolveCaseInput(root: root.path, caseName: "both")
        guard case let .pdf(url) = resolved else { return XCTFail("expected .pdf, got \(resolved)") }
        XCTAssertEqual(url.lastPathComponent, "input.pdf")
    }

    func testResolveCaseInputNeitherThrows() throws {
        let root = try makeTempCaseDir("empty")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try Fixtures.resolveCaseInput(root: root.path, caseName: "empty")) { error in
            XCTAssertTrue(error is Fixtures.LoadError)
        }
    }

    // MARK: - pagesText I/O wrapper

    func testPagesTextNilWhenAbsent() throws {
        let root = try makeTempCaseDir("nopages")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(try Fixtures.pagesText(root: root.path, caseName: "nopages"))
    }

    // MARK: - temp-dir loader end-to-end through RunCore (pages flow unchanged; inputHash non-empty)

    func testTempDirLoaderFlowsThroughRunCore() async throws {
        let root = try makeTempCaseDir("promptonly")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Heart rate 72.5 /min on 2024-01-15",
                  to: root.appendingPathComponent("promptonly/pages.txt"))
        let expectedJSON = """
        {"patients":[{"name":"Jane Public","dob":"1990-05-01"}],
         "observations":[{"loinc":"8867-4","display":"Heart rate","value":72.5,"valueText":null,
                          "unit":"/min","effectiveDate":"2024-01-15","category":"vital"}]}
        """
        try write(expectedJSON, to: root.appendingPathComponent("promptonly/expected.json"))

        // discoverCases keys on expected.json -> includes the pages.txt-only case.
        let cases = try Fixtures.discoverCases(root: root.path)
        XCTAssertTrue(cases.contains("promptonly"))

        let txt = try XCTUnwrap(try Fixtures.pagesText(root: root.path, caseName: "promptonly"))
        XCTAssertEqual(txt.pages, ["Heart rate 72.5 /min on 2024-01-15"])
        XCTAssertFalse(txt.raw.isEmpty)

        let expected = try Fixtures.loadExpected(root: root.path, caseName: "promptonly")
        XCTAssertEqual(expected.patients.first?.name, "Jane Public")

        let goodJSON = """
        {"patients":[{"name":"Jane Public","dob":"1990-05-01"}],
         "observations":[{"loinc":"8867-4","display":"Heart rate","value":72.5,"unit":"/min",
                          "effectiveDate":"2024-01-15","category":"vital","confidence":0.9}]}
        """
        let now = LLMResponseContract.parseDate("2026-06-24")!
        let (raw, score) = try await RunCore.runCase(
            pdfData: txt.raw, pages: txt.pages, model: "m", fixture: "promptonly", sample: 0,
            extractor: StubExtractor(json: goodJSON), expected: expected, subjectId: "subj", now: now)
        XCTAssertFalse(raw.inputHash.isEmpty)   // raw pages.txt bytes -> meaningful inputHash provenance
        XCTAssertEqual(score.strict.f1, 1.0, accuracy: 1e-9)
    }
}
