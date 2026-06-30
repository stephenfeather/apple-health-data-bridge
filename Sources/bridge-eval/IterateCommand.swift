import Foundation
import ArgumentParser
import HealthBridgeParsing

/// `iterate` subcommand: operator-driven, budget-bounded prompt search over a curated set of candidate
/// `.txt` variants against the gold-fixture fitness function, keeping the best by a noise-aware decision
/// rule and recording every evaluation in an append-only journal (plan §1). Like `run`, the live body
/// touches network/PDFKit and is macOS-guarded; off macOS it refuses rather than pretending to work.
struct IterateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iterate",
        abstract: "Evaluate candidate prompt variants against gold fixtures; keep the best.")

    @Option(name: .long, help: "Variants dir of *.txt prompt templates (default: eval/prompts).")
    var variants: String = "eval/prompts"
    @Option(name: .long, help: "Fixtures root (default: eval/fixtures).")
    var fixtures: String = "eval/fixtures"
    @Option(name: .long, help: "Iterate session root; re-invoking the same root resumes (default: eval/iterate).")
    var iterateRoot: String = "eval/iterate"
    @Option(name: .long, parsing: .upToNextOption,
            help: "Model id to evaluate — exactly one (the decision rule is per-model).")
    var models: [String] = ["claude-opus-4-8"]
    @Option(name: .long, help: "Provider (anthropic|openai).") var provider: String = "anthropic"
    @Option(name: .long, help: "API key (else the provider env var). Never persisted/logged.") var apiKey: String?
    @Option(name: .long, help: "Samples per (fixture, model).") var samples: Int = 1
    @Option(name: .long, help: "Subject id used for the contract's single-subject decode.")
    var subjectId: String = "eval-subject"
    @Option(name: .customLong("subject-dob"),
            help: "Subject DOB (yyyy-MM-dd UTC) for the before-DOB plausible-date guard. Omit to skip.")
    var subjectDOB: String?
    @Option(name: .long, help: "Noise margin in units of SE_diff (default 1.0).")
    var noiseThreshold: Double = 1.0
    @Option(name: .long, help: "Absolute mean-F1 floor to promote (default 0.01).")
    var minImprovement: Double = 0.01
    @Option(name: .long, help: "Larger absolute floor when n<2, where SE_diff is unestimable (default 0.05).")
    var minImprovementLowN: Double = 0.05
    @Option(name: .long, help: "Max per-fixture F1 regression tolerated before blocking a promotion (default 0.05).")
    var maxFixtureRegression: Double = 0.05
    @Option(name: .long, help: "Cap on variants evaluated (default: all).") var maxVariants: Int?
    @Option(name: .long, help: "Hard cap on total live API calls (default: unbounded).") var budgetCalls: Int?
    @Flag(name: .long, inversion: .prefixedNo,
          help: "Seed the champion with the current production prompt (default: true).")
    var includeBaseline = true

    // Cross-option checks (house style: validate() for what @Option can't express). Pure, no I/O —
    // dir existence is deferred to run-time like `run`. Single-model is HARD-enforced: pooling F1 across
    // models conflates prompt quality with model choice, so the decision rule is only meaningful per-model
    // (§4.2; resolved open Q 8.5).
    func validate() throws {
        guard samples > 0 else { throw ValidationError("--samples must be > 0") }
        if let budget = budgetCalls, budget <= 0 {
            throw ValidationError("--budget-calls must be > 0 when set")
        }
        guard noiseThreshold >= 0 else { throw ValidationError("--noise-threshold must be >= 0") }
        guard models.count == 1 else {
            throw ValidationError("--models must specify exactly one model (the decision rule is per-model)")
        }
        if let cap = maxVariants, cap <= 0 {
            throw ValidationError("--max-variants must be > 0 when set")
        }
        // Allow-list mirrors makeExtractor's switch (case-insensitive) so an unknown provider fails at
        // parse time, not after fixtures are read.
        guard ["anthropic", "openai"].contains(provider.lowercased()) else {
            throw ValidationError("--provider must be one of anthropic|openai (got \"\(provider)\")")
        }
        if let raw = subjectDOB, LLMResponseContract.parseDate(raw) == nil {
            throw ValidationError("--subject-dob must be a valid UTC date in yyyy-MM-dd form (got \"\(raw)\")")
        }
    }

    func run() async throws {
        #if canImport(PDFKit) && os(macOS)
        // PHI git-safety: refuse a tracked iterate root or fixtures root (design §9). NOT the variants dir
        // (prompt templates carry operator instructions only, no patient data — plan open Q 8.4).
        try Preflight.assertUntracked(iterateRoot, role: "iterate")
        try Preflight.assertUntracked(fixtures, role: "fixtures")

        let extractor = try makeExtractor()
        let parsedSubjectDOB = subjectDOB.flatMap { LLMResponseContract.parseDate($0) }
        let model = models[0]   // validate() guarantees exactly one
        let cases = try Fixtures.discoverCases(root: fixtures)

        // Read each fixture's pages AND expected gold once (mirrors run()'s pre-pass; the only PDFText call
        // stays here). loadExpected is hoisted into this fixture-level pre-pass so a malformed (Tier-B,
        // PHI) expected.json throws loudly BEFORE the batch — it can never land in a per-variant failure
        // string (Note 3 PHI hardening).
        var pagesByCase: [String: [String]] = [:]
        var pdfDataByCase: [String: Data] = [:]
        var expectedByCase: [String: ExpectedDoc] = [:]
        for caseName in cases {
            switch try Fixtures.resolveCaseInput(root: fixtures, caseName: caseName) {
            case .pdf(let pdfURL):
                let data = try Data(contentsOf: pdfURL)
                pagesByCase[caseName] = try PDFText.pages(data)
                pdfDataByCase[caseName] = data
            case .pages(let pages, let raw):
                pagesByCase[caseName] = pages
                pdfDataByCase[caseName] = raw
            }
            expectedByCase[caseName] = try Fixtures.loadExpected(root: fixtures, caseName: caseName)
        }

        let config = IterateConfig(models: models, samples: samples, fixturesRoot: fixtures,
                                   noiseThreshold: noiseThreshold, minImprovement: minImprovement,
                                   minImprovementLowN: minImprovementLowN,
                                   maxFixtureRegression: maxFixtureRegression, subjectDOB: subjectDOB)

        let sessionDir = URL(fileURLWithPath: iterateRoot)
        let journalURL = sessionDir.appendingPathComponent("journal.json")

        // Resume vs. fresh session. On resume: refuse config drift, then drop already-succeeded variants
        // and seed the champion. On a fresh session: write the REAL journal header (session + true config)
        // BEFORE any append, so appendJournal never seeds its zeroed placeholder (Task 7 flag). A
        // present-but-corrupt journal THROWS here (readJournal) rather than being blanked (PR #16 finding 1).
        let resumeJournal = try IterateCore.readJournal(at: journalURL)
        if let existing = resumeJournal {
            try IterateCore.assertResumable(config: config, journal: existing)
        }
        let session = resumeJournal?.session ?? ISO8601DateFormatter().string(from: Date())
        if resumeJournal == nil {
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            try writeJSON(IterateJournal(session: session, config: config, entries: []), to: journalURL)
        }

        // Candidates: baseline first (override nil → make()), then variants in lexical order. Refuse a
        // human variant that collides with the reserved synthetic id "baseline" (PR #16 finding 4).
        let loaded = try IterateCore.loadVariants(from: URL(fileURLWithPath: variants))
        try IterateCore.assertNoBaselineCollision(variantIds: loaded.map { $0.id },
                                                  includeBaseline: includeBaseline)
        var candidates: [Candidate] = []
        if includeBaseline { candidates.append(Candidate(id: "baseline", template: nil)) }
        candidates.append(contentsOf: loaded.map { Candidate(id: $0.id, template: $0.template) })

        // Resume filter (skip succeeded, retry failure-only/new) + max-variants cap.
        if let existing = resumeJournal {
            let pending = Set(IterateCore.pendingVariants(all: candidates.map { $0.id }, journal: existing))
            candidates = candidates.filter { pending.contains($0.id) }
        }
        if let cap = maxVariants { candidates = Array(candidates.prefix(cap)) }

        // Seed the champion from the resumed journal. Reload its per-fixture stats from results.json so the
        // per-fixture regression guard (cond-3) is active from the FIRST comparison against the incumbent
        // (Note 2 / premortem #8). If the results.json is gone, fall back to [] with a warning.
        var champion: ChampionState? = nil
        if let existing = resumeJournal, let entry = IterateCore.resumeChampion(journal: existing),
           let mean = entry.strictF1Mean, let sd = entry.strictF1Stdev {
            let fixtures = IterateCore.resumeChampionFixtures(journal: existing, baseDir: sessionDir)
            if fixtures.isEmpty, entry.runDir != nil {
                let warn = "warning: could not reload per-fixture stats for resumed champion "
                    + "\(entry.variantId) — per-fixture guard inactive until the next in-session promotion\n"
                FileHandle.standardError.write(Data(warn.utf8))
            }
            champion = ChampionState(id: entry.variantId,
                                     pooled: AggregateF1(mean: mean, stdev: sd, n: entry.sampleCount),
                                     fixtures: fixtures, template: nil)
        }

        let perVariantCost = cases.count * models.count * samples
        var callsSpent = 0
        var inputTokens = 0
        var outputTokens = 0
        var failed: [String] = []
        var skipped: [String] = []
        var challengersEvaluated = 0

        for candidate in candidates {
            // §4.4 per-variant budget gate: never start a variant we cannot finish.
            if !IterateCore.canAfford(callsSpent: callsSpent, perVariantCost: perVariantCost, budget: budgetCalls) {
                skipped.append(candidate.id)
                let msg = "budget reached (\(callsSpent)/\(budgetCalls.map(String.init) ?? "∞") calls) "
                    + "— stopping before \(candidate.id)\n"
                FileHandle.standardError.write(Data(msg.utf8))
                break
            }

            do {
                let now = Date()
                let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
                let runDirRel = "runs/\(candidate.id)-\(stamp)"
                let runDir = sessionDir.appendingPathComponent(runDirRel)

                // (a) render each per-fixture override ONCE; hash THAT string (baseline → make()).
                var renderedByCase: [String: String] = [:]
                var hashSet = Set<String>()
                for caseName in cases {
                    let pages = pagesByCase[caseName] ?? []
                    if let template = candidate.template {
                        let rendered = IterateCore.renderPrompt(template: template, pages: pages)
                        renderedByCase[caseName] = rendered
                        hashSet.insert(Hashing.promptHash(rendered))
                    } else {
                        hashSet.insert(Hashing.promptHash(ExtractionPrompt.make(pages: pages)))
                    }
                }
                let manifestHashes = hashSet.sorted()

                // (b) manifest BEFORE the network loop (replayable crash window — Codex blocker 2).
                let referenceDateISO = ISO8601DateFormatter().string(from: now)
                let manifest = Manifest(timestamp: stamp, referenceDateISO: referenceDateISO,
                                        promptHashes: manifestHashes, models: models, sampleCount: samples,
                                        fixtureNames: cases, subjectDOB: subjectDOB)
                try ArtifactWriter.writeManifest(manifest, runDir: runDir)

                // (c) per (fixture, model, sample): pass the SAME rendered string as promptOverride.
                var scores: [CaseScore] = []
                var observed = Set<String>()
                for caseName in cases {
                    let expected = expectedByCase[caseName] ?? ExpectedDoc(patients: [], observations: [])
                    let pages = pagesByCase[caseName] ?? []
                    let pdfData = pdfDataByCase[caseName] ?? Data()
                    let override = renderedByCase[caseName]   // nil for baseline
                    for sample in 0..<samples {
                        // Count the call at ATTEMPT time so a throw mid-flight still spends budget and
                        // later variants can't exceed --budget-calls (PR #16 finding 3).
                        callsSpent += 1
                        let (raw, score) = try await RunCore.runCase(
                            pdfData: pdfData, pages: pages, model: model, fixture: caseName, sample: sample,
                            extractor: extractor, expected: expected, subjectId: subjectId,
                            subjectDOB: parsedSubjectDOB, now: now, promptOverride: override)
                        try ArtifactWriter.writeRaw(raw, runDir: runDir)
                        try ArtifactWriter.writeScored(score, key: raw.key, runDir: runDir)
                        scores.append(score)
                        observed.insert(raw.promptHash)
                        inputTokens += raw.inputTokens ?? 0
                        outputTokens += raw.outputTokens ?? 0
                    }
                }

                // (d) belt-and-suspenders: every observed artifact hash MUST be in the manifest.
                let manifestSet = Set(manifestHashes)
                if let stray = observed.sorted().first(where: { !manifestSet.contains($0) }) {
                    throw IterateRunError.hashMismatch(observed: stray)
                }

                // (e) aggregate → pool → decide → journal → maybe promote.
                let results = Aggregator.aggregate(scores, promptHashes: manifestHashes)
                try ArtifactWriter.writeResults(results, runDir: runDir)
                let pooled = IterateCore.overallStrictF1(scores: scores)

                let decision: WinnerDecision
                if let champ = champion {
                    decision = IterateCore.selectWinner(
                        champion: champ.pooled, challenger: pooled,
                        championFixtures: champ.fixtures, challengerFixtures: results.stats,
                        minImprovement: minImprovement, noiseThreshold: noiseThreshold,
                        minImprovementLowN: minImprovementLowN, maxFixtureRegression: maxFixtureRegression)
                } else {
                    // First evaluated candidate is the seed champion (promoted so resume can recover it).
                    decision = WinnerDecision(promoted: true, deltaMean: 0, seDiff: 0,
                                              blockingFixture: nil, reason: "seed champion")
                }

                let entry = JournalEntry(
                    variantId: candidate.id, promptHash: manifestHashes.first,
                    strictF1Mean: pooled.mean, strictF1Stdev: pooled.stdev, sampleCount: pooled.n,
                    runDir: runDirRel, evaluatedAt: ISO8601DateFormatter().string(from: Date()),
                    decision: DecisionRecord(decision), failure: nil)
                try IterateCore.appendJournal(entry: entry, journalURL: journalURL)

                if decision.promoted {
                    champion = ChampionState(id: candidate.id, pooled: pooled, fixtures: results.stats,
                                             template: candidate.template)
                    try writeChampion(candidate: candidate, pooled: pooled, runDirRel: runDirRel,
                                      promptHash: manifestHashes.first, sessionDir: sessionDir)
                }
                if candidate.id != "baseline" { challengersEvaluated += 1 }
            } catch {
                // §4.7: per-variant fault isolation — record a failure entry (no PHI: thrown errors here are
                // transport/IO/preflight, never decode) and continue; the variant stays retriable on resume.
                failed.append(candidate.id)
                let entry = JournalEntry(
                    variantId: candidate.id, promptHash: nil, strictF1Mean: nil, strictF1Stdev: nil,
                    sampleCount: 0, runDir: nil, evaluatedAt: ISO8601DateFormatter().string(from: Date()),
                    decision: nil, failure: "\(error)")
                try? IterateCore.appendJournal(entry: entry, journalURL: journalURL)
                continue
            }
        }

        // Final summary to stderr (incl. batch token cost).
        let championLine = champion.map { "champion=\($0.id) strictF1=\($0.pooled.mean)" } ?? "champion=none"
        let summary = "iterate complete — \(championLine); calls=\(callsSpent) "
            + "tokens(in/out)=\(inputTokens)/\(outputTokens); failed=\(failed) skipped=\(skipped) "
            + "-> \(sessionDir.path)\n"
        FileHandle.standardError.write(Data(summary.utf8))
        if challengersEvaluated == 0 {
            FileHandle.standardError.write(Data("no challengers evaluated — champion is the baseline\n".utf8))
        }
        #else
        throw ValidationError("`iterate` requires macOS (PDFKit). Use `score`/`report` on existing run dirs elsewhere.")
        #endif
    }

    #if canImport(PDFKit) && os(macOS)
    private struct Candidate { let id: String; let template: String? }   // nil template = baseline (make())

    private struct ChampionState {
        let id: String
        let pooled: AggregateF1
        let fixtures: [FixtureModelStats]
        let template: String?
    }

    private struct ChampionPointer: Codable {
        let variantId: String
        let promptHash: String?
        let strictF1Mean: Double
        let runDir: String
    }

    private enum IterateRunError: Error, CustomStringConvertible {
        case hashMismatch(observed: String)
        var description: String {
            switch self {
            case .hashMismatch(let h): return "observed artifact promptHash \(h) not in manifest.promptHashes"
            }
        }
    }

    private func makeExtractor() throws -> any LLMExtractor {
        let isOpenAI = provider.lowercased() == "openai"
        let envKey = ProcessInfo.processInfo.environment[isOpenAI ? "OPENAI_API_KEY" : "ANTHROPIC_API_KEY"]
        guard let key = apiKey ?? envKey else {
            throw ValidationError("missing API key — pass --api-key or set the provider env var")
        }
        switch provider.lowercased() {
        case "anthropic": return AnthropicExtractor(apiKey: key)
        case "openai": return OpenAIExtractor(apiKey: key)
        default: throw ValidationError("unknown provider '\(provider)' — use anthropic or openai")
        }
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]   // matches ArtifactWriter
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    /// Persist the winning prompt + pointer on promotion (§4.8) so the best prompt is directly diffable
    /// against production and ready to hand to a human. Baseline has no template file — record a marker.
    private func writeChampion(candidate: Candidate, pooled: AggregateF1, runDirRel: String,
                               promptHash: String?, sessionDir: URL) throws {
        let text = candidate.template
            ?? "# baseline — current production ExtractionPrompt.make (no variant template file)\n"
        try text.write(to: sessionDir.appendingPathComponent("champion.txt"),
                       atomically: true, encoding: .utf8)
        let pointer = ChampionPointer(variantId: candidate.id, promptHash: promptHash,
                                      strictF1Mean: pooled.mean, runDir: runDirRel)
        try writeJSON(pointer, to: sessionDir.appendingPathComponent("champion.json"))
    }
    #endif
}
