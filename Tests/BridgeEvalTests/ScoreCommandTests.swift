import XCTest
import HealthBridgeParsing
@testable import bridge_eval

final class ScoreCommandTests: XCTestCase {
    private static let fixedNow = LLMResponseContract.parseDate("2026-06-24")!
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
                                      subjectId: "subj", now: Self.fixedNow)
        XCTAssertTrue(score.catastrophic)
    }

    func testRescoreGoodResponseHits() {
        let score = ScoreCore.rescore(raw: raw(goodJSON), expected: expectedDoc(),
                                      subjectId: "subj", now: Self.fixedNow)
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
                                fixtureNames: ["vitals-basic"], subjectDOB: nil)
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

    // Live==replay symmetry (Fix 2): a run that used --subject-dob persists the DOB in its manifest, so
    // offline rescore reads it and re-fires the SAME before-DOB skip the live run did. The raw response
    // carries an obs dated 1985-03-10 (5y before the subject's 1990-05-01 DOB); gold carries the correct
    // plausible-dated obs for the same display. The live run skipped the obs into `dateBeforeDOB` and
    // scored strict.f1 == 0.0; the rescore MUST match. Before Fix 2 the rescore ignored the DOB, KEPT the
    // obs, and produced no `dateBeforeDOB` skip — so this assertion fails (the genuine RED).
    func testScoreCommandReadsSubjectDOBFromManifest() async throws {
        let runDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-eval-dob-\(UUID().uuidString)")
        let fixturesRoot = runDir.appendingPathComponent("fixtures")
        let caseDir = fixturesRoot.appendingPathComponent("vitals-basic")
        try FileManager.default.createDirectory(at: caseDir, withIntermediateDirectories: true)

        // Gold: the correct PLAUSIBLE-dated observation for the same display.
        let expectedJSON = """
        {"patients":[{"name":"Jane Public","dob":"1990-05-01"}],
         "observations":[{"loinc":"8867-4","display":"Heart rate","value":68,"valueText":null,
                          "unit":"/min","effectiveDate":"2024-05-15","category":"vital"}]}
        """
        try Data(expectedJSON.utf8).write(to: caseDir.appendingPathComponent("expected.json"))

        // Raw response: the model emitted an obs dated BEFORE the subject's DOB (1985 < 1990).
        let beforeDOBJSON = """
        {"patients":[{"name":"Jane Public","dob":"1990-05-01"}],
         "observations":[{"loinc":"8867-4","display":"Heart rate","value":68,"unit":"/min",
                          "effectiveDate":"1985-03-10","category":"vital","confidence":0.9}]}
        """

        // Manifest records the RAW DOB the live run used; reference instant well after both dates so the
        // ONLY guard in play is the before-DOB skip (not dateAfterNow).
        let manifest = Manifest(timestamp: "2026-06-24T00-00-00Z",
                                referenceDateISO: "2026-06-24T00:00:00Z",
                                promptHashes: ["abc"], models: ["m"], sampleCount: 1,
                                fixtureNames: ["vitals-basic"], subjectDOB: "1990-05-01")
        try ArtifactWriter.writeManifest(manifest, runDir: runDir)
        try ArtifactWriter.writeRaw(raw(beforeDOBJSON), runDir: runDir)

        var cmd = ScoreCommand()
        cmd.runDir = runDir.path
        cmd.fixtures = fixturesRoot.path
        cmd.subjectId = "subj"
        try await cmd.run()

        let scores = try ArtifactReader.readScores(runDir: runDir)
        XCTAssertEqual(scores.count, 1)
        let score = try XCTUnwrap(scores.first)
        // Replay must mirror live: the before-DOB obs is skipped, the gold is missed, strict.f1 == 0.0.
        XCTAssertEqual(score.skipHistogram["dateBeforeDOB"], 1)
        XCTAssertEqual(score.strict.f1, 0.0, accuracy: 1e-9)
        XCTAssertFalse(score.matches.contains { $0.outcome == .hit })
    }

    // No-DOB regression: a run WITHOUT --subject-dob writes subjectDOB nil; rescore parses nil and behaves
    // exactly as today — the before-DOB guard never fires and a plausible obs hits gold (strict.f1 == 1.0).
    func testScoreCommandNilManifestDOBRescoresAsToday() async throws {
        let runDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-eval-nodob-\(UUID().uuidString)")
        let fixturesRoot = runDir.appendingPathComponent("fixtures")
        let caseDir = fixturesRoot.appendingPathComponent("vitals-basic")
        try FileManager.default.createDirectory(at: caseDir, withIntermediateDirectories: true)

        let expectedJSON = """
        {"patients":[{"name":"Jane Public","dob":"1990-05-01"}],
         "observations":[{"loinc":"8867-4","display":"Heart rate","value":72.5,"valueText":null,
                          "unit":"/min","effectiveDate":"2024-01-15","category":"vital"}]}
        """
        try Data(expectedJSON.utf8).write(to: caseDir.appendingPathComponent("expected.json"))

        let manifest = Manifest(timestamp: "2026-06-24T00-00-00Z",
                                referenceDateISO: "2026-06-24T00:00:00Z",
                                promptHashes: ["abc"], models: ["m"], sampleCount: 1,
                                fixtureNames: ["vitals-basic"], subjectDOB: nil)
        try ArtifactWriter.writeManifest(manifest, runDir: runDir)
        try ArtifactWriter.writeRaw(raw(goodJSON), runDir: runDir)

        var cmd = ScoreCommand()
        cmd.runDir = runDir.path
        cmd.fixtures = fixturesRoot.path
        cmd.subjectId = "subj"
        try await cmd.run()

        let scores = try ArtifactReader.readScores(runDir: runDir)
        let score = try XCTUnwrap(scores.first)
        XCTAssertNil(score.skipHistogram["dateBeforeDOB"])
        XCTAssertEqual(score.strict.f1, 1.0, accuracy: 1e-9)
        XCTAssertTrue(score.matches.contains { $0.outcome == .hit })
    }
}
