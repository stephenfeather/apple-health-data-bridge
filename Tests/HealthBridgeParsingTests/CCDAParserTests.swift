import XCTest
import BridgeKit
@testable import HealthBridgeParsing

#if canImport(FoundationXML) || os(macOS)
final class CCDAParserTests: XCTestCase {
    private func fixture(_ n: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(n)", withExtension: "xml")))
    }
    private func parse(_ n: String) throws -> ParseResult { try CCDAParser().parse(try fixture(n), subjectId: "s") }

    func testCanParseDetectsCCDA() throws {
        XCTAssertTrue(CCDAParser.canParse(try fixture("ccda-minimal")))
        XCTAssertFalse(CCDAParser.canParse(Data(#"{"resourceType":"Observation"}"#.utf8)))
    }
    // Error handler first: malformed XML throws, not returns empty.
    func testMalformedThrows() throws {
        XCTAssertThrowsError(try parse("ccda-malformed")) {
            guard case ParseError.malformed = $0 else { return XCTFail("expected .malformed") }
        }
    }
    func testHL7TimestampUTC() {
        // "20250319093000+0000" -> 2025-03-19T09:30:00Z = 1_742_376_600
        XCTAssertEqual(CCDAParser.date(fromHL7TS: "20250319093000+0000")?.timeIntervalSince1970 ?? -1,
                       1_742_376_600, accuracy: 1)
    }
    func testHL7DateOnlyResolvesUTCMidnight() {
        // "20250319" -> 2025-03-19T00:00:00Z = 1_742_342_400, regardless of machine TZ.
        XCTAssertEqual(CCDAParser.date(fromHL7TS: "20250319")?.timeIntervalSince1970 ?? -1,
                       1_742_342_400, accuracy: 1)
    }
    // Codex A: Calendar normalizes out-of-range components; a malformed TS must be nil (→ .noDate skip),
    // never a silently-wrong date that imports under the wrong effective date / id.
    func testRejectsOutOfRangeHL7TS() {
        XCTAssertNil(CCDAParser.date(fromHL7TS: "20251340"))        // month 13 / day 40
        XCTAssertNil(CCDAParser.date(fromHL7TS: "20250230"))        // Feb 30
        XCTAssertNil(CCDAParser.date(fromHL7TS: "20250101999900"))  // 99:99:00
    }
    func testParsesSingleVital() throws {
        let o = try XCTUnwrap(parse("ccda-minimal").observations.first { $0.code?.code == "29463-7" })
        XCTAssertEqual(o.code?.system, "http://loinc.org")
        XCTAssertEqual(o.name, "Body weight")
        XCTAssertEqual(o.value, .quantity(72.5)); XCTAssertEqual(o.unit, "kg")
        XCTAssertEqual(o.category, .vital); XCTAssertEqual(o.confidence, 1.0); XCTAssertNil(o.mapping)
        XCTAssertEqual(o.effectiveDate.timeIntervalSince1970, 1_742_376_600, accuracy: 1)
    }
    func testIdMatchesFHIRPathForSameContent() throws {
        // Same subject+LOINC+date+value+unit must yield the same id as the FHIR path (shared derive()).
        let o = try XCTUnwrap(parse("ccda-minimal").observations.first { $0.code?.code == "29463-7" })
        let expected = ObservationID.derive(subjectId: "s", system: "http://loinc.org", code: "29463-7",
                                            effectiveDate: o.effectiveDate, rawValue: "72.5", unit: "kg")
        XCTAssertEqual(o.id, expected)
    }
    // Regression (PR #1 crash): a large integral value must NOT trap String(Int(d)) and must
    // stringify via the SHARED helper identically to the FHIR path.
    func testLargeIntegralValueDoesNotTrap() throws {
        let o = try XCTUnwrap(parse("ccda-large-value").observations.first { $0.code?.code == "29463-7" })
        XCTAssertEqual(o.value, .quantity(1e20))
        // id is derived with the shared stableNumberString(1e20); compute the expected raw the same way.
        let expected = ObservationID.derive(subjectId: "s", system: "http://loinc.org", code: "29463-7",
                                            effectiveDate: o.effectiveDate, rawValue: stableNumberString(1e20), unit: "kg")
        XCTAssertEqual(o.id, expected)
    }
    func testStableNumberStringGuardsLargeIntegral() {
        // Shared single-source-of-truth helper: integral but > Int.max -> Double string, no trap.
        XCTAssertEqual(stableNumberString(1e20), String(1e20))
        XCTAssertEqual(stableNumberString(72), "72")
        XCTAssertEqual(stableNumberString(72.5), "72.5")
    }
    // MARK: multi-patient refusal (PHI-safety parity with M1)
    func testRefusesMultiplePatients() throws {
        XCTAssertThrowsError(try parse("ccda-multi-patient")) {
            guard case ParseError.malformed(let m) = $0 else { return XCTFail("expected .malformed") }
            XCTAssertTrue(m.lowercased().contains("patient"), m)
        }
    }
    func testAcceptsSinglePatient() throws {
        XCTAssertNoThrow(try parse("ccda-minimal"))   // exactly one recordTarget
    }
    // Adversarial: refusal keys on the COUNT of patients in the document, NOT the subjectId arg —
    // a 2-patient doc must refuse no matter which subject was selected (the exact cross-patient leak risk).
    func testRefusalIsIndependentOfSubjectId() throws {
        let data = try fixture("ccda-multi-patient")
        for subject in ["jane", "john", "", "anyone"] {
            XCTAssertThrowsError(try CCDAParser().parse(data, subjectId: subject)) {
                guard case ParseError.malformed = $0 else { return XCTFail("expected .malformed for subject=\(subject)") }
            }
        }
    }
    // MARK: Vital Signs — BP organizer + empty/non-LOINC handling
    func testBPOrganizerYieldsTwoMappableComponents() throws {
        let r = try parse("ccda-vitals")
        // Adversarial: exactly TWO observations — the outer organizer code 46680-4 must NOT leak in.
        XCTAssertEqual(r.observations.count, 2)
        let codes = Set(r.observations.compactMap { $0.code?.code })
        XCTAssertEqual(codes, ["8480-6", "8462-4"])
        XCTAssertFalse(codes.contains("46680-4"))
        for o in r.observations where ["8480-6", "8462-4"].contains(o.code?.code) {
            XCTAssertNotNil(MappingTable.resolve(loinc: o.code?.code, value: o.value, unit: o.unit))
        }
    }
    func testEmptySectionYieldsNothing() throws {
        let r = try parse("ccda-empty-section")
        XCTAssertEqual(r.observations.count, 0); XCTAssertEqual(r.skipped.count, 0)
    }
    func testNonLOINCCodeIsSkippedNoCode() throws {
        let r = try parse("ccda-no-loinc")
        XCTAssertEqual(r.observations.count, 0)
        XCTAssertEqual(r.skipped.first?.reason, .noCode)
    }
    // MARK: Results / Problems / Allergies
    func testParsesLabResult() throws {
        let o = try XCTUnwrap(try parse("ccda-results").observations.first { $0.code?.code == "1742-6" })
        XCTAssertEqual(o.category, .lab); XCTAssertEqual(o.value, .quantity(22)); XCTAssertEqual(o.unit, "U/L")
    }
    func testParsesProblemAsStringOther() throws {
        let o = try XCTUnwrap(try parse("ccda-problems").observations.first)
        XCTAssertEqual(o.category, .other)
        if case .string(let s) = o.value { XCTAssertEqual(s, "Hypertension") } else { XCTFail("expected .string") }
        XCTAssertNil(o.mapping)
    }
    // Codex B (safety): a negated assertion (negationInd="true", "no penicillin allergy") must NOT
    // become a positive observation — the schema has no polarity field, so emit nothing and log a skip.
    func testNegatedProblemIsSkippedNotEmitted() throws {
        let r = try parse("ccda-negated-problem")
        XCTAssertTrue(r.observations.isEmpty, "negated assertion must not be emitted as a present condition")
        XCTAssertEqual(r.skipped.first?.reason, .negated)
    }

    func testParsesAllergyAsStringOther() throws {
        let o = try XCTUnwrap(try parse("ccda-allergies").observations.first)
        XCTAssertEqual(o.category, .other)
        // ST value has no displayName -> stringValue text fallback must surface the reaction text.
        if case .string(let s) = o.value { XCTAssertEqual(s, "Penicillin - hives") } else { XCTFail("expected .string") }
    }
    func testMissingSectionsYieldsNoObservationsNoThrow() throws {
        let r = try parse("ccda-missing-sections")
        XCTAssertEqual(r.observations.count, 0); XCTAssertEqual(r.skipped.count, 0)
    }
    func testMinimalCarriesBothVitalAndResult() throws {
        let r = try parse("ccda-minimal")
        XCTAssertEqual(Set(r.observations.compactMap { $0.code?.code }), ["29463-7", "1742-6"])
        XCTAssertEqual(r.observations.first { $0.code?.code == "1742-6" }?.category, .lab)
    }
    // Regression (PR #2 review #1): a section containing a nested <section> must not double-count.
    // The top-level section's own descendant observation walk already collects subsection observations
    // exactly once; iterating the nested section separately would duplicate observations AND skips.
    func testNestedSubsectionDoesNotDuplicate() throws {
        let r = try parse("ccda-nested-section")
        let codes = r.observations.compactMap { $0.code?.code }
        XCTAssertEqual(codes.filter { $0 == "8867-4" }.count, 1, "nested heart rate must appear exactly once")
        XCTAssertEqual(codes.filter { $0 == "29463-7" }.count, 1)
        XCTAssertEqual(r.observations.count, 2)              // weight + heart rate, no dup
        XCTAssertEqual(r.skipped.count, 1)                   // the nested no-date resp rate, not double-counted
    }

    // MARK: - Plausible-date guard adoption (parity with the LLM path)
    // recordTarget DOB 2000-01-01; Vital Signs (quantitative) has weights at 1995-06-01 (before DOB),
    // 2099-01-01 (after now), 2010-05-05 (plausible); Problem List (qualitative) has 1995 + 2099. `now` pinned.
    private static let fixedNow = LLMResponseContract.parseDate("2026-06-24")!
    private func parsePinned(_ n: String) throws -> ParseResult {
        try CCDAParser(now: Self.fixedNow).parse(try fixture(n), subjectId: "s")
    }

    func testCCDADropsQuantitativeBeforeDOB() throws {   // error handler
        let r = try parsePinned("ccda-implausible-dates")
        XCTAssertFalse(r.observations.contains { $0.value == .quantity(70) },
                       "1995-06-01 vital predates DOB 2000-01-01 and must be dropped")
        XCTAssertTrue(r.skipped.contains { $0.reason == .implausibleDate && $0.detail == .dateBeforeDOB })
    }
    func testCCDADropsQuantitativeAfterNow() throws {   // error handler
        let r = try parsePinned("ccda-implausible-dates")
        XCTAssertFalse(r.observations.contains { $0.value == .quantity(71) },
                       "2099-01-01 vital is after now and must be dropped")
        XCTAssertTrue(r.skipped.contains { $0.reason == .implausibleDate && $0.detail == .dateAfterNow })
    }
    func testCCDADropsQualitativeImplausible() throws {   // error handler (qualitative path)
        let r = try parsePinned("ccda-implausible-dates")
        // The two Hypertension problems (1995 before DOB, 2099 after now) must be dropped.
        XCTAssertFalse(r.observations.contains { $0.value == .string("Hypertension") },
                       "implausible-date Hypertension problems must be dropped")
        XCTAssertEqual(r.skipped.filter {
            $0.reason == .implausibleDate && ($0.detail == .dateBeforeDOB || $0.detail == .dateAfterNow)
        }.count, 4, "2 quantitative + 2 qualitative implausible-date drops")
    }
    func testCCDAKeepsPlausibleObservation() throws {   // happy path (quantitative)
        let r = try parsePinned("ccda-implausible-dates")
        XCTAssertEqual(r.observations.count, 2, "one plausible vital + one plausible qualitative")
        XCTAssertTrue(r.observations.contains { $0.value == .quantity(72) },
                      "2010-05-05 quantitative vital must be kept")
    }
    func testCCDAKeepsPlausibleQualitativeObservation() throws {   // happy path (qualitative)
        let r = try parsePinned("ccda-implausible-dates")
        XCTAssertTrue(r.observations.contains { $0.value == .string("Migraine") },
                      "2025-03-19 qualitative Migraine observation must be kept (plausible date)")
    }
}
#endif
