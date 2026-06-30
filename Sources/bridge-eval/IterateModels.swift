import Foundation

/// A single candidate prompt: a human-authored template whose body MUST contain exactly one
/// `{{DOCUMENT}}` placeholder (plan §4.1). The harness renders the per-fixture prompt by substituting
/// the page-numbered document block for the placeholder (`IterateCore.renderPrompt`). `id` is the source
/// `.txt` filename stem — a stable, lexically-ordered variant identifier used for resume keying.
struct PromptVariant: Codable, Equatable {
    let id: String
    let template: String
}

/// The full outcome of a champion-vs-challenger comparison (`IterateCore.selectWinner`, plan §4.2). A
/// superset of the journal's `DecisionRecord`: it additionally names the fixture that blocked a
/// per-fixture regression (Task 5c) so the journal can record *why* a per-fixture-regressing challenger
/// was held back. `blockingFixture` is nil unless condition 3 (per-fixture regression) fired.
struct WinnerDecision: Codable, Equatable {
    let promoted: Bool
    let deltaMean: Double
    let seDiff: Double
    let blockingFixture: String?
    let reason: String
}
