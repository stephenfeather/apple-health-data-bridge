import XCTest
import HealthBridgeParsing
@testable import bridge_eval

private struct StubExtractor: LLMExtractor {
    let response: LLMRawResponse
    let error: LLMError?
    init(json: String, meta: LLMResponseMeta? = nil) {
        self.response = LLMRawResponse(jsonText: json, meta: meta); self.error = nil
    }
    init(error: LLMError) {
        self.response = LLMRawResponse(jsonText: ""); self.error = error
    }
    func extract(_ request: LLMRequest) async throws -> LLMRawResponse {
        if let error { throw error }
        return response
    }
}

final class RunCommandTests: XCTestCase {
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

    func testRunCaseProducesRawAndScore() async throws {
        let meta = LLMResponseMeta(inputTokens: 10, outputTokens: 20, stopReason: "stop")
        let (raw, score) = try await RunCore.runCase(
            pdfData: Data("%PDF-1.4".utf8), pages: ["Heart rate 72.5 /min on 2024-01-15"],
            model: "m", fixture: "vitals-basic", sample: 0,
            extractor: StubExtractor(json: goodJSON, meta: meta), expected: expectedDoc(),
            subjectId: "subj", now: Self.fixedNow)
        XCTAssertEqual(raw.jsonText, goodJSON)
        XCTAssertEqual(raw.inputTokens, 10)
        XCTAssertEqual(raw.stopReason, "stop")
        XCTAssertFalse(raw.promptHash.isEmpty)
        XCTAssertFalse(raw.inputHash.isEmpty)
        XCTAssertEqual(score.strict.f1, 1.0, accuracy: 1e-9)
    }

    func testRunCaseMalformedResponseIsCatastrophicButStillRaw() async throws {
        let (raw, score) = try await RunCore.runCase(
            pdfData: Data("%PDF".utf8), pages: ["x"], model: "m", fixture: "f", sample: 0,
            extractor: StubExtractor(json: "not json"), expected: expectedDoc(),
            subjectId: "subj", now: Self.fixedNow)
        XCTAssertEqual(raw.jsonText, "not json")   // raw preserved for replay/research
        XCTAssertTrue(score.catastrophic)
    }

    func testRunCasePropagatesTransportError() async {
        do {
            _ = try await RunCore.runCase(
                pdfData: Data("%PDF".utf8), pages: ["x"], model: "m", fixture: "f", sample: 0,
                extractor: StubExtractor(error: .transport("boom")), expected: expectedDoc(),
                subjectId: "subj", now: Self.fixedNow)
            XCTFail("expected throw")
        } catch let e as LLMError {
            XCTAssertEqual(e, .transport("boom"))
        } catch { XCTFail("wrong error \(error)") }
    }

    // A non-nil subjectDOB makes the before-DOB plausible-date guard reachable from the harness:
    // an observation dated five years before DOB is rejected into the `dateBeforeDOB` skip bucket.
    func testRunCaseWithSubjectDOBRejectsDateBeforeDOB() async throws {
        let stubJSON = """
        {"patients":[{"name":"Jane Public","dob":"1990-05-01"}],
         "observations":[{"loinc":"8867-4","display":"Heart rate","value":68,"unit":"/min",
                          "effectiveDate":"1985-03-10","category":"vital","confidence":0.9}]}
        """
        // Gold uses a plausible date for the same display so the skip links via display match.
        let expected = ExpectedDoc(
            patients: [ExpectedPatient(name: "Jane Public", dob: "1990-05-01")],
            observations: [ExpectedObservation(loinc: "8867-4", display: "Heart rate", value: 68,
                           valueText: nil, unit: "/min", effectiveDate: "2024-05-15", category: "vital")])
        let (_, score) = try await RunCore.runCase(
            pdfData: Data("%PDF".utf8), pages: ["Heart rate 68 /min"], model: "m", fixture: "date-before-dob",
            sample: 0, extractor: StubExtractor(json: stubJSON), expected: expected,
            subjectId: "subj", subjectDOB: LLMResponseContract.parseDate("1990-05-01"), now: Self.fixedNow)
        XCTAssertEqual(score.skipHistogram["dateBeforeDOB"], 1)
        XCTAssertLessThan(score.strict.f1, 1.0)
    }

    // With subjectDOB nil the before-DOB guard never fires, so an ancient date is kept (no skip).
    func testRunCaseNilSubjectDOBKeepsAncientDate() async throws {
        let stubJSON = """
        {"patients":[{"name":"Jane Public","dob":"1990-05-01"}],
         "observations":[{"loinc":"8867-4","display":"Heart rate","value":68,"unit":"/min",
                          "effectiveDate":"1900-01-01","category":"vital","confidence":0.9}]}
        """
        let expected = ExpectedDoc(
            patients: [ExpectedPatient(name: "Jane Public", dob: "1990-05-01")],
            observations: [ExpectedObservation(loinc: "8867-4", display: "Heart rate", value: 68,
                           valueText: nil, unit: "/min", effectiveDate: "1900-01-01", category: "vital")])
        let (_, score) = try await RunCore.runCase(
            pdfData: Data("%PDF".utf8), pages: ["Heart rate 68 /min"], model: "m", fixture: "ancient-date",
            sample: 0, extractor: StubExtractor(json: stubJSON), expected: expected,
            subjectId: "subj", subjectDOB: nil, now: Self.fixedNow)
        XCTAssertNil(score.skipHistogram["dateBeforeDOB"])
    }
}
