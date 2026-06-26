import Foundation
import BridgeKit

/// Validating decoder for the model's JSON reply — the security-critical heart of M3.
///
/// LLM output is UNTRUSTED even though each adapter forces JSON natively (D2 belt-and-suspenders):
/// this decoder rejects malformed JSON, drops entries missing a usable code/date/value (recording a
/// `Skip` with the existing reasons), and REJECTS entries whose `confidence` is outside `0...1`
/// (never silently clamped). Valid entries map into the same schema the FHIR/C-CDA parsers produce,
/// using the SAME id derivation (`ObservationID.derive` + shared `stableNumberString`) so identical
/// clinical content dedupes across all three paths.
public enum LLMResponseContract {

    /// Top-level contract envelope. `patients` is parsed for the Task 6 single-subject check.
    private struct Envelope: Decodable {
        let patients: [PatientDTO]?
        let observations: [ObservationDTO]?
    }
    private struct PatientDTO: Decodable { let name: String?; let dob: String? }
    private struct ObservationDTO: Decodable {
        let loinc: String?
        let display: String?
        let value: Double?
        let valueText: String?
        let unit: String?
        let effectiveDate: String?
        let category: String?
        let confidence: Double?
        let page: Int?
        let snippet: String?
    }

    private static let loincSystem = "http://loinc.org"

