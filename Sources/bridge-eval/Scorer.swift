import Foundation
import BridgeKit
import HealthBridgeParsing

/// PURE scorer (design §6). Folds Matcher output together with the contract's skip list into a
/// `CaseScore`: strict F1 (hits only) headline, lenient F1 (partials = ½) secondary, a skip-detail
/// histogram, and patient-extraction correctness. Platform-free — no PDFKit.
enum Scorer {
    /// Histogram key: structured `detail` when present, else a `reason:` fallback (design §8).
    static func skipDetailKey(_ skip: Skip) -> String {
        guard let detail = skip.detail else { return "reason:\(skip.reason)" }
        switch detail {
        case .bothValueAndText: return "bothValueAndText"
        case .noUsableValue: return "noUsableValue"
        case .nonFiniteValue: return "nonFiniteValue"
        case .confidenceOutOfRange(let got): return "confidenceOutOfRange(\(got))"
        case .dateMalformed: return "dateMalformed"
        case .dateBeforeDOB: return "dateBeforeDOB"
        case .dateAfterNow: return "dateAfterNow"
        case .missingCode: return "missingCode"
        }
    }

    static func catastrophic(fixture: String, model: String, sample: Int) -> CaseScore {
        let zero = F1(precision: 0, recall: 0, f1: 0)
        return CaseScore(fixture: fixture, model: model, sample: sample, catastrophic: true,
                         strict: zero, lenient: zero, skipHistogram: [:], matches: [],
                         patient: PatientCorrectness(distinctCountCorrect: false, identityCorrect: false))
    }

    static func score(fixture: String, model: String, sample: Int,
                      result: ParseResult, expected: ExpectedDoc,
                      extractedPatient: (name: String, dob: String)?,
                      distinctPatientCount: Int) -> CaseScore {
        var matches = Matcher.match(predicted: result.observations, expected: expected.observations)

        // A skip that references an expected observation reclassifies that miss: absent -> rejected.
        let rejectedLoincs = rejectedLoincSet(result.skipped, expected: expected.observations)
        matches = matches.map { record in
            guard record.outcome == .missedAbsent, rejectedLoincs.contains(record.loinc) else { return record }
            return MatchRecord(loinc: record.loinc, outcome: .missedRejected, fieldErrors: nil)
        }

        var histogram: [String: Int] = [:]
        for skip in result.skipped { histogram[skipDetailKey(skip), default: 0] += 1 }

        let strict = f1(matches: matches, partialWeight: 0.0)
        let lenient = f1(matches: matches, partialWeight: 0.5)

        let patient = patientCorrectness(expected: expected.patients,
                                         extracted: extractedPatient,
                                         distinctCount: distinctPatientCount)

        return CaseScore(fixture: fixture, model: model, sample: sample, catastrophic: false,
                         strict: strict, lenient: lenient, skipHistogram: histogram,
                         matches: matches, patient: patient)
    }

    // MARK: - Helpers

    /// Best-effort DIAGNOSTIC linkage; does not affect F1. Production sets a skip's `label` to
    /// `dto.display ?? dto.loinc ?? "Unknown"` (LLMResponseContract.mapEntry), so when the model emits a
    /// display name the LOINC is NOT in the label. Match an expected observation when the skip label
    /// contains EITHER its loinc OR its display/name string (premortem Fix 2).
    private static func rejectedLoincSet(_ skipped: [Skip], expected: [ExpectedObservation]) -> Set<String> {
        var hit = Set<String>()
        for skip in skipped {
            let label = skip.label
            for e in expected {
                let display = e.display ?? ""
                if label.contains(e.loinc) || (!display.isEmpty && label.contains(display)) {
                    hit.insert(e.loinc)
                }
            }
        }
        return hit
    }

    private static func f1(matches: [MatchRecord], partialWeight: Double) -> F1 {
        let hits = Double(matches.filter { $0.outcome == .hit }.count)
        let partials = Double(matches.filter { $0.outcome == .partial }.count)
        let predictedValid = Double(matches.filter { $0.outcome == .hit || $0.outcome == .partial || $0.outcome == .hallucinated }.count)
        let expectedTotal = Double(matches.filter { $0.outcome == .hit || $0.outcome == .partial || $0.outcome == .missedAbsent || $0.outcome == .missedRejected }.count)
        let credit = hits + partialWeight * partials
        let precision = predictedValid == 0 ? 0 : credit / predictedValid
        let recall = expectedTotal == 0 ? 0 : credit / expectedTotal
        let denom = precision + recall
        let f1 = denom == 0 ? 0 : 2 * precision * recall / denom
        return F1(precision: precision, recall: recall, f1: f1)
    }

    private static func patientCorrectness(expected: [ExpectedPatient],
                                           extracted: (name: String, dob: String)?,
                                           distinctCount: Int) -> PatientCorrectness {
        let expectedCount = Set(expected.map { "\($0.name.lowercased())|\($0.dob.lowercased())" }).count
        let countCorrect = distinctCount == expectedCount
        let identityCorrect: Bool
        if let e = expected.first, let got = extracted {
            identityCorrect = got.name.lowercased() == e.name.lowercased()
                && got.dob.lowercased() == e.dob.lowercased()
        } else {
            identityCorrect = expected.isEmpty && extracted == nil
        }
        return PatientCorrectness(distinctCountCorrect: countCorrect, identityCorrect: identityCorrect)
    }
}
