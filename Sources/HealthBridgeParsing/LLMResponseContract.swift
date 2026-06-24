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

    private enum MapResult { case success(Observation); case failure(Skip) }

    /// Decode + validate the contract JSON into `[Observation]` + `[Skip]`.
    /// Throws `ParseError.malformed` on non-JSON / wrong top-level shape.
    public static func decode(_ jsonText: String, subjectId: String) throws -> ParseResult {
        guard let data = jsonText.data(using: .utf8) else {
            throw ParseError.malformed("LLM response is not UTF-8 text")
        }
        let env: Envelope
        do {
            env = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw ParseError.malformed("LLM response is not valid contract JSON")
        }

        var observations: [Observation] = []
        var skipped: [Skip] = []
        for dto in env.observations ?? [] {
            switch mapEntry(dto, subjectId: subjectId) {
            case .success(let o): observations.append(o)
            case .failure(let s): skipped.append(s)
            }
        }
        return ParseResult(observations: observations, skipped: skipped)
    }

    // MARK: - Per-entry validation (validate, don't trust)

    private static func mapEntry(_ dto: ObservationDTO, subjectId: String) -> MapResult {
        let label = dto.display ?? dto.loinc ?? "Unknown"

        // 1. LOINC code (so the existing MappingTable applies).
        guard let loinc = dto.loinc, !loinc.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure(Skip(reason: .noCode, label: label))
        }
        // 2. Effective date (ISO-8601 / yyyy-mm-dd, UTC discipline).
        guard let dateStr = dto.effectiveDate, let date = parseDate(dateStr) else {
            return .failure(Skip(reason: .noDate, label: label))
        }
        // 3. Value: exactly one of numeric `value` / `valueText`, finite.
        guard let (value, unit, raw) = resolveValue(dto) else {
            return .failure(Skip(reason: .unrepresentableValue, label: label))
        }
        // 4. Confidence: validate against 0...1 — REJECT out-of-range/absent, NEVER clamp.
        guard let confidence = dto.confidence, (0.0...1.0).contains(confidence) else {
            let got = dto.confidence.map { String($0) } ?? "missing"
            return .failure(Skip(reason: .unrepresentableValue, label: "\(label) [rejected: confidence \(got) not in 0...1]"))
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

    /// Quantity → shared overflow-safe `stableNumberString` (id-parity with FHIR/C-CDA);
    /// qualitative → string with no unit. Neither / non-finite → nil (caller records a Skip).
    private static func resolveValue(_ dto: ObservationDTO) -> (ObservationValue, String?, String)? {
        if let v = dto.value {
            guard v.isFinite else { return nil }
            return (.quantity(v), dto.unit, stableNumberString(v))
        }
        if let t = dto.valueText, !t.trimmingCharacters(in: .whitespaces).isEmpty {
            return (.string(t), nil, t)
        }
        return nil
    }

    private static func mapCategory(_ s: String?) -> ObservationCategory {
        switch s?.lowercased() {
        case "vital": return .vital
        case "lab": return .lab
        default: return .other
        }
    }

    // MARK: - Date parsing (UTC; date-only -> UTC midnight)

    /// Parse an ISO-8601 / `yyyy-MM-dd` date from untrusted LLM output.
    ///
    /// `Calendar.date(from:)` and the date formatters SILENTLY NORMALIZE out-of-range components
    /// (e.g. `2000-02-30` -> 2000-03-01) instead of failing — the same integrity bug M2 fixed on the
    /// C-CDA HL7-TS path (`CCDAParser.date(fromHL7TS:)`). To honor "validate, don't trust", we parse
    /// components manually and ROUND-TRIP through the same UTC/fixed-offset Gregorian calendar,
    /// rejecting (→ nil → `Skip(.noDate)`) if any component changed. Fixed offsets have no DST, so
    /// there are no false negatives.
    private static func parseDate(_ s: String) -> Date? {
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
