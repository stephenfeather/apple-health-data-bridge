import Foundation
import ArgumentParser

/// Pure human-table rendering of aggregate results (design §3 `report`). A single-sample stat renders
/// `n=1 (single sample)` instead of a misleading `±0.00` (premortem Fix 3).
enum Report {
    static func renderTable(_ results: RunResults) -> String {
        guard !results.stats.isEmpty else {
            return "no results (prompts \(results.promptHashes.joined(separator: ",")))\n"
        }
        func f(_ x: Double) -> String { String(format: "%.2f", x) }
        func cell(_ a: AggregateF1) -> String {
            a.n <= 1 ? "\(f(a.mean)) n=1 (single sample)" : "\(f(a.mean))±\(f(a.stdev))"
        }
        var lines = ["prompts \(results.promptHashes.joined(separator: ","))",
                     "fixture\tmodel\tstrictF1\tlenientF1\tconsistency\tcatastrophic"]
        for s in results.stats {
            lines.append([
                s.fixture, s.model,
                cell(s.strictF1),
                cell(s.lenientF1),
                f(s.outputConsistency),
                f(s.catastrophicRate),
            ].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// `report` subcommand: re-aggregate a run dir's scored/*.json into a table + results.json (pure).
struct ReportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report",
        abstract: "Aggregate a run directory into a human table and machine results.json (no network).")

    @Option(name: .long, help: "Run directory containing scored/*.json and manifest.json.") var runDir: String

    func run() async throws {
        let dir = URL(fileURLWithPath: runDir)
        let manifest = try ArtifactReader.readManifest(runDir: dir)
        let scores = try ArtifactReader.readScores(runDir: dir)
        let results = Aggregator.aggregate(scores, promptHashes: manifest.promptHashes)
        try ArtifactWriter.writeResults(results, runDir: dir)
        print(Report.renderTable(results))
    }
}
