import Foundation

/// Reads run-dir artifacts back for the pure `score`/`report` subcommands (design §3). Platform-free.
enum ArtifactReader {
    struct ReadError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static func readRaws(runDir: URL) throws -> [RawArtifact] {
        let rawDir = runDir.appendingPathComponent("raw")
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: rawDir.path) else {
            throw ReadError(message: "no raw/ dir at \(rawDir.path)")
        }
        return try names.filter { $0.hasSuffix(".json") }.sorted().map { name in
            let data = try Data(contentsOf: rawDir.appendingPathComponent(name))
            return try JSONDecoder().decode(RawArtifact.self, from: data)
        }
    }

    static func readManifest(runDir: URL) throws -> Manifest {
        let data = try Data(contentsOf: runDir.appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    static func readScores(runDir: URL) throws -> [CaseScore] {
        let scoredDir = runDir.appendingPathComponent("scored")
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: scoredDir.path) else {
            throw ReadError(message: "no scored/ dir at \(scoredDir.path)")
        }
        return try names.filter { $0.hasSuffix(".json") }.sorted().map { name in
            let data = try Data(contentsOf: scoredDir.appendingPathComponent(name))
            return try JSONDecoder().decode(CaseScore.self, from: data)
        }
    }
}
