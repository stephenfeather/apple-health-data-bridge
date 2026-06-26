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

    static func pagesTextURL(root: String, caseName: String) -> URL {
        URL(fileURLWithPath: root)
            .appendingPathComponent(caseName)
            .appendingPathComponent("pages.txt")
    }

    /// Thin I/O wrapper: returns `nil` when `pages.txt` is absent, else the parsed pages plus the raw
    /// bytes (the raw bytes become the case's `inputHash` provenance for PDF-less cases).
    static func pagesText(root: String, caseName: String) throws -> (pages: [String], raw: Data)? {
        let url = pagesTextURL(root: root, caseName: caseName)
        guard let raw = FileManager.default.contents(atPath: url.path) else { return nil }
        guard let text = String(data: raw, encoding: .utf8) else {
            throw LoadError(message: "pages.txt for '\(caseName)' is not valid UTF-8")
        }
        let pages = try parsePages(text)
        return (pages, raw)
    }

    /// REAL-DIRECTORY SEAM (premortem addendum). Does an existence-ONLY check on `input.pdf` — it NEVER
    /// reads or parses the PDF and NEVER calls `PDFText`. Fully resolves the `.pages` arm. The branch
    /// choice routes through the CI-tested pure `resolveInput`, so BOTH arms are cross-platform testable;
    /// `RunCommand.run()` makes the single macOS-only `PDFText.pages` call only in the `.pdf` arm.
    enum ResolvedCaseInput: Equatable { case pdf(URL); case pages(pages: [String], raw: Data) }

    static func resolveCaseInput(root: String, caseName: String) throws -> ResolvedCaseInput {
        let pdfURL = inputPDFURL(root: root, caseName: caseName)
        let pdfExists = FileManager.default.fileExists(atPath: pdfURL.path)   // existence-only, NEVER parsed
        let txt = pdfExists ? nil : try pagesText(root: root, caseName: caseName)
        switch try resolveInput(pdfExists: pdfExists, pagesText: txt?.pages) {
        case .pdf:
            return .pdf(pdfURL)                                                // defer the read to run()
        case .pages(let pages):
            // txt is non-nil here: resolveInput returned .pages only because txt?.pages was non-nil,
            // which required pagesText() to have returned a value. The guard is a defensive trap for
            // future refactors that might break that invariant — not a reachable runtime path.
            guard let raw = txt?.raw else {
                throw LoadError(message: "internal: pages resolved without raw bytes for '\(caseName)'")
            }
            return .pages(pages: pages, raw: raw)
        }
    }
}
