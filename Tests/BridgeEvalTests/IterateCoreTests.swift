import XCTest
@testable import bridge_eval
import HealthBridgeParsing

final class IterateCoreTests: XCTestCase {
    /// Pattern C: a fresh temp dir per test, cleaned up after.
    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-eval-iterate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ contents: String, named name: String, in dir: URL) throws {
        try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // MARK: - loadVariants

    func testLoadVariantsReadsTxtDirInLexicalOrder() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Write out of lexical order to prove sorting; include a non-.txt file that must be ignored.
        try write("beta {{DOCUMENT}} body", named: "b-second.txt", in: dir)
        try write("alpha {{DOCUMENT}} body", named: "a-first.txt", in: dir)
        try write("not a variant", named: "ignore.md", in: dir)

        let variants = try IterateCore.loadVariants(from: dir)

        XCTAssertEqual(variants.map { $0.id }, ["a-first", "b-second"])
        XCTAssertEqual(variants[0].template, "alpha {{DOCUMENT}} body")
        XCTAssertEqual(variants[1].template, "beta {{DOCUMENT}} body")
    }

    func testLoadVariantsRejectsTemplateMissingDocumentPlaceholder() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("this template has no placeholder", named: "bad.txt", in: dir)

        XCTAssertThrowsError(try IterateCore.loadVariants(from: dir)) { error in
            XCTAssertEqual(error as? IterateCore.LoadError,
                           .placeholderCount(variantId: "bad", found: 0))
        }
    }

    func testLoadVariantsRejectsDuplicatePlaceholder() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("first {{DOCUMENT}} then second {{DOCUMENT}}", named: "dup.txt", in: dir)

        XCTAssertThrowsError(try IterateCore.loadVariants(from: dir)) { error in
            // Pins the >1 branch: exactly-one validation must reject two placeholders too.
            XCTAssertEqual(error as? IterateCore.LoadError,
                           .placeholderCount(variantId: "dup", found: 2))
        }
    }

    // MARK: - renderPrompt

    func testRenderPromptSubstitutesPageNumberedDocumentBlock() {
        let template = "PROMPT HEADER\nBEGIN\n{{DOCUMENT}}\nEND"
        let pages = ["first page text", "second page text"]

        let rendered = IterateCore.renderPrompt(template: template, pages: pages)

        XCTAssertTrue(rendered.contains("----- PAGE 1 -----\nfirst page text"))
        XCTAssertTrue(rendered.contains("----- PAGE 2 -----\nsecond page text"))
        XCTAssertFalse(rendered.contains("{{DOCUMENT}}"))
    }

    /// Fairness golden test (premortem target #5): the baseline variant is rendered by
    /// `ExtractionPrompt.make` directly while all other variants go through `renderPrompt`. The
    /// baseline-vs-variant comparison is only fair if the injected document block is byte-identical
    /// between the two paths. `make()` lives in HealthBridgeParsing and may not be refactored into a
    /// shared helper (no production-source change), so `renderPrompt` necessarily duplicates the block
    /// format — this pins that duplication against drift. If `make()`'s page-block format ever changes,
    /// this test trips and `renderPrompt` must be re-synced.
    func testRenderPromptDocumentBlockMatchesExtractionPromptMake() throws {
        let pages = ["alpha page one", "beta page two", "gamma page three"]

        // The block `make()` embeds, extracted between its BEGIN/END markers.
        let made = ExtractionPrompt.make(pages: pages)
        let beginMarker = "BEGIN DOCUMENT\n"
        let endMarker = "\nEND DOCUMENT"
        let beginRange = try XCTUnwrap(made.range(of: beginMarker))
        let endRange = try XCTUnwrap(made.range(of: endMarker, range: beginRange.upperBound..<made.endIndex))
        let madeBlock = String(made[beginRange.upperBound..<endRange.lowerBound])

        // The block `renderPrompt` substitutes for {{DOCUMENT}} (template is the bare placeholder).
        let renderedBlock = IterateCore.renderPrompt(template: "{{DOCUMENT}}", pages: pages)

        XCTAssertEqual(renderedBlock, madeBlock)
    }

    // MARK: - overallStrictF1

    /// Minimal `CaseScore` carrying only the `strict.f1` value `overallStrictF1` pools; other fields are
    /// neutral placeholders (the reduction ignores them).
    private func caseScore(strictF1: Double, fixture: String = "fx", model: String = "m",
                           sample: Int = 0) -> CaseScore {
        let zero = F1(precision: 0, recall: 0, f1: strictF1)
        return CaseScore(fixture: fixture, model: model, sample: sample, catastrophic: false,
                         strict: F1(precision: 0, recall: 0, f1: strictF1), lenient: zero,
                         skipHistogram: [:], matches: [], patient: PatientCorrectness(
                            distinctCountCorrect: true, identityCorrect: true))
    }

    func testOverallStrictF1PoolsAllSampleF1s() {
        // Pool across fixtures/models/samples: f1s = [0.2,0.4,0.6,0.8] → mean 0.5,
        // population variance = (0.09+0.01+0.01+0.09)/4 = 0.05 → stdev sqrt(0.05).
        let scores = [
            caseScore(strictF1: 0.2, fixture: "a", sample: 0),
            caseScore(strictF1: 0.4, fixture: "a", sample: 1),
            caseScore(strictF1: 0.6, fixture: "b", model: "m2", sample: 0),
            caseScore(strictF1: 0.8, fixture: "b", model: "m2", sample: 1),
        ]

        let agg = IterateCore.overallStrictF1(scores: scores)

        XCTAssertEqual(agg.mean, 0.5, accuracy: 1e-12)
        XCTAssertEqual(agg.stdev, 0.05.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(agg.n, 4)
    }

    func testOverallStrictF1SingleSampleHasZeroStdev() {
        let agg = IterateCore.overallStrictF1(scores: [caseScore(strictF1: 0.7)])

        XCTAssertEqual(agg.mean, 0.7, accuracy: 1e-12)
        XCTAssertEqual(agg.stdev, 0.0, accuracy: 1e-12)
        XCTAssertEqual(agg.n, 1)
    }

    func testOverallStrictF1OnEmptyScoresReturnsZeroNotNaN() {
        let agg = IterateCore.overallStrictF1(scores: [])

        XCTAssertEqual(agg, AggregateF1(mean: 0, stdev: 0, n: 0))
        XCTAssertFalse(agg.mean.isNaN)
        XCTAssertFalse(agg.stdev.isNaN)
    }
}
