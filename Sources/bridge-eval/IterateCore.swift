import Foundation

/// Pure, offline helpers for the `iterate` loop (plan §5). No network, no PDFKit, no keys — every
/// function here is unit-tested under Patterns B/C. The macOS-guarded `IterateCommand.run()` shell
/// composes these.
enum IterateCore {
    /// The single placeholder a variant template must contain (exactly once) — replaced with the
    /// page-numbered document block at render time (plan §4.1).
    static let documentPlaceholder = "{{DOCUMENT}}"

    enum LoadError: Error, Equatable {
        /// Template did not contain exactly one `{{DOCUMENT}}` placeholder (count attached).
        case placeholderCount(variantId: String, found: Int)
    }

    /// Load every `*.txt` file in `dirURL` as a `PromptVariant`, in lexical filename order (plan §4.1).
    /// `id` = filename stem; `template` = file contents. Each template MUST contain exactly one
    /// `{{DOCUMENT}}` placeholder — zero or more than one throws `LoadError.placeholderCount` (a
    /// missing placeholder would send the model no document; a duplicated one is operator error).
    /// Non-`.txt` entries are ignored.
    static func loadVariants(from dirURL: URL) throws -> [PromptVariant] {
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: dirURL, includingPropertiesForKeys: nil)
        let txtURLs = fileURLs
            .filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return try txtURLs.map { url in
            let id = url.deletingPathExtension().lastPathComponent
            let template = try String(contentsOf: url, encoding: .utf8)
            let count = placeholderCount(in: template)
            guard count == 1 else {
                throw LoadError.placeholderCount(variantId: id, found: count)
            }
            return PromptVariant(id: id, template: template)
        }
    }

    /// Count occurrences of the document placeholder in a template (non-overlapping).
    private static func placeholderCount(in template: String) -> Int {
        template.components(separatedBy: documentPlaceholder).count - 1
    }

    /// Render a per-fixture prompt by substituting the page-numbered document block for the single
    /// `{{DOCUMENT}}` placeholder (plan §4.1, §4.5). The block format MUST stay byte-identical to
    /// `ExtractionPrompt.make` so a `renderPrompt`-rendered variant and the `make()`-rendered baseline
    /// inject the same document. DRIFT TRIPWIRE: if `make()`'s page-block format ever changes, the test
    /// `IterateCoreTests.testRenderPromptDocumentBlockMatchesExtractionPromptMake` fails — re-sync the
    /// line below to match `make()` exactly (no shared helper: `make()` is off-limits production source).
    static func renderPrompt(template: String, pages: [String]) -> String {
        let document = pages.enumerated()
            .map { "----- PAGE \($0.offset + 1) -----\n\($0.element)" }
            .joined(separator: "\n")
        return template.replacingOccurrences(of: documentPlaceholder, with: document)
    }

    /// Pool every `score.strict.f1` (across fixtures × models × samples) into one `AggregateF1` — the
    /// variant-level fitness `selectWinner` compares (plan §4.2). Population stdev (variance = Σ(x-μ)²/n,
    /// so n=1 → stdev 0), mirroring `Aggregator.aggregateF1`'s convention exactly. Empty scores (a variant
    /// whose every case errored/was skipped) return `{0,0,0}` — a worst-possible, non-promotable result,
    /// never `NaN` (plan §6 Task 4 / Risk 6).
    static func overallStrictF1(scores: [CaseScore]) -> AggregateF1 {
        let values = scores.map { $0.strict.f1 }
        guard !values.isEmpty else { return AggregateF1(mean: 0, stdev: 0, n: 0) }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return AggregateF1(mean: mean, stdev: variance.squareRoot(), n: values.count)
    }

    /// Noise-aware champion-vs-challenger decision (plan §4.2). Promote the challenger iff it clears an
    /// absolute floor AND a noise margin (n≥2 branch here; the n<2 low-n guard and the per-fixture
    /// regression guard arrive in Tasks 5b/5c via the defaulted trailing params). Ties and within-noise
    /// gains retain the incumbent (intentional incumbency bias — do not churn the prompt on noise).
    ///
    /// `AggregateF1.stdev` is a POPULATION stdev (✓ Aggregator: variance = Σ(x-μ)²/n). Population stdev
    /// underestimates uncertainty at small n, so it is converted to the unbiased sample variance
    /// `sampleVar = sd_pop²·n/(n-1)` BEFORE forming the standard error of the difference (§4.2 Codex note):
    ///   SE_diff = sqrt( sampleVar_c/n_c + sampleVar_x/n_x )  =  sqrt( sd_c²/(n_c-1) + sd_x²/(n_x-1) ).
    static func selectWinner(champion: AggregateF1, challenger: AggregateF1,
                             championFixtures: [FixtureModelStats] = [],
                             challengerFixtures: [FixtureModelStats] = [],
                             minImprovement: Double = 0.01,
                             noiseThreshold: Double = 1.0,
                             minImprovementLowN: Double = 0.05,
                             maxFixtureRegression: Double = 0.05) -> WinnerDecision {
        let deltaMean = challenger.mean - champion.mean

        // Condition 1 — absolute floor (applies to every branch).
        guard deltaMean >= minImprovement else {
            return WinnerDecision(promoted: false, deltaMean: deltaMean, seDiff: 0, blockingFixture: nil,
                                  reason: "retain: Δmean \(deltaMean) below absolute floor \(minImprovement)")
        }

        // Condition 2 — noise margin. Low-n trap (n<2): population stdev of a single sample is 0, so
        // SE_diff collapses to 0 and the n≥2 margin would promote on any positive jitter. Sample variance
        // is undefined at n=1, so the noise margin is replaced by the larger minImprovementLowN floor
        // (plan §4.2 condition 2 else-branch).
        let seDiff: Double
        if champion.n >= 2, challenger.n >= 2 {
            seDiff = standardErrorOfDifference(champion: champion, challenger: challenger)
            guard deltaMean >= noiseThreshold * seDiff else {
                return WinnerDecision(promoted: false, deltaMean: deltaMean, seDiff: seDiff, blockingFixture: nil,
                                      reason: "retain: Δmean \(deltaMean) within noise margin \(noiseThreshold * seDiff)")
            }
        } else {
            seDiff = 0
            guard deltaMean >= minImprovementLowN else {
                return WinnerDecision(promoted: false, deltaMean: deltaMean, seDiff: 0, blockingFixture: nil,
                                      reason: "retain: Δmean \(deltaMean) below low-n floor \(minImprovementLowN)")
            }
        }

        // Condition 3 — per-fixture regression guard (anti-overfitting). The pooled mean can rise while a
        // single fixture craters; pooled SE_diff reflects fixture-difficulty variance, not sampling noise,
        // so conditions 1+2 alone cannot catch this. Block promotion if ANY fixture(×model) the challenger
        // evaluated drops more than maxFixtureRegression below the champion's for that fixture (§4.2 cond 3).
        if let blocking = firstRegressingFixture(champion: championFixtures, challenger: challengerFixtures,
                                                 maxFixtureRegression: maxFixtureRegression) {
            return WinnerDecision(promoted: false, deltaMean: deltaMean, seDiff: seDiff, blockingFixture: blocking,
                                  reason: "retain: fixture \(blocking) regressed beyond \(maxFixtureRegression)")
        }

        return WinnerDecision(promoted: true, deltaMean: deltaMean, seDiff: seDiff, blockingFixture: nil,
                              reason: "promote: Δmean \(deltaMean) cleared all floors and per-fixture margin")
    }

    enum ResumeError: Error, Equatable {
        /// Incoming options differ from the journal's persisted config — the batches are non-comparable.
        case configDrift
    }

    /// Append one entry to the journal at `journalURL`, durably (plan §4.7 step 2 — written immediately
    /// after each variant, never end-buffered). Reads the existing `IterateJournal` and appends, or, if
    /// the file is absent, seeds a placeholder header. NOTE: `run()` (Task 9) writes the REAL session/config
    /// header before the loop, so the placeholder is only reached by the unit path; the append always
    /// uses the same sorted-keys pretty encoder + atomic write as `ArtifactWriter` for diff-friendliness.
    static func appendJournal(entry: JournalEntry, journalURL: URL) throws {
        var journal = readJournal(at: journalURL)
            ?? IterateJournal(session: "", config: placeholderConfig, entries: [])
        journal.entries.append(entry)
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try journalEncoder().encode(journal).write(to: journalURL, options: .atomic)
    }

    /// Variant ids still needing evaluation: all ids minus those with ≥1 SUCCESS entry (failure == nil).
    /// Failure-only ids are RETRIED and never-seen ids are included (plan §4.7 step 3 — transient failures
    /// must not be terminal). Order follows `all`.
    static func pendingVariants(all: [String], journal: IterateJournal) -> [String] {
        let succeeded = Set(journal.entries.filter { $0.failure == nil }.map { $0.variantId })
        return all.filter { !succeeded.contains($0) }
    }

    /// The running champion on resume: the most-recent entry whose decision promoted it (nil if none).
    static func resumeChampion(journal: IterateJournal) -> JournalEntry? {
        journal.entries.last { $0.decision?.promoted == true }
    }

    /// Refuse a resume whose incoming config differs from the journal's persisted config — mixing
    /// incomparable fitness conditions would corrupt the decision trace (plan §4.7 step 4).
    static func assertResumable(config: IterateConfig, journal: IterateJournal) throws {
        guard journal.config == config else { throw ResumeError.configDrift }
    }

    private static let placeholderConfig = IterateConfig(
        models: [], samples: 0, fixturesRoot: "", noiseThreshold: 0,
        minImprovement: 0, minImprovementLowN: 0, maxFixtureRegression: 0)

    private static func readJournal(at url: URL) -> IterateJournal? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(IterateJournal.self, from: data)
    }

    private static func journalEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]   // matches ArtifactWriter for diff-friendliness
        return e
    }

    /// First fixture(×model) — in deterministic key order — whose challenger `strictF1.mean` drops more
    /// than `maxFixtureRegression` below the champion's for the SAME fixture. Fixtures the challenger
    /// evaluated but the champion did not have no regression baseline and are skipped. Returns nil if no
    /// fixture regresses beyond the margin.
    private static func firstRegressingFixture(champion: [FixtureModelStats], challenger: [FixtureModelStats],
                                               maxFixtureRegression: Double) -> String? {
        let championByKey = Dictionary(champion.map { ("\($0.fixture)\u{0}\($0.model)", $0) },
                                       uniquingKeysWith: { first, _ in first })
        return challenger
            .sorted { ($0.fixture, $0.model) < ($1.fixture, $1.model) }
            .first { x in
                guard let c = championByKey["\(x.fixture)\u{0}\(x.model)"] else { return false }
                return x.strictF1.mean < c.strictF1.mean - maxFixtureRegression
            }?
            .fixture
    }

    /// SE of the difference of two pooled means, converting each population stdev to the unbiased sample
    /// variance first (`sd_pop²·n/(n-1)`). Requires n≥2 on both sides (caller guards).
    private static func standardErrorOfDifference(champion c: AggregateF1, challenger x: AggregateF1) -> Double {
        let sampleVarC = c.stdev * c.stdev * Double(c.n) / Double(c.n - 1)
        let sampleVarX = x.stdev * x.stdev * Double(x.n) / Double(x.n - 1)
        return (sampleVarC / Double(c.n) + sampleVarX / Double(x.n)).squareRoot()
    }
}
