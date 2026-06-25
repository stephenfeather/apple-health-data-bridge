import Foundation
import ArgumentParser
import HealthBridgeParsing

/// PURE-ish per-case execution of the production step sequence with an INJECTED extractor (design §3,
/// §10). It takes pre-read `pdfData` + `pages` so it is platform-free and stub-testable without PDFKit;
/// the macOS-guarded `PDFText.pages` read happens in the `RunCommand.run()` shell. A transport/HTTP
/// error propagates (the run records nothing for that sample); a malformed reply still yields a raw
/// artifact (preserved for replay/research) plus a catastrophic score.
enum RunCore {
    static func runCase(pdfData: Data, pages: [String], model: String, fixture: String, sample: Int,
                        extractor: any LLMExtractor, expected: ExpectedDoc, subjectId: String,
                        now: Date) async throws -> (raw: RawArtifact, score: CaseScore) {
        let prompt = ExtractionPrompt.make(pages: pages)
        let promptHash = Hashing.promptHash(prompt)
        let inputHash = Hashing.sha256Hex(pdfData)
        let request = LLMRequest(pages: pages, instructions: prompt, model: model)

        let start = Date()
        let response = try await extractor.extract(request)   // network error propagates
        let latencyMillis = Int(Date().timeIntervalSince(start) * 1000)

        let key = ArtifactWriter.key(promptHash: promptHash, model: model, fixture: fixture, sample: sample)
        let raw = RawArtifact(key: key, promptHash: promptHash, inputHash: inputHash, model: model,
                              fixture: fixture, sample: sample, jsonText: response.jsonText,
                              inputTokens: response.meta?.inputTokens, outputTokens: response.meta?.outputTokens,
                              stopReason: response.meta?.stopReason, latencyMillis: latencyMillis)

        let score: CaseScore
        do {
            let result = try LLMResponseContract.decode(response.jsonText, subjectId: subjectId, now: now)
            let distinct = (try? LLMResponseContract.distinctPatientCount(response.jsonText)) ?? 0
            let patient = (try? LLMResponseContract.extractedPatient(response.jsonText)) ?? nil
            score = Scorer.score(fixture: fixture, model: model, sample: sample, result: result,
                                 expected: expected, extractedPatient: patient, distinctPatientCount: distinct)
        } catch {
            score = Scorer.catastrophic(fixture: fixture, model: model, sample: sample)
        }
        return (raw, score)
    }
}

/// `run` subcommand: fixtures × models × N samples → call models → write raw + scored + results.
/// The PDF read and adapter calls touch disk/network, so the body is macOS-guarded (PDFKit) and never
/// runs in CI (design §10). The preflight guard refuses git-tracked fixture/run paths (design §9). The
/// manifest is written BEFORE the network loop (Fix 4) so a mid-run failure leaves a replayable run dir.
struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run fixtures × models × N samples against live models; write run artifacts.")

    @Option(name: .long, help: "Fixtures root (default: eval/fixtures).") var fixtures: String = "eval/fixtures"
    @Option(name: .long, help: "Runs root (default: eval/runs).") var runsRoot: String = "eval/runs"
    @Option(name: .long, parsing: .upToNextOption, help: "Model ids to evaluate.") var models: [String] = ["claude-opus-4-8"]
    @Option(name: .long, help: "Provider (anthropic|openai).") var provider: String = "anthropic"
    @Option(name: .long, help: "API key (else the provider env var). Never persisted/logged.") var apiKey: String?
    @Option(name: .long, help: "Samples per (fixture, model).") var samples: Int = 1
    @Option(name: .long, help: "Subject id used for the contract's single-subject decode.") var subjectId: String = "eval-subject"

    func run() async throws {
        #if canImport(PDFKit) && os(macOS)
        // PHI git-safety: refuse a tracked fixtures root or runs root (design §9).
        try Preflight.assertUntracked(fixtures, role: "fixtures")
        try Preflight.assertUntracked(runsRoot, role: "runs")

        let extractor = try makeExtractor()
        let cases = try Fixtures.discoverCases(root: fixtures)
        // ONE instant drives both the (sanitized) run-dir name and the manifest's parseable reference
        // date used for deterministic offline rescoring (Finding 3).
        let runInstant = Date()
        let referenceDateISO = ISO8601DateFormatter().string(from: runInstant)
        let timestamp = referenceDateISO.replacingOccurrences(of: ":", with: "-")
        let dir = ArtifactWriter.runDir(runsRoot: runsRoot, timestamp: timestamp)

        // Pre-pass: read each fixture's pages ONCE, compute its prompt hash, and keep pages for the loop.
        // This lets the manifest be written BEFORE any network call (Fix 4) and record the DISTINCT
        // per-fixture prompt hashes (Fix 5).
        var pagesByCase: [String: [String]] = [:]
        var pdfDataByCase: [String: Data] = [:]
        var promptHashSet = Set<String>()
        for caseName in cases {
            let pdfData = try Data(contentsOf: Fixtures.inputPDFURL(root: fixtures, caseName: caseName))
            let pages = try PDFText.pages(pdfData)
            pagesByCase[caseName] = pages
            pdfDataByCase[caseName] = pdfData
            promptHashSet.insert(Hashing.promptHash(ExtractionPrompt.make(pages: pages)))
        }
        let promptHashes = promptHashSet.sorted()

        let manifest = Manifest(timestamp: timestamp, referenceDateISO: referenceDateISO,
                                promptHashes: promptHashes, models: models, sampleCount: samples,
                                fixtureNames: cases)
        try ArtifactWriter.writeManifest(manifest, runDir: dir)   // BEFORE the loop (Fix 4)

        var allScores: [CaseScore] = []
        for caseName in cases {
            let expected = try Fixtures.loadExpected(root: fixtures, caseName: caseName)
            let pages = pagesByCase[caseName] ?? []
            let pdfData = pdfDataByCase[caseName] ?? Data()
            for model in models {
                for sample in 0..<samples {
                    let (raw, score) = try await RunCore.runCase(
                        pdfData: pdfData, pages: pages, model: model, fixture: caseName, sample: sample,
                        extractor: extractor, expected: expected, subjectId: subjectId, now: Date())
                    try ArtifactWriter.writeRaw(raw, runDir: dir)
                    try ArtifactWriter.writeScored(score, key: raw.key, runDir: dir)
                    allScores.append(score)
                }
            }
        }

        let results = Aggregator.aggregate(allScores, promptHashes: promptHashes)
        try ArtifactWriter.writeResults(results, runDir: dir)
        FileHandle.standardError.write(Data("run complete -> \(dir.path)\n".utf8))
        #else
        throw ValidationError("`run` requires macOS (PDFKit). Use `score`/`report` on existing run dirs elsewhere.")
        #endif
    }

    #if canImport(PDFKit) && os(macOS)
    private func makeExtractor() throws -> any LLMExtractor {
        // Normalize ONCE so the env-key lookup and the provider switch agree (e.g. `--provider OpenAI`
        // must read OPENAI_API_KEY, not ANTHROPIC_API_KEY).
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
    #endif
}
