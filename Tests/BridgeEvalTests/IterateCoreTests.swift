import XCTest
@testable import bridge_eval
import HealthBridgeParsing

/// Minimal extractor stub returning a fixed reply; the hash-consistency test only inspects the
/// RawArtifact's promptHash, which is derived from the prompt regardless of the reply.
private struct StubExtractor: LLMExtractor {
    func extract(_ request: LLMRequest) async throws -> LLMRawResponse {
        LLMRawResponse(jsonText: "{}")
    }
}

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

    // MARK: - selectWinner (n>=2 margin rule)

    func testSelectWinnerPromotesWhenGainExceedsNoiseMargin() {
        // Δmean 0.2 clears both the absolute floor (0.01) and the noise margin (SE_diff ≈ 0.047).
        let champion = AggregateF1(mean: 0.5, stdev: 0.1, n: 10)
        let challenger = AggregateF1(mean: 0.7, stdev: 0.1, n: 10)

        let decision = IterateCore.selectWinner(champion: champion, challenger: challenger)

        XCTAssertTrue(decision.promoted)
        XCTAssertEqual(decision.deltaMean, 0.2, accuracy: 1e-12)
        XCTAssertNil(decision.blockingFixture)
    }

    func testSelectWinnerRetainsChampionWithinNoise() {
        // Δmean 0.02 clears the absolute floor but is below noiseThreshold·SE_diff (≈ 0.1414).
        let champion = AggregateF1(mean: 0.50, stdev: 0.2, n: 5)
        let challenger = AggregateF1(mean: 0.52, stdev: 0.2, n: 5)

        let decision = IterateCore.selectWinner(champion: champion, challenger: challenger)

        XCTAssertFalse(decision.promoted)
    }

    func testSelectWinnerTieKeepsChampion() {
        // Equal means → Δmean 0 fails the absolute floor → incumbency bias retains the champion.
        let champion = AggregateF1(mean: 0.6, stdev: 0.1, n: 5)
        let challenger = AggregateF1(mean: 0.6, stdev: 0.1, n: 5)

        let decision = IterateCore.selectWinner(champion: champion, challenger: challenger)

        XCTAssertFalse(decision.promoted)
        XCTAssertEqual(decision.deltaMean, 0.0, accuracy: 1e-12)
    }

    func testSelectWinnerUsesSampleVarianceAtN2() {
        // n=2, σ=0.025. Population SE_diff = σ = 0.025 → a +0.03 gain WOULD promote with raw population
        // stdev. Sample-variance SE_diff = σ√2 ≈ 0.035355 → +0.03 must NOT promote. Proves Bessel applied.
        let champion = AggregateF1(mean: 0.50, stdev: 0.025, n: 2)
        let challenger = AggregateF1(mean: 0.53, stdev: 0.025, n: 2)

        let decision = IterateCore.selectWinner(champion: champion, challenger: challenger)

        XCTAssertFalse(decision.promoted)
        // SE_diff = sqrt(σ²/(n-1) + σ²/(n-1)) = sqrt(0.025²·2) = 0.0353553...
        XCTAssertEqual(decision.seDiff, (0.025 * 0.025 * 2).squareRoot(), accuracy: 1e-12)
    }

    func testSelectWinnerLowNRequiresLargerAbsoluteFloor() {
        // n=1 → population stdev 0 → SE_diff collapses to 0; the n>=2 margin would promote on any
        // positive jitter. The low-n branch instead requires the larger minImprovementLowN floor (0.05).
        let champion = AggregateF1(mean: 0.50, stdev: 0.0, n: 1)

        // +0.02 clears the 0.01 absolute floor but NOT the 0.05 low-n floor → retain.
        let small = IterateCore.selectWinner(champion: champion,
                                             challenger: AggregateF1(mean: 0.52, stdev: 0.0, n: 1))
        XCTAssertFalse(small.promoted)

        // +0.06 clears the 0.05 low-n floor → promote.
        let large = IterateCore.selectWinner(champion: champion,
                                             challenger: AggregateF1(mean: 0.56, stdev: 0.0, n: 1))
        XCTAssertTrue(large.promoted)
    }

    func testSelectWinnerLowNAsymmetric() {
        // OR-branch: one side n>=2, the other n=1 → still the low-n floor (0.05), not the SE_diff margin.
        let champion = AggregateF1(mean: 0.50, stdev: 0.1, n: 5)

        // +0.02 < 0.05 low-n floor → retain (challenger n=1).
        let small = IterateCore.selectWinner(champion: champion,
                                             challenger: AggregateF1(mean: 0.52, stdev: 0.0, n: 1))
        XCTAssertFalse(small.promoted)

        // +0.06 >= 0.05 low-n floor → promote (challenger n=1).
        let large = IterateCore.selectWinner(champion: champion,
                                             challenger: AggregateF1(mean: 0.56, stdev: 0.0, n: 1))
        XCTAssertTrue(large.promoted)
    }

    // MARK: - selectWinner per-fixture regression guard (condition 3)

    private func fixtureStats(fixture: String, strictMean: Double, model: String = "m") -> FixtureModelStats {
        FixtureModelStats(fixture: fixture, model: model,
                          strictF1: AggregateF1(mean: strictMean, stdev: 0, n: 5),
                          lenientF1: AggregateF1(mean: strictMean, stdev: 0, n: 5),
                          outputConsistency: 1.0, catastrophicRate: 0.0)
    }

    func testSelectWinnerBlocksPromotionOnPerFixtureRegression() {
        // Pooled mean rises (0.5→0.7, clears conditions 1+2) but fixture "alpha" craters 0.9→0.4
        // (−0.5, far beyond the 0.05 margin) → overfitting → block, naming "alpha".
        let champion = AggregateF1(mean: 0.5, stdev: 0.05, n: 10)
        let challenger = AggregateF1(mean: 0.7, stdev: 0.05, n: 10)
        let championFixtures = [fixtureStats(fixture: "alpha", strictMean: 0.9),
                                fixtureStats(fixture: "beta", strictMean: 0.1)]
        let challengerFixtures = [fixtureStats(fixture: "alpha", strictMean: 0.4),
                                  fixtureStats(fixture: "beta", strictMean: 0.9)]

        let decision = IterateCore.selectWinner(
            champion: champion, challenger: challenger,
            championFixtures: championFixtures, challengerFixtures: challengerFixtures)

        XCTAssertFalse(decision.promoted)
        XCTAssertEqual(decision.blockingFixture, "alpha")
    }

    func testSelectWinnerPromotesWhenAllFixturesWithinMargin() {
        // Pooled mean rises and no fixture drops more than 0.05 below the champion → promote.
        let champion = AggregateF1(mean: 0.5, stdev: 0.05, n: 10)
        let challenger = AggregateF1(mean: 0.7, stdev: 0.05, n: 10)
        let championFixtures = [fixtureStats(fixture: "alpha", strictMean: 0.6),
                                fixtureStats(fixture: "beta", strictMean: 0.4)]
        let challengerFixtures = [fixtureStats(fixture: "alpha", strictMean: 0.58),  // −0.02, within margin
                                  fixtureStats(fixture: "beta", strictMean: 0.9)]

        let decision = IterateCore.selectWinner(
            champion: champion, challenger: challenger,
            championFixtures: championFixtures, challengerFixtures: challengerFixtures)

        XCTAssertTrue(decision.promoted)
        XCTAssertNil(decision.blockingFixture)
    }

    // MARK: - promptHash consistency (render-once / hash-the-sent-string — the gotcha, §4.6)

    func testIterateManifestHashMatchesObservedArtifactHashForOverride() async throws {
        let pages = ["Heart rate 72.5 /min on 2024-01-15"]
        let template = "EXTRACT CAREFULLY:\n{{DOCUMENT}}\nEND"

        // Render the override ONCE, hash THAT string for the manifest, then pass THAT SAME string as
        // promptOverride. Because it is the identical String value, runCase's internal promptHash is
        // byte-identical by construction → no default make() hash leaks into the manifest.
        let rendered = IterateCore.renderPrompt(template: template, pages: pages)
        let manifestPromptHashes = [Hashing.promptHash(rendered)]

        let now = LLMResponseContract.parseDate("2026-06-24")!
        let (raw, _) = try await RunCore.runCase(
            pdfData: Data("%PDF".utf8), pages: pages, model: "m", fixture: "f", sample: 0,
            extractor: StubExtractor(), expected: ExpectedDoc(patients: [], observations: []),
            subjectId: "subj", now: now, promptOverride: rendered)

        // The manifest's hashes contain exactly the observed artifact hash, and NOT the default-prompt hash.
        XCTAssertEqual(manifestPromptHashes, [raw.promptHash])
        XCTAssertNotEqual(raw.promptHash, Hashing.promptHash(ExtractionPrompt.make(pages: pages)))
    }

    // MARK: - journal + resume helpers

    private func config(samples: Int = 1) -> IterateConfig {
        IterateConfig(models: ["m"], samples: samples, fixturesRoot: "eval/fixtures",
                      noiseThreshold: 1.0, minImprovement: 0.01, minImprovementLowN: 0.05,
                      maxFixtureRegression: 0.05)
    }

    private func successEntry(_ id: String, promoted: Bool) -> JournalEntry {
        JournalEntry(variantId: id, promptHash: "hash-\(id)", strictF1Mean: 0.7, strictF1Stdev: 0.05,
                     sampleCount: 5, runDir: "runs/\(id)", evaluatedAt: "2026-06-29T00:00:00Z",
                     decision: DecisionRecord(promoted: promoted, deltaMean: 0.1, seDiff: 0.02,
                                              blockingFixture: nil, reason: "ok"),
                     failure: nil)
    }

    private func failureEntry(_ id: String) -> JournalEntry {
        JournalEntry(variantId: id, promptHash: nil, strictF1Mean: nil, strictF1Stdev: nil,
                     sampleCount: 0, runDir: nil, evaluatedAt: "2026-06-29T00:01:00Z",
                     decision: nil, failure: "transport error")
    }

    func testAppendJournalCreatesThenAppendsInOrder() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("journal.json")

        try IterateCore.appendJournal(entry: successEntry("a", promoted: true), journalURL: url)
        let after1 = try JSONDecoder().decode(IterateJournal.self, from: Data(contentsOf: url))
        XCTAssertEqual(after1.entries.map { $0.variantId }, ["a"])

        try IterateCore.appendJournal(entry: failureEntry("b"), journalURL: url)
        let after2 = try JSONDecoder().decode(IterateJournal.self, from: Data(contentsOf: url))
        XCTAssertEqual(after2.entries.map { $0.variantId }, ["a", "b"])
    }

    func testAppendJournalRecordsFailureEntry() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("journal.json")
        let failure = failureEntry("x")

        try IterateCore.appendJournal(entry: failure, journalURL: url)
        let decoded = try JSONDecoder().decode(IterateJournal.self, from: Data(contentsOf: url))

        XCTAssertEqual(decoded.entries, [failure])
        XCTAssertNil(decoded.entries[0].decision)
        XCTAssertNil(decoded.entries[0].promptHash)
        XCTAssertEqual(decoded.entries[0].sampleCount, 0)
        XCTAssertEqual(decoded.entries[0].failure, "transport error")
    }

    func testResumeRetriesFailedButSkipsSucceeded() {
        // A succeeded, B only failed, C never seen → pending = [B, C] (A skipped, B retried, C new).
        let journal = IterateJournal(session: "s", config: config(),
                                     entries: [successEntry("a", promoted: true), failureEntry("b")])

        XCTAssertEqual(IterateCore.pendingVariants(all: ["a", "b", "c"], journal: journal), ["b", "c"])
        XCTAssertEqual(IterateCore.resumeChampion(journal: journal)?.variantId, "a")
    }

    func testResumeRefusesOnConfigDrift() {
        let journal = IterateJournal(session: "s", config: config(samples: 1), entries: [])

        XCTAssertThrowsError(try IterateCore.assertResumable(config: config(samples: 3), journal: journal))
        XCTAssertNoThrow(try IterateCore.assertResumable(config: config(samples: 1), journal: journal))
    }

    func testResumeChampionReloadsPerFixtureStatsFromResultsJson() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        // Write a results.json with known per-fixture stats into the champion's run dir.
        let runDirRel = "runs/winner-2026"
        let stats = [
            FixtureModelStats(fixture: "alpha", model: "m",
                              strictF1: AggregateF1(mean: 0.8, stdev: 0.0, n: 5),
                              lenientF1: AggregateF1(mean: 0.8, stdev: 0.0, n: 5),
                              outputConsistency: 1.0, catastrophicRate: 0.0),
            FixtureModelStats(fixture: "beta", model: "m",
                              strictF1: AggregateF1(mean: 0.6, stdev: 0.0, n: 5),
                              lenientF1: AggregateF1(mean: 0.6, stdev: 0.0, n: 5),
                              outputConsistency: 1.0, catastrophicRate: 0.0),
        ]
        let results = RunResults(promptHashes: ["h"], stats: stats)
        let runDir = base.appendingPathComponent(runDirRel)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(results).write(to: runDir.appendingPathComponent("results.json"))

        // A journal whose promoted champion entry points at that run dir.
        var champ = successEntry("winner", promoted: true)
        champ = JournalEntry(variantId: champ.variantId, promptHash: champ.promptHash,
                             strictF1Mean: champ.strictF1Mean, strictF1Stdev: champ.strictF1Stdev,
                             sampleCount: champ.sampleCount, runDir: runDirRel,
                             evaluatedAt: champ.evaluatedAt, decision: champ.decision, failure: nil)
        let journal = IterateJournal(session: "s", config: config(), entries: [champ])

        let reloaded = IterateCore.resumeChampionFixtures(journal: journal, baseDir: base)

        XCTAssertEqual(reloaded, stats)   // real per-fixture stats, not []
    }

    func testResumeChampionFixturesReturnsEmptyWhenResultsMissing() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let champ = JournalEntry(variantId: "winner", promptHash: "h", strictF1Mean: 0.7, strictF1Stdev: 0.0,
                                 sampleCount: 5, runDir: "runs/does-not-exist",
                                 evaluatedAt: "2026-06-29T00:00:00Z",
                                 decision: DecisionRecord(promoted: true, deltaMean: 0, seDiff: 0,
                                                          blockingFixture: nil, reason: "seed"),
                                 failure: nil)
        let journal = IterateJournal(session: "s", config: config(), entries: [champ])

        XCTAssertEqual(IterateCore.resumeChampionFixtures(journal: journal, baseDir: base), [])
    }
}
