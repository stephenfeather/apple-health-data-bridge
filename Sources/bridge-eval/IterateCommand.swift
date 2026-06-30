import Foundation
import ArgumentParser

/// `iterate` subcommand: operator-driven, budget-bounded prompt search over a curated set of candidate
/// `.txt` variants against the gold-fixture fitness function, keeping the best by a noise-aware decision
/// rule and recording every evaluation in an append-only journal (plan §1). Like `run`, the live body
/// touches network/PDFKit and is macOS-guarded; off macOS it refuses rather than pretending to work.
///
/// Compile-first stub: registration only. Options, validate(), and the run() shell land in later tasks.
struct IterateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iterate",
        abstract: "Evaluate candidate prompt variants against gold fixtures; keep the best.")

    func run() async throws {
        #if canImport(PDFKit) && os(macOS)
        // Implemented in Task 9 (integration shell). Stub no-op for now.
        #else
        throw ValidationError("`iterate` requires macOS (PDFKit). Use `score`/`report` on existing run dirs elsewhere.")
        #endif
    }
}
