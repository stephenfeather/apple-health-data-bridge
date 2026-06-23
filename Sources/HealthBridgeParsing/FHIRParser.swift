import Foundation
import BridgeKit
import ModelsR4

public struct FHIRParser: DocumentParser {
    public init() {}

    public static func canParse(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["resourceType"] as? String else { return false }
        return type == "Bundle" || type == "Observation"
    }

    public func parse(_ data: Data, subjectId: String) throws -> ParseResult {
        let fhir = try decodeObservations(data)
        var observations: [BridgeKit.Observation] = []
        var skipped: [Skip] = []
        for o in fhir {
            for r in convert(o, subjectId: subjectId) {
                switch r { case .success(let obs): observations.append(obs); case .failure(let s): skipped.append(s) }
            }
        }
        return ParseResult(observations: observations, skipped: skipped)
    }

    private func decodeObservations(_ data: Data) throws -> [ModelsR4.Observation] {
        let decoder = JSONDecoder()
        if let bundle = try? decoder.decode(ModelsR4.Bundle.self, from: data) {
            return bundle.entry?.compactMap { $0.resource?.get(if: ModelsR4.Observation.self) } ?? []
        }
        do { return [try decoder.decode(ModelsR4.Observation.self, from: data)] }
        catch { throw ParseError.malformed("not a FHIR Bundle or Observation: \(error)") }
    }

    private enum ConvertResult { case success(BridgeKit.Observation); case failure(Skip) }

    /// A panel (components, no top-level value) yields one observation per component;
    /// otherwise a single observation from the top-level value.
    private func convert(_ o: ModelsR4.Observation, subjectId: String) -> [ConvertResult] {
        let effective = effectiveDate(o.effective)
        let cat = category(o.category)
        if o.value == nil, let comps = o.component, !comps.isEmpty {
            return comps.map { c in
                build(code: c.code, value: observationValue(c.value), effective: effective, category: cat, subjectId: subjectId)
            }
        }
        return [build(code: o.code, value: observationValue(o.value), effective: effective, category: cat, subjectId: subjectId)]
    }

    private func build(code: CodeableConcept, value: (ObservationValue, String?, String)?,
                       effective: Date?, category: ObservationCategory, subjectId: String) -> ConvertResult {
        let label = code.text?.value?.string ?? code.coding?.first?.display?.value?.string ?? "Unknown"
        guard let coding = loincCoding(code) else { return .failure(Skip(reason: .noCode, label: label)) }
        guard let effective else { return .failure(Skip(reason: .noDate, label: label)) }
        guard let (val, unit, raw) = value else { return .failure(Skip(reason: .unrepresentableValue, label: label)) }
        let codeStr = coding.code?.value?.string
        let system = coding.system?.value?.url.absoluteString
        let display = coding.display?.value?.string ?? code.text?.value?.string ?? codeStr ?? "Unknown"
        let id = ObservationID.derive(subjectId: subjectId, system: system, code: codeStr,
                                      effectiveDate: effective, rawValue: raw, unit: unit)
        let ref = (system != nil && codeStr != nil) ? CodeableRef(system: system!, code: codeStr!, display: display) : nil
        return .success(BridgeKit.Observation(id: id, code: ref, name: display, value: val, unit: unit,
                                              effectiveDate: effective, category: category, mapping: nil,
                                              confidence: 1.0, sourceLocator: nil))
    }

    private func loincCoding(_ code: CodeableConcept) -> Coding? {
        let codings = code.coding ?? []
        return codings.first { $0.system?.value?.url.absoluteString == "http://loinc.org" } ?? codings.first
    }

    private func observationValue(_ value: ModelsR4.Observation.ValueX?) -> (ObservationValue, String?, String)? {
        guard let value else { return nil }
        switch value {
        case .quantity(let q): return quantity(q)
        case .string(let s): return string(s)
        default: return nil
        }
    }
    private func observationValue(_ value: ObservationComponent.ValueX?) -> (ObservationValue, String?, String)? {
        guard let value else { return nil }
        switch value {
        case .quantity(let q): return quantity(q)
        case .string(let s): return string(s)
        default: return nil
        }
    }
    private func quantity(_ q: Quantity) -> (ObservationValue, String?, String)? {
        guard let decimal = q.value?.value?.decimal else { return nil }
        let d = NSDecimalNumber(decimal: decimal).doubleValue
        let unit = q.code?.value?.string ?? q.unit?.value?.string
        return (.quantity(d), unit, stableNumberString(d))
    }
    private func string(_ s: FHIRPrimitive<FHIRString>) -> (ObservationValue, String?, String)? {
        guard let str = s.value?.string else { return nil }
        return (.string(str), nil, str)
    }

    private func effectiveDate(_ effective: ModelsR4.Observation.EffectiveX?) -> Date? {
        guard let effective else { return nil }
        switch effective {
        case .dateTime(let dt): return dt.value.flatMap(FHIRDate.date(from:))
        case .instant(let inst): return inst.value.flatMap(FHIRDate.date(from:))
        case .period(let p): return p.start?.value.flatMap(FHIRDate.date(from:))
        default: return nil
        }
    }

    private func category(_ categories: [CodeableConcept]?) -> ObservationCategory {
        let codes = (categories ?? []).flatMap { $0.coding ?? [] }.compactMap { $0.code?.value?.string }
        if codes.contains("vital-signs") { return .vital }
        if codes.contains("laboratory") { return .lab }
        return .other
    }
    // Number rendering for id stability moved to the shared `stableNumberString` free function
    // (NumberString.swift) so FHIRParser and CCDAParser stay byte-identical for matching content.
}
