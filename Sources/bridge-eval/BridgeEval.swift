import Foundation

/// bridge-eval — dev-only LLM-extraction evaluation harness. NOT shipped in `healthbridge`.
/// The real `@main AsyncParsableCommand` root + run/score/report subcommands are wired in Task 13;
/// this file currently holds the version stub plus a TEMPORARY `@main` entry point.
enum BridgeEvalVersion {
    static let current = "0.1.0"
}

/// TEMPORARY entry point. An `executableTarget` with more than one source file (added from Task 2
/// on) must declare an explicit `@main`/`main.swift` — SwiftPM only treats a *single-file* executable
/// as an implicit script. Without this, `swift build`/`swift test` fail to link the product
/// (`_bridge_eval_main` undefined). Task 13 REPLACES this with the real ArgumentParser command root.
@main
struct BridgeEvalEntry {
    static func main() {
        let msg = "bridge-eval \(BridgeEvalVersion.current): command tree not yet wired (build in progress)\n"
        FileHandle.standardError.write(Data(msg.utf8))
    }
}
