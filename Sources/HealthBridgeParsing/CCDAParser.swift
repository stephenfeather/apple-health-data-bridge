import Foundation
import BridgeKit
#if canImport(FoundationXML)
import FoundationXML
#endif

#if canImport(FoundationXML) || os(macOS)
public struct CCDAParser: DocumentParser {
    public init() {}

    static let loincOID = "2.16.840.1.113883.6.1"
    static let loincURI = "http://loinc.org"

    public static func canParse(_ data: Data) -> Bool { CDAXML.isClinicalDocument(data) }

    public func parse(_ data: Data, subjectId: String) throws -> ParseResult {
        let doc = try CDAXML.document(data)
        guard let root = doc.rootElement() else { throw ParseError.malformed("no ClinicalDocument root") }
        try enforceSinglePatient(root)            // Task 4

        var observations: [Observation] = []
        var skipped: [Skip] = []
        for section in try CDAXML.elements(root, localName: "section") {
            let (obs, skips) = parseSection(section, subjectId: subjectId)
            observations.append(contentsOf: obs); skipped.append(contentsOf: skips)
        }
        return ParseResult(observations: observations, skipped: skipped)
    }

    // MARK: section dispatch (Tasks 3,5,6)
    private func parseSection(_ section: XMLElement, subjectId: String) -> ([Observation], [Skip]) {
        let code = CDAXML.child(section, localName: "code").flatMap { CDAXML.attr($0, "code") }
        switch code {
        case "8716-3":  return parseVitals(section, subjectId: subjectId)          // Vital Signs
        case "30954-2": return parseResults(section, subjectId: subjectId)         // Results
        case "11450-4": return parseProblems(section, subjectId: subjectId)        // Problems
        case "48765-2": return parseAllergies(section, subjectId: subjectId)       // Allergies
        default:        return ([], [])                                            // unknown section: ignored
        }
    }

    // MARK: Vital Signs (Task 3 happy path; BP organizer in Task 5)
    private func parseVitals(_ section: XMLElement, subjectId: String) -> ([Observation], [Skip]) {
        var obs: [Observation] = []; var skips: [Skip] = []
        for observation in observationElements(in: section) {
            switch quantitative(observation, category: .vital, subjectId: subjectId) {
            case .success(let o): obs.append(o); case .failure(let s): skips.append(s)
            }
        }
        return (obs, skips)
    }

    // MARK: results/labs (Task 6)
    func parseResults(_ section: XMLElement, subjectId: String) -> ([Observation], [Skip]) {
        var obs: [Observation] = []; var skips: [Skip] = []
        for observation in observationElements(in: section) {
            switch quantitative(observation, category: .lab, subjectId: subjectId) {
            case .success(let o): obs.append(o); case .failure(let s): skips.append(s)
            }
        }
        return (obs, skips)
    }

    // MARK: problems / allergies (Task 6) — qualitative .string values
    func parseProblems(_ section: XMLElement, subjectId: String) -> ([Observation], [Skip]) {
        qualitative(section, subjectId: subjectId)
    }
    func parseAllergies(_ section: XMLElement, subjectId: String) -> ([Observation], [Skip]) {
        qualitative(section, subjectId: subjectId)
    }

    // MARK: helpers
    /// All <observation> elements anywhere under a section (covers bare entries and organizer panels).
    private func observationElements(in section: XMLElement) -> [XMLElement] {
        (try? CDAXML.elements(section, localName: "observation")) ?? []
    }

    private enum ConvertResult { case success(Observation); case failure(Skip) }

    private func quantitative(_ observation: XMLElement, category: ObservationCategory, subjectId: String) -> ConvertResult {
        let codeEl = CDAXML.child(observation, localName: "code")
        let display = codeEl.flatMap { CDAXML.attr($0, "displayName") } ?? "Unknown"
        guard let codeEl, CDAXML.attr(codeEl, "codeSystem") == Self.loincOID,
              let code = CDAXML.attr(codeEl, "code") else {
            return .failure(Skip(reason: .noCode, label: display))
        }
        guard let tsEl = CDAXML.child(observation, localName: "effectiveTime"),
              let ts = CDAXML.attr(tsEl, "value"), let date = Self.date(fromHL7TS: ts) else {
            return .failure(Skip(reason: .noDate, label: display))
        }
        guard let valueEl = CDAXML.child(observation, localName: "value"),
              CDAXML.attr(valueEl, "nullFlavor") == nil,
              let raw = CDAXML.attr(valueEl, "value"), let d = Double(raw), d.isFinite else {
            return .failure(Skip(reason: .unrepresentableValue, label: display))
        }
        let unit = CDAXML.attr(valueEl, "unit")
        let id = ObservationID.derive(subjectId: subjectId, system: Self.loincURI, code: code,
                                      effectiveDate: date, rawValue: stableNumberString(d), unit: unit)
        return .success(Observation(id: id, code: CodeableRef(system: Self.loincURI, code: code, display: display),
                                    name: display, value: .quantity(d), unit: unit, effectiveDate: date,
                                    category: category, mapping: nil, confidence: 1.0, sourceLocator: nil))
    }

