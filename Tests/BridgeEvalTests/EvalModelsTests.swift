import XCTest
@testable import bridge_eval

final class EvalModelsTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func testExpectedDocDecodesContractShape() throws {
        let json = """
        {"patients":[{"name":"Jane Public","dob":"1990-05-01"}],
         "observations":[{"loinc":"8867-4","display":"Heart rate","value":72.5,"valueText":null,
                          "unit":"/min","effectiveDate":"2024-01-15","category":"vital"}]}
        """
        let doc = try JSONDecoder().decode(ExpectedDoc.self, from: Data(json.utf8))
        XCTAssertEqual(doc.patients.first?.name, "Jane Public")
        XCTAssertEqual(doc.observations.first?.loinc, "8867-4")
        XCTAssertEqual(doc.observations.first?.value, 72.5)
        XCTAssertEqual(doc.observations.first?.category, "vital")
    }

    func testCaseScoreRoundTrips() throws {
        let score = CaseScore(
            fixture: "vitals-basic", model: "claude-opus-4-8", sample: 0, catastrophic: false,
            strict: F1(precision: 1, recall: 1, f1: 1),
            lenient: F1(precision: 1, recall: 1, f1: 1),
            skipHistogram: ["noUsableValue": 1],
            matches: [MatchRecord(loinc: "8867-4", outcome: .hit, fieldErrors: nil)],
            patient: PatientCorrectness(distinctCountCorrect: true, identityCorrect: true))
        XCTAssertEqual(try roundTrip(score), score)
    }

    func testRunResultsRoundTrips() throws {
        let r = RunResults(promptHashes: ["abc", "def"], stats: [
            FixtureModelStats(fixture: "f", model: "m",
                              strictF1: AggregateF1(mean: 0.8, stdev: 0.1, n: 3),
                              lenientF1: AggregateF1(mean: 0.9, stdev: 0.05, n: 3),
                              outputConsistency: 0.66, catastrophicRate: 0.0)])
        XCTAssertEqual(try roundTrip(r), r)
    }

    func testManifestAndRawArtifactRoundTrip() throws {
        let m = Manifest(timestamp: "2026-06-25T10-47-37Z", referenceDateISO: "2026-06-25T10:47:37Z",
                         promptHashes: ["abc", "xyz"], models: ["m1", "m2"], sampleCount: 3,
                         fixtureNames: ["f1"], subjectDOB: nil)
        XCTAssertEqual(try roundTrip(m), m)
        // No-DOB regression: a manifest from a run without --subject-dob round-trips with subjectDOB nil.
        XCTAssertNil(try roundTrip(m).subjectDOB)
        // referenceDateISO must survive UNsanitized so ISO8601DateFormatter can parse it (Finding 3).
        XCTAssertEqual(try roundTrip(m).referenceDateISO, "2026-06-25T10:47:37Z")
        XCTAssertNotNil(ISO8601DateFormatter().date(from: try roundTrip(m).referenceDateISO))
        let raw = RawArtifact(key: "abc__m1__f1__0", promptHash: "abc", inputHash: "def",
                              model: "m1", fixture: "f1", sample: 0, jsonText: "{}",
                              inputTokens: 10, outputTokens: 20, stopReason: "stop", latencyMillis: 1234)
        XCTAssertEqual(try roundTrip(raw), raw)
    }

    // The DOB the run used must survive encode/decode UNreformatted (raw yyyy-MM-dd), so offline rescore
    // can parse back the EXACT Date the live path used. And a LEGACY manifest JSON without the field must
    // decode with subjectDOB == nil (backward compatible — no schema-version field, no throw).
    func testManifestSubjectDOBRoundTripsAndIsBackwardCompatible() throws {
        let withDOB = Manifest(timestamp: "2026-06-25T10-47-37Z", referenceDateISO: "2026-06-25T10:47:37Z",
                               promptHashes: ["abc"], models: ["m"], sampleCount: 1,
                               fixtureNames: ["f1"], subjectDOB: "1990-05-01")
        XCTAssertEqual(try roundTrip(withDOB), withDOB)
        XCTAssertEqual(try roundTrip(withDOB).subjectDOB, "1990-05-01")

        let legacyJSON = """
        {"timestamp":"2026-06-25T10-47-37Z","referenceDateISO":"2026-06-25T10:47:37Z",
         "promptHashes":["abc"],"models":["m"],"sampleCount":1,"fixtureNames":["f1"]}
        """
        let legacy = try JSONDecoder().decode(Manifest.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.subjectDOB)
    }
}