    /// JSON Schema for the response envelope — the single source of truth for the response SHAPE,
    /// shared by every `LLMExtractor` adapter (Anthropic structured outputs, OpenAI json_schema). It
    /// lives here, on the decoder that validates the JSON it describes, rather than on either provider
    /// struct (neither owns the contract). Within structured-output limits: `additionalProperties:
    /// false` and every object key in `required` (optional fields are nullable types instead). No
    /// `minLength`/`maximum`/`minimum`/`multipleOf` (range validation stays in the decoder), no
    /// recursion. Shape only — the decoder enforces confidence 0...1, date validity, code/value rules.
    static let contractSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["patients", "observations"],
        "properties": [
            "patients": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["name", "dob"],
                    "properties": [
                        "name": ["type": "string"],
                        "dob": ["type": "string"],
                    ],
                ],
            ],
            "observations": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["loinc", "display", "value", "valueText", "unit",
                                 "effectiveDate", "category", "confidence", "page", "snippet"],
                    "properties": [
                        "loinc": ["type": "string"],
                        "display": ["type": "string"],
                        "value": ["type": ["number", "null"]],
                        "valueText": ["type": ["string", "null"]],
                        "unit": ["type": ["string", "null"]],
                        // Nullable so a model can honestly signal a MISSING date as null (→ decoder
                        // Skip(.noDate)) instead of being forced by a required+non-nullable field to
                        // FABRICATE one (observed: gpt-4.1/gpt-5.5 invented a DOB/today's date on a
                        // dateless PDF; claude-opus-4-8 emitted ""). Kept in `required`. Uses the same
                        // `["<t>","null"]` type-union form as the other 5 optionals — both Anthropic and
                        // OpenAI accept it (confirmed via live smoke), so the contract is uniform.
                        "effectiveDate": ["type": ["string", "null"]],
                        "category": ["type": "string"],
                        "confidence": ["type": "number"],
                        "page": ["type": ["integer", "null"]],
                        "snippet": ["type": ["string", "null"]],
                    ],
                ],
            ],
        ],
    ]

    private enum MapResult { case success(Observation); case failure(Skip) }

    /// Decode + validate the contract JSON into `[Observation]` + `[Skip]`.
    /// Throws `ParseError.malformed` on non-JSON / wrong top-level shape.
    ///
    /// `subjectDOB` (the bound subject's VERIFIED roster DOB, not the model's untrusted patients[].dob)
    /// and `now` drive the plausible-date guard: an effectiveDate strictly before DOB or strictly after
    /// `now` is rejected as `Skip(.implausibleDate)` — catching a model that fabricates/borrows a date.
    public static func decode(_ jsonText: String, subjectId: String,
                              subjectDOB: Date? = nil, now: Date = Date()) throws -> ParseResult {
        let env = try decodeEnvelope(jsonText)
        var observations: [Observation] = []
        var skipped: [Skip] = []
        for dto in env.observations ?? [] {
            switch mapEntry(dto, subjectId: subjectId, subjectDOB: subjectDOB, now: now) {
            case .success(let o): observations.append(o)
            case .failure(let s): skipped.append(s)
            }
        }
        return ParseResult(observations: observations, skipped: skipped)
    }

    /// Number of DISTINCT patients reported in the response's top-level `patients[]` (D4).
    /// The PDF path's only multi-patient signal — `PDFExtractor` refuses when this exceeds 1
    /// (single-subject binding parity with the FHIR/C-CDA paths). Identical or absent patient info
    /// collapses to ≤1; two distinct (name-token + dob) identities count as 2. Throws
    /// `ParseError.malformed` on non-JSON (same as `decode`).
    public static func distinctPatientCount(_ jsonText: String) throws -> Int {
        let env = try decodeEnvelope(jsonText)
        return Set((env.patients ?? []).compactMap(patientKey)).count
    }

    /// The single patient reported in the response (when distinct-count ≤ 1, enforced by the caller's
    /// multi-patient refusal). The CLI compares this — UNTRUSTED, model-extracted — identity against
    /// the bound subject (the best available document-identity signal for an opaque PDF). `nil` when the
    /// response reports no patient. Empty name/dob propagate (→ the comparator's `.incomplete`).
    ///
    /// We return the first IDENTIFIABLE patient — the first for which `patientKey` is non-nil (has a
    /// name token OR a non-empty dob) — rather than blindly `patients.first`. A model that emits a BLANK
    /// placeholder (`{"name":"","dob":""}`) BEFORE a real, mismatched identity would otherwise mask that
    /// identity: `distinctPatientCount` ignores the blank (multi-patient refusal passes) while
    /// `patients.first` surfaced the blank, downgrading the comparator from `.mismatch` (→ `--force`) to
    /// `.incomplete` (→ weaker `--allow-unverified-subject`). Because `PDFExtractor` already refuses when
    /// `distinctPatientCount > 1`, there is at most ONE keyed identity here, so "first identifiable" is
    /// unambiguous. When every entry is blank/unkeyed we fall back to the first entry's (name, dob) —
    /// i.e. ("",""), preserving the conservative `.incomplete` classification.
    public static func extractedPatient(_ jsonText: String) throws -> (name: String, dob: String)? {
        let env = try decodeEnvelope(jsonText)
        let patients = env.patients ?? []
        guard let chosen = patients.first(where: { patientKey($0) != nil }) ?? patients.first else {
            return nil
        }
        return (chosen.name ?? "", chosen.dob ?? "")
    }

    private static func decodeEnvelope(_ jsonText: String) throws -> Envelope {
        guard let data = jsonText.data(using: .utf8) else {
            throw ParseError.malformed("LLM response is not UTF-8 text")
        }
        do {
            return try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ParseError.malformed("LLM response is not valid contract JSON")
        }
    }

    /// Normalized identity key: first+last name token (lowercased) + dob, mirroring M2's match
    /// discipline. Patients with neither a name nor a dob are ignored (absent info proceeds).
    private static func patientKey(_ p: PatientDTO) -> String? {
        let tokens = (p.name ?? "").lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let dob = (p.dob ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard let first = tokens.first, let last = tokens.last else {
            return dob.isEmpty ? nil : "|\(dob)"
        }
        return "\(first) \(last)|\(dob)"
    }

    // MARK: - Per-entry validation (validate, don't trust)

    private static func mapEntry(_ dto: ObservationDTO, subjectId: String,
                                 subjectDOB: Date?, now: Date) -> MapResult {
        let label = dto.display ?? dto.loinc ?? "Unknown"

        // 1. LOINC code (so the existing MappingTable applies).
        guard let loinc = dto.loinc, !loinc.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure(Skip(reason: .noCode, label: label, detail: .missingCode))
        }
        // 2. Effective date (ISO-8601 / yyyy-mm-dd, UTC discipline) — well-formed AND in range.
        guard let dateStr = dto.effectiveDate, let date = parseDate(dateStr) else {
            return .failure(Skip(reason: .noDate, label: label, detail: .dateMalformed))
        }
        if let implausibility = implausibility(date, dob: subjectDOB, now: now) {
            return .failure(Skip(reason: .implausibleDate, label: "\(label) [\(implausibility.reason)]",
                                 detail: implausibility.detail))
        }
        // 3. Value: EXACTLY one of numeric `value` / `valueText`. The schema forces both fields present
        // (nullable), so a confused model can emit BOTH non-null — reject the ambiguity, don't guess.
        if dto.value != nil, let t = dto.valueText, !t.trimmingCharacters(in: .whitespaces).isEmpty {
            return .failure(Skip(reason: .unrepresentableValue,
                                 label: "\(label) [rejected: both value and valueText present]",
                                 detail: .bothValueAndText))
        }
        let resolved = resolveValue(dto)
        guard case .ok(let value, let unit, let raw) = resolved else {
            let detail: Skip.Detail = (resolved == .nonFinite) ? .nonFiniteValue : .noUsableValue
            return .failure(Skip(reason: .unrepresentableValue, label: label, detail: detail))
        }
        // 4. Confidence: validate against 0...1 — REJECT out-of-range/absent, NEVER clamp.
        guard let confidence = dto.confidence, (0.0...1.0).contains(confidence) else {
            let got = dto.confidence.map { String($0) } ?? "missing"
            return .failure(Skip(reason: .unrepresentableValue,
                                 label: "\(label) [rejected: confidence \(got) not in 0...1]",
                                 detail: .confidenceOutOfRange(got: got)))
        }

        let id = ObservationID.derive(subjectId: subjectId, system: loincSystem, code: loinc,
                                      effectiveDate: date, rawValue: raw, unit: unit)
        let ref = CodeableRef(system: loincSystem, code: loinc, display: dto.display ?? loinc)
        let locator: SourceLocator? = (dto.page != nil || dto.snippet != nil)
            ? SourceLocator(page: dto.page, snippet: dto.snippet) : nil

        return .success(Observation(
            id: id, code: ref, name: dto.display ?? loinc, value: value, unit: unit,
            effectiveDate: date, category: mapCategory(dto.category),
            mapping: nil, confidence: confidence, sourceLocator: locator))
    }

    /// Outcome of resolving an entry's value. Splitting the two failure modes lets the caller record a
    /// precise `Skip.Detail` (`.nonFiniteValue` vs `.noUsableValue`) without changing the success shape.
    /// `internal` (not `private`) so tests can pin the defensive non-finite branch, which is unreachable
    /// through `decode` (JSONDecoder rejects overflowing numbers as malformed before they reach here).
    enum ResolvedValue: Equatable {
        case ok(ObservationValue, String?, String)
        case nonFinite          // numeric `value` present but not finite (e.g. ±inf / NaN)
        case noUsable           // neither a numeric value nor a non-empty valueText
    }

    /// Test-only seam over the non-finite branch of `resolveValue` (see `ResolvedValue`).
    static func resolveValueForTesting(_ v: Double) -> ResolvedValue {
        resolveValue(ObservationDTO(loinc: nil, display: nil, value: v, valueText: nil, unit: "kg",
                                    effectiveDate: nil, category: nil, confidence: nil,
                                    page: nil, snippet: nil))
    }

    /// Quantity → shared overflow-safe `stableNumberString` (id-parity with FHIR/C-CDA);
    /// qualitative → string with no unit. Non-finite numeric → `.nonFinite`; neither → `.noUsable`.
    private static func resolveValue(_ dto: ObservationDTO) -> ResolvedValue {
        if let v = dto.value {
            guard v.isFinite else { return .nonFinite }
            return .ok(.quantity(v), dto.unit, stableNumberString(v))
        }
        if let t = dto.valueText, !t.trimmingCharacters(in: .whitespaces).isEmpty {
            return .ok(.string(t), nil, t)
        }
        return .noUsable
    }

    private static func mapCategory(_ s: String?) -> ObservationCategory {
        switch s?.lowercased() {
        case "vital": return .vital
        case "lab": return .lab
        default: return .other
        }
    }

    // MARK: - Plausible-date guard (before-DOB / future)

    /// Reusable predicate: an observation date is plausible iff it is NOT strictly before the subject's
    /// DOB (birth-day measurements at == DOB are allowed) and NOT strictly after `now` (== today is
    /// allowed). A nil DOB skips the before-birth check but the future check still applies. Exposed so
    /// the FHIR/C-CDA paths can adopt the same guard later (deferred — not retrofitted here).
    public static func isPlausibleObservationDate(_ d: Date, dob: Date?, now: Date) -> Bool {
        implausibilityReason(d, dob: dob, now: now) == nil
    }

    /// nil when plausible; otherwise a human-readable reason for the Skip label.
    /// Compares at UTC CALENDAR-DAY granularity (not raw instants) so a same-UTC-day observation with a
    /// later wall-clock time than `now` is "today" (kept), not "future"; `== day` is allowed for both
    /// the birth-day and today boundaries.
    static func implausibilityReason(_ d: Date, dob: Date?, now: Date) -> String? {
        implausibility(d, dob: dob, now: now)?.reason
    }

    /// Both the label `reason` string AND the structured `Skip.Detail` for an implausible date, so
    /// `mapEntry` can distinguish before-DOB from after-now (issue #5). Single source of truth for the
    /// day-granularity comparison; `implausibilityReason` and `isPlausibleObservationDate` delegate here.
    static func implausibility(_ d: Date, dob: Date?, now: Date) -> (reason: String, detail: Skip.Detail)? {
        let dDay = utcCalendar.startOfDay(for: d)
        if let dob, dDay < utcCalendar.startOfDay(for: dob) {
            return ("implausible date: \(utcDateString(d)) before DOB \(utcDateString(dob))", .dateBeforeDOB)
        }
        if dDay > utcCalendar.startOfDay(for: now) {
            return ("implausible date: \(utcDateString(d)) after \(utcDateString(now))", .dateAfterNow)
        }
        return nil
    }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Format a `Date` as zero-padded UTC `yyyy-MM-dd` for Skip LABELS. Uses the thread-safe `utcCalendar`
    /// value type (Foundation `DateFormatter` is NOT thread-safe for concurrent `string(from:)`, and this
    /// is a public, concurrently-callable library API).
    private static func utcDateString(_ d: Date) -> String {
        let c = utcCalendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Date parsing (UTC; date-only -> UTC midnight)

    /// Parse an ISO-8601 / `yyyy-MM-dd` date from untrusted LLM output. Also used by the CLI to parse
    /// the roster DOB with the IDENTICAL UTC discipline so the plausible-date comparison is exact.
    ///
    /// `Calendar.date(from:)` and the date formatters SILENTLY NORMALIZE out-of-range components
    /// (e.g. `2000-02-30` -> 2000-03-01) instead of failing — the same integrity bug M2 fixed on the
    /// C-CDA HL7-TS path (`CCDAParser.date(fromHL7TS:)`). To honor "validate, don't trust", we parse
    /// components manually and ROUND-TRIP through the same UTC/fixed-offset Gregorian calendar,
    /// rejecting (→ nil → `Skip(.noDate)`) if any component changed. Fixed offsets have no DST, so
    /// there are no false negatives.
    public static func parseDate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        // Split the date from an optional time component (ISO "T" or a space separator).
        let dateStr: Substring
        var timeStr: Substring?
        if let sep = t.firstIndex(where: { $0 == "T" || $0 == " " }) {
            dateStr = t[..<sep]
            timeStr = t[t.index(after: sep)...]
        } else {
            dateStr = t[...]
        }

        // Date: strict, zero-padded yyyy-MM-dd.
        let d = dateStr.split(separator: "-", omittingEmptySubsequences: false)
        guard d.count == 3,
              let year = intExactWidth(d[0], 4),
              let month = intExactWidth(d[1], 2),
              let day = intExactWidth(d[2], 2) else { return nil }

        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        var tz = TimeZone(identifier: "UTC")!

        if let timeStr {
            guard let parsed = parseTime(timeStr) else { return nil }
            c.hour = parsed.h; c.minute = parsed.m; c.second = parsed.s; tz = parsed.tz
        } else {
            c.hour = 0; c.minute = 0; c.second = 0   // date-only -> UTC midnight
        }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        guard let date = cal.date(from: c) else { return nil }
        let rt = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard rt.year == c.year, rt.month == c.month, rt.day == c.day,
              rt.hour == c.hour, rt.minute == c.minute, rt.second == c.second else { return nil }
        return date
    }

    /// `HH:mm[:ss[.frac]]` plus optional `Z` / `±HH:mm` / `±HHmm` offset. Strict, zero-padded fields.
    private static func parseTime(_ s: Substring) -> (h: Int, m: Int, s: Int, tz: TimeZone)? {
        var body = String(s)
        var tz = TimeZone(identifier: "UTC")!
        if body.hasSuffix("Z") || body.hasSuffix("z") {
            body.removeLast()
        } else if let r = body.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) {
            let off = body[r]
            let sign = off.first == "-" ? -1 : 1
            let digits = off.dropFirst().filter { $0.isNumber }
            guard digits.count == 4, let oh = Int(digits.prefix(2)), let om = Int(digits.suffix(2)),
                  let z = TimeZone(secondsFromGMT: sign * (oh * 3600 + om * 60)) else { return nil }
            tz = z
            body.removeSubrange(r)
        }
        let p = body.split(separator: ":", omittingEmptySubsequences: false)
        guard p.count == 2 || p.count == 3,
              let h = intExactWidth(p[0], 2),
              let m = intExactWidth(p[1], 2) else { return nil }
        var sec = 0
        if p.count == 3 {
            let secPart = p[2].split(separator: ".").first ?? p[2]   // tolerate fractional seconds
            guard let s2 = intExactWidth(secPart, 2) else { return nil }
            sec = s2
        }
        return (h, m, sec, tz)
    }

    private static func intExactWidth(_ s: Substring, _ width: Int) -> Int? {
        guard s.count == width, s.allSatisfy({ $0.isNumber }) else { return nil }
        return Int(s)
    }
}