    private func qualitative(_ section: XMLElement, subjectId: String) -> ([Observation], [Skip]) {
        var obs: [Observation] = []; var skips: [Skip] = []
        for observation in observationElements(in: section) {
            let codeEl = CDAXML.child(observation, localName: "code")
            let display = codeEl.flatMap { CDAXML.attr($0, "displayName") } ?? "Problem"
            guard let codeEl, CDAXML.attr(codeEl, "codeSystem") == Self.loincOID,
                  let code = CDAXML.attr(codeEl, "code") else {
                skips.append(Skip(reason: .noCode, label: display)); continue
            }
            guard let tsEl = CDAXML.child(observation, localName: "effectiveTime"),
                  let ts = CDAXML.attr(tsEl, "value"), let date = Self.date(fromHL7TS: ts) else {
                skips.append(Skip(reason: .noDate, label: display)); continue
            }
            let valueEl = CDAXML.child(observation, localName: "value")
            let text = valueText(valueEl) ?? display
            let id = ObservationID.derive(subjectId: subjectId, system: Self.loincURI, code: code,
                                          effectiveDate: date, rawValue: text, unit: nil)
            obs.append(Observation(id: id, code: CodeableRef(system: Self.loincURI, code: code, display: display),
                                   name: display, value: .string(text), unit: nil, effectiveDate: date,
                                   category: .other, mapping: nil, confidence: 1.0, sourceLocator: nil))
        }
        return (obs, skips)
    }

    /// Qualitative display text: prefer the value's @displayName (CD/coded), else its element text
    /// content (ST/free-text values that carry no displayName attribute).
    private func valueText(_ el: XMLElement?) -> String? {
        guard let el else { return nil }
        if let dn = CDAXML.attr(el, "displayName"), !dn.isEmpty { return dn }
        let s = el.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }

    // MARK: HL7 TS date — UTC for timezone-less/date-only (parity with FHIRDate)
    static func date(fromHL7TS ts: String) -> Date? {
        let digits = ts.prefix { $0.isNumber }
        guard digits.count >= 8 else { return nil }
        func part(_ lo: Int, _ len: Int) -> Int? {
            let s = Array(digits); guard lo + len <= s.count else { return nil }
            return Int(String(s[lo..<lo+len]))
        }
        var c = DateComponents()
        c.year = part(0, 4); c.month = part(4, 2); c.day = part(6, 2)
        c.hour = part(8, 2) ?? 0; c.minute = part(10, 2) ?? 0; c.second = part(12, 2) ?? 0
        var cal = Calendar(identifier: .gregorian)
        if let r = ts.range(of: #"[+-]\d{4}$"#, options: .regularExpression) {
            let off = ts[r]; let sign = off.first == "-" ? -1 : 1
            let h = Int(off.dropFirst().prefix(2)) ?? 0, m = Int(off.suffix(2)) ?? 0
            cal.timeZone = TimeZone(secondsFromGMT: sign * (h * 3600 + m * 60)) ?? .init(identifier: "UTC")!
        } else {
            cal.timeZone = TimeZone(identifier: "UTC")!   // timezone-less / date-only -> UTC
        }
        return cal.date(from: c)
    }

    // MARK: single-subject binding (PHI-safety parity with M1)
    /// Conservative single-subject binding: a Bridge Document binds ONE person.
    /// More than one recordTarget/patientRole is refused (PHI-safety parity with M1). The decision
    /// is on the COUNT of patients in the document and is independent of the selected subjectId —
    /// a multi-patient document must never let one subject's selection admit another's observations.
    private func enforceSinglePatient(_ root: XMLElement) throws {
        let targets = (try? CDAXML.elements(root, localName: "patientRole")) ?? []
        if targets.count > 1 {
            throw ParseError.malformed("C-CDA contains \(targets.count) patients; refusing (one document = one subject)")
        }
    }
}
#endif
