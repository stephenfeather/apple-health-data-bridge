import XCTest
@testable import bridge_eval

final class ArtifactWriterTests: XCTestCase {
    private func tempRunDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-eval-\(UUID().uuidString)")
        return dir
    }

    func testKeyComposition() {
        XCTAssertEqual(ArtifactWriter.key(promptHash: "abc", model: "claude-opus-4-8",
                                          fixture: "vitals-basic", sample: 2),
                       "abc__claude-opus-4-8__vitals-basic__2")
    }

    func testRunDirComposesUnderRoot() {
        let url = ArtifactWriter.runDir(runsRoot: "/runs", timestamp: "2026-06-25T00-00-00Z")
        XCTAssertEqual(url.path, "/runs/2026-06-25T00-00-00Z")
    }

    func testWriteAndReadbackManifest() throws {
        let runDir = tempRunDir()
        let manifest = Manifest(timestamp: "2026-06-25T00:00:00Z", promptHashes: ["abc"],
                                models: ["m"], sampleCount: 1, fixtureNames: ["vitals-basic"])
        try ArtifactWriter.writeManifest(manifest, runDir: runDir)
        let data = try Data(contentsOf: runDir.appendingPathComponent("manifest.json"))
        XCTAssertEqual(try JSONDecoder().decode(Manifest.self, from: data), manifest)
    }

    func testWriteRawAndScoredIntoSubdirs() throws {
        let runDir = tempRunDir()
        let raw = RawArtifact(key: "k", promptHash: "abc", inputHash: "def", model: "m",
                              fixture: "f", sample: 0, jsonText: "{}", inputTokens: nil,
                              outputTokens: nil, stopReason: nil, latencyMillis: nil)
        try ArtifactWriter.writeRaw(raw, runDir: runDir)
        let score = Scorer.catastrophic(fixture: "f", model: "m", sample: 0)
        try ArtifactWriter.writeScored(score, key: "k", runDir: runDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: runDir.appendingPathComponent("raw/k.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runDir.appendingPathComponent("scored/k.json").path))
    }

    func testWriteResults() throws {
        let runDir = tempRunDir()
        let results = RunResults(promptHashes: ["abc"], stats: [])
        try ArtifactWriter.writeResults(results, runDir: runDir)
        let data = try Data(contentsOf: runDir.appendingPathComponent("results.json"))
        XCTAssertEqual(try JSONDecoder().decode(RunResults.self, from: data), results)
    }
}
