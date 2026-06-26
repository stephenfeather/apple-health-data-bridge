import Foundation

/// Loads a fixture case (design §5): `<root>/<case>/expected.json` (always) + `input.pdf` (for `run`).
/// `loadExpected`/`discoverCases` are platform-free and exercised with the committed Tier A synthetic
/// gold. PDF bytes are read by the macOS-guarded `run` leg, not here.
enum Fixtures {
    struct LoadError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static func discoverCases(root: String) throws -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else {
            throw LoadError(message: "fixtures root not readable: \(root)")
        }
        return entries.filter { name in
            var isDir: ObjCBool = false
            let casePath = (root as NSString).appendingPathComponent(name)
            guard fm.fileExists(atPath: casePath, isDirectory: &isDir), isDir.boolValue else { return false }
            let expected = (casePath as NSString).appendingPathComponent("expected.json")
            return fm.fileExists(atPath: expected)
        }.sorted()
    }

    static func loadExpected(root: String, caseName: String) throws -> ExpectedDoc {
        let path = (root as NSString)
            .appendingPathComponent(caseName)
            .appending("/expected.json")
        guard let data = FileManager.default.contents(atPath: path) else {
            throw LoadError(message: "missing expected.json for case '\(caseName)' at \(path)")
        }
        do {
            return try JSONDecoder().decode(ExpectedDoc.self, from: data)
        } catch {
            throw LoadError(message: "expected.json for '\(caseName)' is not valid: \(error)")
        }
    }

    static func inputPDFURL(root: String, caseName: String) -> URL {
        URL(fileURLWithPath: root)
            .appendingPathComponent(caseName)
            .appendingPathComponent("input.pdf")
    }

    // MARK: - pages.txt input path (design §5) — pure, platform-free, zero PDFKit.

    /// Form-feed (U+000C) is the canonical page delimiter — exactly what `pdftotext` emits — so a
    /// `pages.txt` produced from a real extraction is a drop-in. Split on `\f`; drop a single trailing
    /// empty page (the `pdftotext` trailing-FF artifact) while preserving interior empty pages; reject
    /// an all-whitespace document for parity with `PDFText.pages` ("no extractable text",
    /// `PDFText.swift:38-39`).
    static func parsePages(_ text: String) throws -> [String] {
        var pages = text.components(separatedBy: "\u{000C}")
        if pages.count > 1, pages.last?.isEmpty == true {
            pages.removeLast()   // drop ONLY the trailing FF artifact; interior empties stay
        }
        guard pages.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw LoadError(message: "pages.txt has no extractable text")
        }
        return pages
    }

    /// Pure input-resolution decision. Keeping the branch selection here makes BOTH arms CI-testable;
    /// only the literal `PDFText.pages` call stays macOS-guarded in `RunCommand.run()`. Precedence:
    /// `input.pdf` wins (realistic PDFKit path, zero behavior change for existing fixtures); `pages.txt`
    /// is the PDF-less fallback; neither present is a loud error.
    enum ResolvedInput: Equatable { case pdf; case pages([String]) }

    static func resolveInput(pdfExists: Bool, pagesText: [String]?) throws -> ResolvedInput {
        if pdfExists { return .pdf }
        if let pages = pagesText { return .pages(pages) }
        throw LoadError(message: "case has neither input.pdf nor pages.txt")
    }
}
