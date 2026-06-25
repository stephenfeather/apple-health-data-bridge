import Foundation
import ArgumentParser

/// bridge-eval — dev-only LLM-extraction evaluation harness (design §3). NOT in `products`, so it never
/// ships in `healthbridge`. Three subcommands: `run` (network, macOS-guarded), `score` (pure offline
/// rescore), `report` (pure aggregate). No iterate/research loop in v1 (design §11–12).
@main
struct BridgeEval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bridge-eval",
        abstract: "Evaluate LLM PDF-extraction responses against gold fixtures.",
        subcommands: [RunCommand.self, ScoreCommand.self, ReportCommand.self])
}

enum BridgeEvalVersion {
    static let current = "0.1.0"
}
