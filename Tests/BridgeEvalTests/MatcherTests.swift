import XCTest
import BridgeKit
import HealthBridgeParsing
@testable import bridge_eval

final class MatcherTests: XCTestCase {
    // Same parser the matcher and production decoder use — one source of truth.
    private func date(_ s: String) -> Date {
        LLMResponseContract.parseDate(s)!
    }

    private func observation(loinc: String, value: ObservationValue, unit: String?,
                             date s: String, category: ObservationCategory) -> Observation {
        Observation(id: "id-\(loinc)-\(s)",
                    code: CodeableRef(system: "http://loinc.org", code: loinc, display: loinc),
                    name: loinc, value: value, unit: unit, effectiveDate: date(s),
                    category: category, mapping: nil, confidence: 1.0, sourceLocator: nil)
    }

    private func expected(loinc: String, value: Double?, valueText: String?, unit: String?,
                          date: String, category: String) -> ExpectedObservation {
        ExpectedObservation(loinc: loinc, display: loinc, value: value, valueText: valueText,
                            unit: unit, effectiveDate: date, category: category)
    }

    func testUnparseableExpectedDateNeverMatches() {
        // A garbage expected date drops out of the index -> the prediction can only hallucinate.
        let preds = [observation(loinc: "8867-4", value: .quantity(72), unit: "/min",
                                 date: "2024-01-15", category: .vital)]
        let exp = [expected(loinc: "8867-4", value: 72, valueText: nil, unit: "/min",
                            date: "not-a-date", category: "vital")]
        let records = Matcher.match(predicted: preds, expected: exp)
        XCTAssertEqual(records.map { $0.outcome }, [.hallucinated])
    }

    func testUnmatchedPredictedIsHallucinated() {
        let preds = [observation(loinc: "8867-4", value: .quantity(72), unit: "/min",
                                 date: "2024-01-15", category: .vital)]
        let records = Matcher.match(predicted: preds, expected: [])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.outcome, .hallucinated)
    }

    func testUnmatchedExpectedIsMissedAbsent() {
        let exp = [expected(loinc: "8867-4", value: 72, valueText: nil, unit: "/min",
                            date: "2024-01-15", category: "vital")]
        let records = Matcher.match(predicted: [], expected: exp)
        XCTAssertEqual(records.first?.outcome, .missedAbsent)
    }

    func testExactMatchIsHit() {
        let preds = [observation(loinc: "8867-4", value: .quantity(72), unit: "/min",
                                 date: "2024-01-15", category: .vital)]
        let exp = [expected(loinc: "8867-4", value: 72, valueText: nil, unit: "/min",
                            date: "2024-01-15", category: "vital")]
        let records = Matcher.match(predicted: preds, expected: exp)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.outcome, .hit)
        XCTAssertNil(records.first?.fieldErrors)
    }

    func testOffsetTimestampLandsOnSameUTCDayAsDateOnly() {
        // A fixture timestamp with an offset must reduce to the SAME UTC day as the decoded
        // observation's date-only value — the whole point of unifying on parseDate (Fix 1).
        let preds = [observation(loinc: "8867-4", value: .quantity(72), unit: "/min",
                                 date: "2024-01-15", category: .vital)]
        let exp = [expected(loinc: "8867-4", value: 72, valueText: nil, unit: "/min",
                            date: "2024-01-15T08:00:00+00:00", category: "vital")]
        let records = Matcher.match(predicted: preds, expected: exp)
        XCTAssertEqual(records.first?.outcome, .hit)
    }

    func testRoundingSlipIsPartialNotHit() {
        // 72.4 vs 72.5 — exact grading => Partial, not Hit (design §13.1).
        let preds = [observation(loinc: "8867-4", value: .quantity(72.4), unit: "/min",
                                 date: "2024-01-15", category: .vital)]
        let exp = [expected(loinc: "8867-4", value: 72.5, valueText: nil, unit: "/min",
                            date: "2024-01-15", category: "vital")]
        let records = Matcher.match(predicted: preds, expected: exp)
        XCTAssertEqual(records.first?.outcome, .partial)
        XCTAssertEqual(records.first?.fieldErrors?.value, true)
        XCTAssertEqual(records.first?.fieldErrors?.unit, false)
    }

    func testWrongUnitIsPartial() {
        let preds = [observation(loinc: "718-7", value: .quantity(13), unit: "g/L",
                                 date: "2024-01-15", category: .lab)]
        let exp = [expected(loinc: "718-7", value: 13, valueText: nil, unit: "g/dL",
                            date: "2024-01-15", category: "lab")]
        let records = Matcher.match(predicted: preds, expected: exp)
        XCTAssertEqual(records.first?.outcome, .partial)
        XCTAssertEqual(records.first?.fieldErrors?.unit, true)
        XCTAssertEqual(records.first?.fieldErrors?.value, false)
    }

    func testQualitativeValueNormalizedEquality() {
        let preds = [observation(loinc: "5778-6", value: .string("  Yellow  "), unit: nil,
                                 date: "2024-01-15", category: .lab)]
        let exp = [expected(loinc: "5778-6", value: nil, valueText: "yellow", unit: nil,
                            date: "2024-01-15", category: "lab")]
        let records = Matcher.match(predicted: preds, expected: exp)
        XCTAssertEqual(records.first?.outcome, .hit)
    }

    func testSameLoincDifferentDayDoesNotMatch() {
        let preds = [observation(loinc: "8867-4", value: .quantity(72), unit: "/min",
                                 date: "2024-01-15", category: .vital)]
        let exp = [expected(loinc: "8867-4", value: 72, valueText: nil, unit: "/min",
                            date: "2024-01-16", category: "vital")]
        let records = Matcher.match(predicted: preds, expected: exp)
        XCTAssertEqual(Set(records.map { $0.outcome }), [.hallucinated, .missedAbsent])
    }
}
