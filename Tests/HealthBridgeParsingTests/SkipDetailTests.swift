import XCTest
import BridgeKit
@testable import HealthBridgeParsing

/// Issue #5 — structured `Skip.Detail`. Asserts each `mapEntry` rejection site in
/// `LLMResponseContract.decode` populates the right `detail` (additive observability), and that
/// `detail` defaults nil everywhere it is not set (FHIR/C-CDA paths, success entries).
/// All JSON is synthetic (Jane Public / John Sample).
final class SkipDetailTests: XCTestCase {

    private static let dobJane = LLMResponseContract.parseDate("2000-01-01")!
    private static let fixedNow = LLMResponseContract.parseDate("2026-06-24")!

    /// Single-observation envelope with overridable fields (defaults form a VALID entry).
    private func obs(loinc: String = "29463-7",
                     value: String = "72.5",
                     valueText: String? = nil,
                     effectiveDate: String? = "2024-03-15",
                     confidence: String = "0.9") -> String {
        var fields: [String] = []
        fields.append(#""loinc":"\#(loinc)""#)
        fields.append(#""display":"Body weight""#)
        if value != "null" { fields.append(#""value":\#(value)"#) } else { fields.append(#""value":null"#) }
        if let valueText { fields.append(#""valueText":"\#(valueText)""#) }
        fields.append(#""unit":"kg""#)
        if let effectiveDate { fields.append(#""effectiveDate":"\#(effectiveDate)""#) }
        else { fields.append(#""effectiveDate":null"#) }
        fields.append(#""category":"vital""#)
        fields.append(#""confidence":\#(confidence)"#)
        return #"{"observations":[{"# + fields.joined(separator: ",") + #"}]}"#
    }

    private func decodeFirstSkip(_ json: String) throws -> Skip {
        let r = try LLMResponseContract.decode(json, subjectId: "s",
                                               subjectDOB: Self.dobJane, now: Self.fixedNow)
        XCTAssertEqual(r.observations.count, 0, "fixture should reject")
        return try XCTUnwrap(r.skipped.first)
    }

    // MARK: - 1. Missing code -> .noCode / .missingCode

    func testMissingCodeDetail() throws {
        let s = try decodeFirstSkip(obs(loinc: ""))
        XCTAssertEqual(s.reason, .noCode)
        XCTAssertEqual(s.detail, .missingCode)
    }

    // MARK: - 2. Malformed date -> .noDate / .dateMalformed

    func testMalformedDateDetail() throws {
        // Feb 30 is out-of-range and must be rejected (not normalized).
        let s = try decodeFirstSkip(obs(effectiveDate: "2000-02-30"))
        XCTAssertEqual(s.reason, .noDate)
        XCTAssertEqual(s.detail, .dateMalformed)
    }

    func testNullDateDetail() throws {
        let s = try decodeFirstSkip(obs(effectiveDate: nil))
        XCTAssertEqual(s.reason, .noDate)
        XCTAssertEqual(s.detail, .dateMalformed)
    }

    // MARK: - 3a. Date before DOB -> .implausibleDate / .dateBeforeDOB

    func testDateBeforeDOBDetail() throws {
        let s = try decodeFirstSkip(obs(effectiveDate: "1995-06-01"))
        XCTAssertEqual(s.reason, .implausibleDate)
        XCTAssertEqual(s.detail, .dateBeforeDOB)
        // label string must be UNCHANGED by the detail addition
        XCTAssertEqual(s.label, "Body weight [implausible date: 1995-06-01 before DOB 2000-01-01]")
    }

    // MARK: - 3b. Date after now -> .implausibleDate / .dateAfterNow

    func testDateAfterNowDetail() throws {
        let s = try decodeFirstSkip(obs(effectiveDate: "2030-01-01"))
        XCTAssertEqual(s.reason, .implausibleDate)
        XCTAssertEqual(s.detail, .dateAfterNow)
        XCTAssertEqual(s.label, "Body weight [implausible date: 2030-01-01 after 2026-06-24]")
    }

    // MARK: - 4a. Both value & valueText -> .unrepresentableValue / .bothValueAndText

    func testBothValueAndTextDetail() throws {
        let s = try decodeFirstSkip(obs(valueText: "positive"))
        XCTAssertEqual(s.reason, .unrepresentableValue)
        XCTAssertEqual(s.detail, .bothValueAndText)
        XCTAssertEqual(s.label, "Body weight [rejected: both value and valueText present]")
    }

    // MARK: - 4b. Non-finite numeric value -> .unrepresentableValue / .nonFiniteValue

    /// The `.nonFiniteValue` branch is a DEFENSIVE belt-and-suspenders guard: Foundation's JSONDecoder
    /// rejects any overflowing/non-representable number (e.g. `1e400`) as malformed JSON BEFORE it can
    /// surface as a non-finite `Double`, so the branch is unreachable through `decode(...)` with valid
    /// JSON. Pin the defensive path at the `resolveValue` seam instead (and confirm the malformed-number
    /// JSON is rejected upstream as `ParseError.malformed`, never silently kept).
    func testNonFiniteValueResolvesToNonFiniteOutcome() {
        XCTAssertEqual(LLMResponseContract.resolveValueForTesting(.infinity), .nonFinite)
        XCTAssertEqual(LLMResponseContract.resolveValueForTesting(.nan), .nonFinite)
        // and a finite value still resolves OK (regression guard for the split)
        if case .ok = LLMResponseContract.resolveValueForTesting(72.5) {} else {
            XCTFail("finite value must resolve to .ok")
        }
    }

    func testOverflowingNumberRejectedAsMalformedJSON() {
        let json = #"{"observations":[{"loinc":"29463-7","display":"Body weight","value":1e400,"unit":"kg","effectiveDate":"2024-03-15","category":"vital","confidence":0.9}]}"#
        XCTAssertThrowsError(try LLMResponseContract.decode(json, subjectId: "s")) {
            guard case ParseError.malformed = $0 else { return XCTFail("expected .malformed") }
        }
    }

    // MARK: - 4c. No usable value -> .unrepresentableValue / .noUsableValue

    func testNoUsableValueDetail() throws {
        // value null AND no (non-empty) valueText.
        let s = try decodeFirstSkip(obs(value: "null"))
        XCTAssertEqual(s.reason, .unrepresentableValue)
        XCTAssertEqual(s.detail, .noUsableValue)
    }

    func testNoUsableValueWhenValueTextBlankDetail() throws {
        // value null, valueText present but whitespace-only -> still no usable value.
        let s = try decodeFirstSkip(obs(value: "null", valueText: "   "))
        XCTAssertEqual(s.reason, .unrepresentableValue)
        XCTAssertEqual(s.detail, .noUsableValue)
    }

    // MARK: - 4d. Confidence out of range -> .unrepresentableValue / .confidenceOutOfRange(got:)

    func testConfidenceTooHighDetail() throws {
        let s = try decodeFirstSkip(obs(confidence: "1.5"))
        XCTAssertEqual(s.reason, .unrepresentableValue)
        XCTAssertEqual(s.detail, .confidenceOutOfRange(got: "1.5"))
        XCTAssertEqual(s.label, "Body weight [rejected: confidence 1.5 not in 0...1]")
    }

    func testConfidenceMissingDetail() throws {
        // omit confidence entirely -> got == "missing"
        let json = #"{"observations":[{"loinc":"29463-7","display":"Body weight","value":72.5,"unit":"kg","effectiveDate":"2024-03-15","category":"vital"}]}"#
        let s = try decodeFirstSkip(json)
        XCTAssertEqual(s.reason, .unrepresentableValue)
        XCTAssertEqual(s.detail, .confidenceOutOfRange(got: "missing"))
    }

    // MARK: - Success entry leaves detail unset (nil) and is otherwise unchanged

    func testSuccessEntryHasNoSkipAndUnchanged() throws {
        let r = try LLMResponseContract.decode(obs(), subjectId: "s",
                                               subjectDOB: Self.dobJane, now: Self.fixedNow)
        XCTAssertEqual(r.observations.count, 1)
        XCTAssertEqual(r.skipped.count, 0)
        XCTAssertEqual(r.observations.first?.category, .vital)
    }

    // MARK: - Non-LLM parser Skips default detail to nil (additive, no behavior change)

    func testDocumentParserSkipDefaultsDetailNil() {
        let s = Skip(reason: .noCode, label: "x")
        XCTAssertNil(s.detail)
    }

    func testSkipEquatableIgnoresNothingAndIncludesDetail() {
        // Equatable is auto-synthesized over (reason, label, detail).
        let a = Skip(reason: .unrepresentableValue, label: "L", detail: .noUsableValue)
        let b = Skip(reason: .unrepresentableValue, label: "L", detail: .noUsableValue)
        let c = Skip(reason: .unrepresentableValue, label: "L", detail: .nonFiniteValue)
        let d = Skip(reason: .unrepresentableValue, label: "L")   // detail nil
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, d)
    }
}
