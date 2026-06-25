import Foundation

/// Writes the run-dir artifacts (design §7). Re-implements minimal JSON writing because `RawResponseLog`
/// lives in the un-importable `healthbridge` executable target (scout §7) — the shipping CLI stays
/// untouched. Key/path composition is pure; writes create dirs lazily and pretty-print with sorted keys
/// for diff-friendliness.
enum ArtifactWriter {
    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static func key(promptHash: String, model: String, fixture: String, sample: Int) -> String {
        "\(promptHash)__\(model)__\(fixture)__\(sample)"
    }

    static func runDir(runsRoot: String, timestamp: String) -> URL {
        URL(fileURLWithPath: runsRoot).appendingPathComponent(timestamp)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encoder().encode(value).write(to: url, options: .atomic)
    }

    static func writeManifest(_ manifest: Manifest, runDir: URL) throws {
        try write(manifest, to: runDir.appendingPathComponent("manifest.json"))
    }

    static func writeRaw(_ raw: RawArtifact, runDir: URL) throws {
        try write(raw, to: runDir.appendingPathComponent("raw").appendingPathComponent("\(raw.key).json"))
    }

    static func writeScored(_ score: CaseScore, key: String, runDir: URL) throws {
        try write(score, to: runDir.appendingPathComponent("scored").appendingPathComponent("\(key).json"))
    }

    static func writeResults(_ results: RunResults, runDir: URL) throws {
        try write(results, to: runDir.appendingPathComponent("results.json"))
    }
}
