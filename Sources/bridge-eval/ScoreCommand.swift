import Foundation
import ArgumentParser
import HealthBridgeParsing

/// Pure decode+score of a saved raw response against gold (design §3 `score`). Decoupled from disk so
/// it unit-tests with a synthetic RawArtifact + ExpectedDoc, zero network. A malformed reply (decode
/// throws ParseError.malformed) becomes a catastrophic CaseScore.
enum ScoreCore {
    static func rescore(raw: RawArtifact, expected: ExpectedDoc, subjectId: String, now: Date) -> CaseScore {
        do {
            let result = try LLMResponseContract.decode(raw.jsonText, subjectId: subjectId, now: now)
            let distinct = (try? LLMResponseContract.distinctPatientCount(raw.jsonText)) ?? 0
            let patient = (try? LLMResponseContract.extractedPatient(raw.jsonText)) ?? nil
            return Scorer.score(fixture: raw.fixture, model: raw.model, sample: raw.sample,
                                result: result, expected: expected,
                                extractedPatient: patient, distinctPatientCount: distinct)
        } catch {
            return Scorer.catastrophic(fixture: raw.fixture, model: raw.model, sample: raw.sample)
        }
    }
}

/// `score` subcommand: re-score saved raw responses offline (pure). Reads raw/*.json from a run dir,
/// rescores each against the matching fixture's expected.json, rewrites scored/*.json + results.json.
/// The run-level promptHashes are the DISTINCT per-case RawArtifact.promptHash values (Fix 5).
struct ScoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "score",
        abstract: "Re-score saved raw responses offline against gold fixtures (no network).")

    @Option(name: .long, help: "Run directory containing raw/*.json and manifest.json.") var runDir: String
    @Option(name: .long, help: "Fixtures root (default: eval/fixtures).") var fixtures: String = "eval/fixtures"
    @Option(name: .long, help: "Subject id used for the contract's single-subject decode.") var subjectId: String = "eval-subject"

    func run() async throws {
        let dir = URL(fileURLWithPath: runDir)
        let raws = try ArtifactReader.readRaws(runDir: dir)
        var expectedCache: [String: ExpectedDoc] = [:]
        var scores: [CaseScore] = []
        for raw in raws {
            let expected: ExpectedDoc
            if let cached = expectedCache[raw.fixture] {
                expected = cached
            } else {
                expected = try Fixtures.loadExpected(root: fixtures, caseName: raw.fixture)
                expectedCache[raw.fixture] = expected
            }
            let score = ScoreCore.rescore(raw: raw, expected: expected, subjectId: subjectId, now: Date())
            try ArtifactWriter.writeScored(score, key: raw.key, runDir: dir)
            scores.append(score)
        }
        let promptHashes = Set(raws.map { $0.promptHash }).sorted()
        let results = Aggregator.aggregate(scores, promptHashes: promptHashes)
        try ArtifactWriter.writeResults(results, runDir: dir)
        FileHandle.standardError.write(Data("scored \(scores.count) case(s) -> \(dir.path)/results.json\n".utf8))
    }
}
