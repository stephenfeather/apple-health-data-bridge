import Foundation
import BridgeKit
import HealthBridgeParsing

/// PURE matcher (design §6). Identity = (loinc, effectiveDate at UTC calendar day). Matched pairs are
/// graded field-by-field with EXACT numeric equality (design §13.1). Platform-free — no PDFKit — so it
/// unit-tests everywhere. `.missedRejected` is assigned by the Scorer (it needs the skip list); the
/// Matcher only distinguishes hit/partial/hallucinated/missedAbsent over VALID predictions vs gold.
///
/// DATE PARSING is delegated to `LLMResponseContract.parseDate` — the SAME parser the production decoder
/// uses for `Observation.effectiveDate` — so an offset timestamp in a fixture and a date-only decoded
/// observation reduce to the SAME UTC day (premortem Fix 1). No ISO8601DateFormatter here.
enum Matcher {
    private static let secondsPerDay = 86_400.0

    static func utcDay(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / secondsPerDay).rounded(.down))
    }

    private struct Key: Hashable { let loinc: String; let day: Int }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func gradeValue(predicted: ObservationValue, expected: ExpectedObservation) -> Bool {
        switch predicted {
        case .quantity(let q):
            guard let want = expected.value else { return false }   // expected qualitative, got numeric
            return q == want                                         // EXACT (design §13.1)
        case .string(let s):
            guard let want = expected.valueText else { return false }
            return normalize(s) == normalize(want)
        }
    }

    /// True iff this predicted obs grades as a FULL exact match against `e` (value + unit + category all
    /// correct). The date is already pinned by the shared identity key, so it never contributes an error.
    private static func isExactMatch(_ p: Observation, _ e: ExpectedObservation) -> Bool {
        gradeValue(predicted: p.value, expected: e)
            && (p.unit ?? "") == (e.unit ?? "")
            && p.category.rawValue == e.category
    }

    static func match(predicted: [Observation], expected: [ExpectedObservation]) -> [MatchRecord] {
        // Index expected by identity. Multiple expected entries may share a (loinc, UTC day) key, so each
        // key holds ALL candidates (Finding 1) — overwriting would silently drop duplicates. An expected
        // date the production parser rejects drops out of the index (it can only ever be a miss).
        var expectedByKey: [Key: [ExpectedObservation]] = [:]
        for e in expected {
            guard let d = LLMResponseContract.parseDate(e.effectiveDate) else { continue }
            let k = Key(loinc: e.loinc, day: utcDay(d))
            expectedByKey[k, default: []].append(e)
        }

        var records: [MatchRecord] = []
        for p in predicted {
            let loinc = p.code?.code ?? ""
            let k = Key(loinc: loinc, day: utcDay(p.effectiveDate))
            guard var candidates = expectedByKey[k], !candidates.isEmpty else {
                records.append(MatchRecord(loinc: loinc, outcome: .hallucinated, fieldErrors: nil))
                continue
            }
            // Prefer a candidate that grades as a full exact match; otherwise take the first. The chosen
            // candidate is consumed so a later prediction can't reuse it.
            let chosenIndex = candidates.firstIndex(where: { isExactMatch(p, $0) }) ?? candidates.startIndex
            let e = candidates.remove(at: chosenIndex)
            if candidates.isEmpty { expectedByKey[k] = nil } else { expectedByKey[k] = candidates }

            let valueWrong = !gradeValue(predicted: p.value, expected: e)
            let unitWrong = (p.unit ?? "") != (e.unit ?? "")
            let categoryWrong = p.category.rawValue != e.category
            let dateWrong = false   // identity already pins the UTC day; matched pairs share it
            if !valueWrong && !unitWrong && !categoryWrong && !dateWrong {
                records.append(MatchRecord(loinc: loinc, outcome: .hit, fieldErrors: nil))
            } else {
                records.append(MatchRecord(loinc: loinc, outcome: .partial,
                    fieldErrors: FieldErrors(value: valueWrong, unit: unitWrong,
                                             category: categoryWrong, date: dateWrong)))
            }
        }

        // Every gold candidate left unconsumed across all keys is one missed-absent record.
        for (k, leftovers) in expectedByKey {
            for _ in leftovers {
                records.append(MatchRecord(loinc: k.loinc, outcome: .missedAbsent, fieldErrors: nil))
            }
        }
        return records
    }
}
