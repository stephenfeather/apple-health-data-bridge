import XCTest
import BridgeKit
import HealthBridgeParsing
@testable import bridge_eval

final class ScorerTests: XCTestCase {
    private func date(_ s: String) -> Date { LLMResponseContract.parseDate(s)! }
    private func obs(_ loinc: String, _ value: Double, _ unit: String, _ s: String) -> Observation {
        Observation(id: "id-\(loinc)", code: CodeableRef(system: "http://loinc.org", code: loinc, display: loinc),
                    name: loinc, value: .quantity(value), unit: unit, effectiveDate: date(s),
                    category: .vital, mapping: nil, confidence: 1.0, sourceLocator: nil)
    }
    private func exp(_ loinc: String, _ value: Double, _ unit: String, _ s: String,
                     display: String? = nil) -> ExpectedObservation {
        ExpectedObservation(loinc: loinc, display: display ?? loinc, value: value, valueText: nil, unit: unit,
                            effectiveDate: s, category: "vital")
    }

    func testCatastrophicIsAllZero() {
        let s = Scorer.catastrophic(fixture: "f", model: "m", sample: 2)
        XCTAssertTrue(s.catastrophic)
        XCTAssertEqual(s.strict.f1, 0)
        XCTAssertEqual(s.lenient.f1, 0)
        XCTAssertEqual(s.sample, 2)
    }

    func testSkipDetailKeyPrefersDetail() {
        let withDetail = Skip(reason: .unrepresentableValue, label: "x", detail: .noUsableValue)
        XCTAssertEqual(Scorer.skipDetailKey(withDetail), "noUsableValue")
        let confidence = Skip(reason: .unrepresentableValue, label: "x", detail: .confidenceOutOfRange(got: "1.5"))
        XCTAssertEqual(Scorer.skipDetailKey(confidence), "confidenceOutOfRange(1.5)")
        let noDetail = Skip(reason: .noDate, label: "x", detail: nil)
        XCTAssertEqual(Scorer.skipDetailKey(noDetail), "reason:noDate")
    }

    func testPerfectExtractionScoresF1One() {
        let result = ParseResult(observations: [obs("8867-4", 72, "/min", "2024-01-15")], skipped: [])
        let expected = ExpectedDoc(patients: [], observations: [exp("8867-4", 72, "/min", "2024-01-15")])
        let s = Scorer.score(fixture: "f", model: "m", sample: 0, result: result, expected: expected,
                             extractedPatient: nil, distinctPatientCount: 0)
        XCTAssertEqual(s.strict.f1, 1.0)
        XCTAssertEqual(s.matches.first?.outcome, .hit)
        XCTAssertFalse(s.catastrophic)
    }

    func testSkipHistogramCountsDetails() {
        let skip = Skip(reason: .unrepresentableValue, label: "Glucose", detail: .noUsableValue)
        let result = ParseResult(observations: [], skipped: [skip, skip])
        let expected = ExpectedDoc(patients: [], observations: [])
        let s = Scorer.score(fixture: "f", model: "m", sample: 0, result: result, expected: expected,
                             extractedPatient: nil, distinctPatientCount: 0)
        XCTAssertEqual(s.skipHistogram["noUsableValue"], 2)
    }

    func testMissedAbsentBecomesMissedRejectedViaDisplayName() {
        // PRODUCTION shape: label is the display name only (`dto.display ?? dto.loinc ?? "Unknown"`),
        // so the LOINC is NOT in the label. The linkage must still match on the expected display string.
        let skip = Skip(reason: .unrepresentableValue, label: "Heart rate", detail: .noUsableValue)
        let result = ParseResult(observations: [], skipped: [skip])
        let expected = ExpectedDoc(patients: [], observations: [
            exp("8867-4", 72, "/min", "2024-01-15", display: "Heart rate")])
        let s = Scorer.score(fixture: "f", model: "m", sample: 0, result: result, expected: expected,
                             extractedPatient: nil, distinctPatientCount: 0)
        XCTAssertEqual(s.matches.first?.outcome, .missedRejected)
    }

    func testMissedAbsentBecomesMissedRejectedViaLoincInLabel() {
        // Some reasons append the loinc (e.g. implausible-date labels); the loinc branch still links.
        let skip = Skip(reason: .implausibleDate, label: "8867-4 [dateAfterNow]", detail: .dateAfterNow)
        let result = ParseResult(observations: [], skipped: [skip])
        let expected = ExpectedDoc(patients: [], observations: [
            exp("8867-4", 72, "/min", "2024-01-15", display: "Heart rate")])
        let s = Scorer.score(fixture: "f", model: "m", sample: 0, result: result, expected: expected,
                             extractedPatient: nil, distinctPatientCount: 0)
        XCTAssertEqual(s.matches.first?.outcome, .missedRejected)
    }

    func testLenientF1CreditsPartialAsHalf() {
        // One partial (wrong unit) and one expected = recall_lenient 0.5.
        let result = ParseResult(observations: [obs("718-7", 13, "g/L", "2024-01-15")], skipped: [])
        let expected = ExpectedDoc(patients: [], observations: [
            ExpectedObservation(loinc: "718-7", display: "Hb", value: 13, valueText: nil, unit: "g/dL",
                                effectiveDate: "2024-01-15", category: "vital")])
        let s = Scorer.score(fixture: "f", model: "m", sample: 0, result: result, expected: expected,
                             extractedPatient: nil, distinctPatientCount: 0)
        XCTAssertEqual(s.strict.f1, 0.0)
        XCTAssertEqual(s.lenient.precision, 0.5)
        XCTAssertEqual(s.lenient.recall, 0.5)
    }

    func testPatientCorrectness() {
        let expected = ExpectedDoc(patients: [ExpectedPatient(name: "Jane Public", dob: "1990-05-01")],
                                   observations: [])
        let s = Scorer.score(fixture: "f", model: "m", sample: 0,
                             result: ParseResult(observations: [], skipped: []), expected: expected,
                             extractedPatient: (name: "Jane Public", dob: "1990-05-01"),
                             distinctPatientCount: 1)
        XCTAssertTrue(s.patient.distinctCountCorrect)
        XCTAssertTrue(s.patient.identityCorrect)
    }
}
