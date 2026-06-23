import Foundation

public struct ValidationIssue: Equatable, Sendable {
    public enum Severity: Sendable { case error, warning }
    public let severity: Severity
    public let message: String
    public init(severity: Severity, message: String) { self.severity = severity; self.message = message }
}

public func validate(_ document: BridgeDocument) -> [ValidationIssue] {
    var issues: [ValidationIssue] = []
    func err(_ m: String) { issues.append(.init(severity: .error, message: m)) }

    if document.schemaVersion != BridgeDocument.currentSchemaVersion {
        err("schemaVersion \(document.schemaVersion) != \(BridgeDocument.currentSchemaVersion)")
    }
    let sha = document.source.sha256
    if sha.count != 64 || sha.contains(where: { !$0.isHexDigit }) { err("source.sha256 is not 64 hex chars") }
    if document.subject.id.isEmpty { err("subject.id is empty") }
    else if UUID(uuidString: document.subject.id) == nil { err("subject.id is not a valid UUID") }
    if document.subject.hash.isEmpty { err("subject.hash is empty") }
    if document.observations.isEmpty { issues.append(.init(severity: .warning, message: "document has zero observations")) }

    var seen = Set<String>()
    for o in document.observations {
        if o.id.isEmpty { err("observation has empty id") }
        if !seen.insert(o.id).inserted { err("duplicate observation id: \(o.id)") }
        if o.name.isEmpty { err("observation \(o.id) has empty name") }
        if !(0.0...1.0).contains(o.confidence) { err("confidence out of range for \(o.id)") }
        if case .quantity(let d) = o.value, !d.isFinite { err("non-finite value for \(o.id)") }
        if let m = o.mapping {
            if case .string = o.value { err("string-valued observation \(o.id) cannot carry a HealthKit mapping") }
            if m.quantityType.isEmpty || m.canonicalUnit.isEmpty { err("empty mapping field for \(o.id)") }
            if !m.convertedValue.isFinite { err("non-finite mapping.convertedValue for \(o.id)") }
        }
    }
    return issues
}
