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

    private static let utcDateOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func parseDate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if t.contains("T") {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: t) { return d }
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: t) { return d }
        }
        return utcDateOnly.date(from: t)
    }
}
