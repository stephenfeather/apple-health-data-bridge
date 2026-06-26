import Foundation
import BridgeKit
#if canImport(FoundationXML)
import FoundationXML
#endif

#if canImport(FoundationXML) || os(macOS)
public struct CCDAParser: DocumentParser {
    /// Reference instant for the plausible-date guard (parity with the LLM path). Injected so tests can
    /// pin it; production uses the wall clock. Threaded via the INITIALIZER rather than the
    /// `DocumentParser.parse` signature to keep the protocol and its callers (`ParserRegistry`, CLI) untouched.
    private let now: Date
    public init(now: Date = Date()) { self.now = now }

    static let loincOID = "2.16.840.1.113883.6.1"
    static let loincURI = "http://loinc.org"

    public static func canParse(_ data: Data) -> Bool { CDAXML.isClinicalDocument(data) }

    public func parse(_ data: Data, subjectId: String) throws -> ParseResult {
        let doc = try CDAXML.document(data)
        guard let root = doc.rootElement() else { throw ParseError.malformed("no ClinicalDocument root") }
        try enforceSinglePatient(root)            // Task 4
        let dob = patientDOB(root)                 // for the plausible-date guard (nil if absent)

        var observations: [Observation] = []
        var skipped: [Skip] = []
        // Iterate ONLY the top-level structuredBody sections. A descendant-or-self section walk would
        // also visit nested subsections, and since each section's own descendant observation walk
        // already collects everything beneath it, that double-counts subsection observations and skips.
        for section in topLevelSections(root) {
            let (obs, skips) = parseSection(section, subjectId: subjectId, dob: dob)
            observations.append(contentsOf: obs); skipped.append(contentsOf: skips)
        }
        return ParseResult(observations: observations, skipped: skipped)
    }

    /// The single recordTarget's birthTime as a Date (UTC), for the plausible-date guard. nil when the
    /// document carries no patient DOB — the guard handles nil dob (skips the before-birth check only).
    private func patientDOB(_ root: XMLElement) -> Date? {
        guard let role = (try? CDAXML.elements(root, localName: "patientRole"))?.first,
              let patient = CDAXML.child(role, localName: "patient"),
              let bt = CDAXML.child(patient, localName: "birthTime"),
              let v = CDAXML.attr(bt, "value") else { return nil }
        return Self.date(fromHL7TS: v)
    }

    /// The direct structuredBody sections: ClinicalDocument/component/structuredBody/component/section.
    /// Subsections (a section's own component/section) are intentionally NOT iterated here — the
    /// owning top-level section's descendant observation walk collects their observations once.
    private func topLevelSections(_ root: XMLElement) -> [XMLElement] {
        (try? CDAXML.query(root,
            "./*[local-name()='component']/*[local-name()='structuredBody']/*[local-name()='component']/*[local-name()='section']"
        )) ?? []
    }

    // MARK: section dispatch (Tasks 3,5,6)
    private func parseSection(_ section: XMLElement, subjectId: String, dob: Date?) -> ([Observation], [Skip]) {
        let code = CDAXML.child(section, localName: "code").flatMap { CDAXML.attr($0, "code") }
        switch code {
        case "8716-3":  return parseVitals(section, subjectId: subjectId, dob: dob)     // Vital Signs
        case "30954-2": return parseResults(section, subjectId: subjectId, dob: dob)    // Results
        case "11450-4": return parseProblems(section, subjectId: subjectId, dob: dob)   // Problems
        case "48765-2": return parseAllergies(section, subjectId: subjectId, dob: dob)  // Allergies
        default:        return ([], [])                                                 // unknown section: ignored
        }
    }

    // MARK: Vital Signs (Task 3 happy path; BP organizer in Task 5)
    private func parseVitals(_ section: XMLElement, subjectId: String, dob: Date?) -> ([Observation], [Skip]) {
        var obs: [Observation] = []; var skips: [Skip] = []
        for observation in observationElements(in: section) {
            switch quantitative(observation, category: .vital, subjectId: subjectId, dob: dob) {
            case .success(let o): obs.append(o); case .failure(let s): skips.append(s)
            }
        }
        return (obs, skips)
    }

    // MARK: results/labs (Task 6)
    func parseResults(_ section: XMLElement, subjectId: String, dob: Date?) -> ([Observation], [Skip]) {
        var obs: [Observation] = []; var skips: [Skip] = []
        for observation in observationElements(in: section) {
            switch quantitative(observation, category: .lab, subjectId: subjectId, dob: dob) {
            case .success(let o): obs.append(o); case .failure(let s): skips.append(s)
            }
        }
        return (obs, skips)
    }

    // MARK: problems / allergies (Task 6) — qualitative .string values
    func parseProblems(_ section: XMLElement, subjectId: String, dob: Date?) -> ([Observation], [Skip]) {
        qualitative(section, subjectId: subjectId, dob: dob)
    }
    func parseAllergies(_ section: XMLElement, subjectId: String, dob: Date?) -> ([Observation], [Skip]) {
        qualitative(section, subjectId: subjectId, dob: dob)
    }

    // MARK: helpers
    /// All <observation> elements anywhere under a section (covers bare entries and organizer panels).
    private func observationElements(in section: XMLElement) -> [XMLElement] {
        (try? CDAXML.elements(section, localName: "observation")) ?? []
    }

    private enum ConvertResult { case success(Observation); case failure(Skip) }

