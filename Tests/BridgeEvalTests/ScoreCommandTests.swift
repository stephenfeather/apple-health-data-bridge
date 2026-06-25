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
}
