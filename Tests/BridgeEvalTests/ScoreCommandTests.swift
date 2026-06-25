import XCTest
import HealthBridgeParsing
@testable import bridge_eval

final class ScoreCommandTests: XCTestCase {
    private let goodJSON = """
    {"patients":[{"name":"Jane Public","dob":"1990-05-01"}],
     "observations":[{"loinc":"8867-4","display":"Heart rate","value":72.5,"unit":"/min",
                      "effectiveDate":"2024-01-15","category":"vital","confidence":0.9}]}
    """
    private func expectedDoc() -> ExpectedDoc {
        ExpectedDoc(patients: [ExpectedPatient(name: "Jane Public", dob: "1990-05-01")],
                    observations: [ExpectedObservation(loinc: "8867-4", display: "Heart rate", value: 72.5,
                                   valueText: nil, unit: "/min", effectiveDate: "2024-01-15", category: "vital")])
    }
    private func raw(_ jsonText: String) -> RawArtifact {
        RawArtifact(key: "abc__m__vitals-basic__0", promptHash: "abc", inputHash: "def", model: "m",
                    fixture: "vitals-basic", sample: 0, jsonText: jsonText, inputTokens: nil,
                    outputTokens: nil, stopReason: nil, latencyMillis: nil)
    }

    func testRescoreMalformedIsCatastrophic() {
        let score = ScoreCore.rescore(raw: raw("not json"), expected: expectedDoc(),
                                      subjectId: "subj", now: Date())
        XCTAssertTrue(score.catastrophic)
    }

    func testRescoreGoodResponseHits() {
        let score = ScoreCore.rescore(raw: raw(goodJSON), expected: expectedDoc(),
                                      subjectId: "subj", now: Date())
        XCTAssertFalse(score.catastrophic)
        XCTAssertEqual(score.strict.f1, 1.0, accuracy: 1e-9)
        XCTAssertEqual(score.matches.first?.outcome, .hit)
    }

    func testReadRawsRoundTrip() throws {
        let runDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-eval-read-\(UUID().uuidString)")
        try ArtifactWriter.writeRaw(raw(goodJSON), runDir: runDir)
        let raws = try ArtifactReader.readRaws(runDir: runDir)
        XCTAssertEqual(raws.count, 1)
        XCTAssertEqual(raws.first?.fixture, "vitals-basic")
        XCTAssertEqual(raws.first?.promptHash, "abc")
    }

    // Finding 3: `score` must use the manifest's reference instant as `now`, not wall-clock time, so an
    // offline replay is deterministic. We write a run dir whose manifest reference date is FIXED in the
    // past (2020-01-01), and a raw obs dated 2024-01-15 — AFTER the manifest date but BEFORE the actual
    // wall clock. Under wall-clock `now` the obs is plausible and would HIT; under the manifest date it is
    // `dateAfterNow` and is skipped, so it can NOT be a hit. The scored result must reflect the MANIFEST
    // date, proving determinism.
    func testScoreCommandUsesManifestReferenceDateNotWallClock() async throws {
        let runDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-eval-det-\(UUID().uuidString)")
        let fixturesRoot = runDir.appendingPathComponent("fixtures")
        let caseDir = fixturesRoot.appendingPathComponent("vitals-basic")
        try FileManager.default.createDirectory(at: caseDir, withIntermediateDirectories: true)

        // Gold expects the 2024-01-15 observation.
        let expectedJSON = """
        {"patients":[{"name":"Jane Public","dob":"1990-05-01"}],
         "observations":[{"loinc":"8867-4","display":"Heart rate","value":72.5,"valueText":null,
                          "unit":"/min","effectiveDate":"2024-01-15","category":"vital"}]}
        """
        try Data(expectedJSON.utf8).write(to: caseDir.appendingPathComponent("expected.json"))

        // Manifest reference instant fixed BEFORE the observation date.
        let manifest = Manifest(timestamp: "2020-01-01T00-00-00Z",
                                referenceDateISO: "2020-01-01T00:00:00Z",
                                promptHashes: ["abc"], models: ["m"], sampleCount: 1,
                                fixtureNames: ["vitals-basic"])
        try ArtifactWriter.writeManifest(manifest, runDir: runDir)
        try ArtifactWriter.writeRaw(raw(goodJSON), runDir: runDir)

        var cmd = ScoreCommand()
        cmd.runDir = runDir.path
        cmd.fixtures = fixturesRoot.path
        cmd.subjectId = "subj"
        try await cmd.run()

        let scores = try ArtifactReader.readScores(runDir: runDir)
        XCTAssertEqual(scores.count, 1)
        let score = try XCTUnwrap(scores.first)
        // The obs was skipped as dateAfterNow relative to the MANIFEST date -> not a hit; the gold is a
        // miss. Wall-clock scoring (2026) would have produced a hit + f1 == 1.0.
        XCTAssertFalse(score.matches.contains { $0.outcome == .hit })
        XCTAssertLessThan(score.strict.f1, 1.0)
        XCTAssertEqual(score.skipHistogram["dateAfterNow"], 1)
    }
}