    /// True when the observation (or an ancestor act) carries negationInd="true" — e.g. "no penicillin
    /// allergy". The Bridge schema has no polarity field, so a negated assertion must be dropped rather
    /// than emitted as a present condition (an inversion of clinical meaning).
    private func isNegated(_ el: XMLElement) -> Bool {
        var node: XMLElement? = el
        while let cur = node {
            if CDAXML.attr(cur, "negationInd") == "true" { return true }
            node = cur.parent as? XMLElement
        }
        return false
    }

    private func quantitative(_ observation: XMLElement, category: ObservationCategory, subjectId: String, dob: Date?) -> ConvertResult {
        let codeEl = CDAXML.child(observation, localName: "code")
        let display = codeEl.flatMap { CDAXML.attr($0, "displayName") } ?? "Unknown"
        if isNegated(observation) { return .failure(Skip(reason: .negated, label: display)) }
        guard let codeEl, CDAXML.attr(codeEl, "codeSystem") == Self.loincOID,
              let code = CDAXML.attr(codeEl, "code") else {
            return .failure(Skip(reason: .noCode, label: display))
        }
        guard let tsEl = CDAXML.child(observation, localName: "effectiveTime"),
              let ts = CDAXML.attr(tsEl, "value"), let date = Self.date(fromHL7TS: ts) else {
            return .failure(Skip(reason: .noDate, label: display))
        }
        // Plausible-date guard (parity with the LLM path): drop an effectiveDate strictly before DOB or
        // strictly after `now`. Same Skip(.implausibleDate) + Detail the contract decoder records.
        if let imp = LLMResponseContract.implausibility(date, dob: dob, now: now) {
            return .failure(Skip(reason: .implausibleDate, label: "\(display) [\(imp.reason)]", detail: imp.detail))
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

    private func qualitative(_ section: XMLElement, subjectId: String, dob: Date?) -> ([Observation], [Skip]) {
        var obs: [Observation] = []; var skips: [Skip] = []
        for observation in observationElements(in: section) {
            let codeEl = CDAXML.child(observation, localName: "code")
            let display = codeEl.flatMap { CDAXML.attr($0, "displayName") } ?? "Problem"
            if isNegated(observation) { skips.append(Skip(reason: .negated, label: display)); continue }
            guard let codeEl, CDAXML.attr(codeEl, "codeSystem") == Self.loincOID,
                  let code = CDAXML.attr(codeEl, "code") else {
                skips.append(Skip(reason: .noCode, label: display)); continue
            }
            guard let tsEl = CDAXML.child(observation, localName: "effectiveTime"),
                  let ts = CDAXML.attr(tsEl, "value"), let date = Self.date(fromHL7TS: ts) else {
                skips.append(Skip(reason: .noDate, label: display)); continue
            }
            // Plausible-date guard (parity with the LLM path): drop before-DOB / after-now dates.
            if let imp = LLMResponseContract.implausibility(date, dob: dob, now: now) {
                skips.append(Skip(reason: .implausibleDate, label: "\(display) [\(imp.reason)]", detail: imp.detail))
                continue
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
        let digits = Array(ts.prefix { $0.isNumber })
        guard digits.count >= 8 else { return nil }
        func part(_ lo: Int, _ len: Int) -> Int? {
            guard lo + len <= digits.count else { return nil }
            return Int(String(digits[lo..<lo+len]))
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
        guard let date = cal.date(from: c) else { return nil }
        // Calendar.date(from:) NORMALIZES out-of-range components (day 40 -> next month, 99:99 -> rollover)
        // instead of failing. Round-trip with the SAME calendar/timezone and reject if any parsed field
        // changed — a malformed timestamp must be nil (→ .noDate skip), never a silently-wrong date.
        let rt = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard rt.year == c.year, rt.month == c.month, rt.day == c.day,
              rt.hour == c.hour, rt.minute == c.minute, rt.second == c.second else { return nil }
        return date
    }

    // MARK: patient demographics (for the CLI subject cross-check; CDAXML is module-internal)
    /// One entry per recordTarget/patientRole/patient: name ("given… family") and dob (YYYY-MM-DD).
    /// The CLI uses this for the subject cross-check and multi-patient detection without re-parsing
    /// observations. Returns [] for non-C-CDA or unreadable input.
    public static func patientDemographics(_ data: Data) -> [(name: String, dob: String)] {
        guard CDAXML.isClinicalDocument(data),
              let doc = try? CDAXML.document(data), let root = doc.rootElement() else { return [] }
        let roles = (try? CDAXML.elements(root, localName: "patientRole")) ?? []
        return roles.map { role in
            let patient = CDAXML.child(role, localName: "patient")
            let nameEl = patient.flatMap { CDAXML.child($0, localName: "name") }
            let givens = (nameEl?.children?.compactMap { $0 as? XMLElement } ?? [])
                .filter { $0.localName == "given" }
                .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let family = nameEl.flatMap { CDAXML.child($0, localName: "family") }?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = (givens + [family]).filter { !$0.isEmpty }.joined(separator: " ")
            let raw = patient.flatMap { CDAXML.child($0, localName: "birthTime") }
                .flatMap { CDAXML.attr($0, "value") } ?? ""
            return (name, formatHL7Date(raw))
        }
    }

    /// HL7 date (YYYYMMDD[…]) -> "YYYY-MM-DD". Empty string when there are fewer than 8 leading digits.
    static func formatHL7Date(_ s: String) -> String {
        let digits = Array(s.prefix { $0.isNumber })
        guard digits.count >= 8 else { return "" }
        return "\(String(digits[0..<4]))-\(String(digits[4..<6]))-\(String(digits[6..<8]))"
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
