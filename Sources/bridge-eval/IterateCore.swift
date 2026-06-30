import Foundation

/// Pure, offline helpers for the `iterate` loop (plan §5). No network, no PDFKit, no keys — every
/// function here is unit-tested under Patterns B/C. The macOS-guarded `IterateCommand.run()` shell
/// composes these.
enum IterateCore {
    /// The single placeholder a variant template must contain (exactly once) — replaced with the
    /// page-numbered document block at render time (plan §4.1).
    static let documentPlaceholder = "{{DOCUMENT}}"

    enum LoadError: Error, Equatable {
        /// Template did not contain exactly one `{{DOCUMENT}}` placeholder (count attached).
        case placeholderCount(variantId: String, found: Int)
    }

    /// Load every `*.txt` file in `dirURL` as a `PromptVariant`, in lexical filename order (plan §4.1).
    /// `id` = filename stem; `template` = file contents. Each template MUST contain exactly one
    /// `{{DOCUMENT}}` placeholder — zero or more than one throws `LoadError.placeholderCount` (a
    /// missing placeholder would send the model no document; a duplicated one is operator error).
    /// Non-`.txt` entries are ignored.
    static func loadVariants(from dirURL: URL) throws -> [PromptVariant] {
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: dirURL, includingPropertiesForKeys: nil)
        let txtURLs = fileURLs
            .filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return try txtURLs.map { url in
            let id = url.deletingPathExtension().lastPathComponent
            let template = try String(contentsOf: url, encoding: .utf8)
            let count = placeholderCount(in: template)
            guard count == 1 else {
                throw LoadError.placeholderCount(variantId: id, found: count)
            }
            return PromptVariant(id: id, template: template)
        }
    }

    /// Count occurrences of the document placeholder in a template (non-overlapping).
    private static func placeholderCount(in template: String) -> Int {
        template.components(separatedBy: documentPlaceholder).count - 1
    }

    /// Render a per-fixture prompt by substituting the page-numbered document block for the single
    /// `{{DOCUMENT}}` placeholder (plan §4.1, §4.5). The block format MUST stay byte-identical to
    /// `ExtractionPrompt.make` so a `renderPrompt`-rendered variant and the `make()`-rendered baseline
    /// inject the same document. DRIFT TRIPWIRE: if `make()`'s page-block format ever changes, the test
    /// `IterateCoreTests.testRenderPromptDocumentBlockMatchesExtractionPromptMake` fails — re-sync the
    /// line below to match `make()` exactly (no shared helper: `make()` is off-limits production source).
    static func renderPrompt(template: String, pages: [String]) -> String {
        let document = pages.enumerated()
            .map { "----- PAGE \($0.offset + 1) -----\n\($0.element)" }
            .joined(separator: "\n")
        return template.replacingOccurrences(of: documentPlaceholder, with: document)
    }
}
