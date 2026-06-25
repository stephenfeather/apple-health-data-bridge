import Foundation

/// bridge-eval — dev-only LLM-extraction evaluation harness. NOT shipped in `healthbridge`.
/// `@main` root + subcommands are wired in Task 13; this stub exists so Task 1 proves the
/// target compiles and links before any feature code lands.
enum BridgeEvalVersion {
    static let current = "0.1.0"
}
