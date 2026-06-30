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

    @Option(name: .long, help: "Variants dir of *.txt prompt templates (default: eval/prompts).")
    var variants: String = "eval/prompts"
    @Option(name: .long, help: "Fixtures root (default: eval/fixtures).")
    var fixtures: String = "eval/fixtures"
    @Option(name: .long, help: "Iterate session root (default: eval/iterate).")
    var iterateRoot: String = "eval/iterate"
    @Option(name: .long, parsing: .upToNextOption,
            help: "Model id to evaluate — exactly one (the decision rule is per-model).")
    var models: [String] = ["claude-opus-4-8"]
    @Option(name: .long, help: "Samples per (fixture, model).") var samples: Int = 1
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
    }

    func run() async throws {
        #if canImport(PDFKit) && os(macOS)
        // Implemented in Task 9 (integration shell). Stub no-op for now.
        #else
        throw ValidationError("`iterate` requires macOS (PDFKit). Use `score`/`report` on existing run dirs elsewhere.")
        #endif
    }
}
