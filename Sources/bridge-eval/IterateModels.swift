import Foundation

/// A single candidate prompt: a human-authored template whose body MUST contain exactly one
/// `{{DOCUMENT}}` placeholder (plan §4.1). The harness renders the per-fixture prompt by substituting
/// the page-numbered document block for the placeholder (`IterateCore.renderPrompt`). `id` is the source
/// `.txt` filename stem — a stable, lexically-ordered variant identifier used for resume keying.
struct PromptVariant: Codable, Equatable {
    let id: String
    let template: String
}
