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
}
