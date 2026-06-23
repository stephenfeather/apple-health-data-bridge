import Foundation

public enum SourceKind: String, Codable, Sendable { case fhir, ccda, pdf }

public struct Extractor: Codable, Equatable, Sendable {
    public var engine: String; public var version: String
    public init(engine: String, version: String) { self.engine = engine; self.version = version }
}

public struct Source: Codable, Equatable, Sendable {
    public var kind: SourceKind; public var fileName: String; public var sha256: String
    public var extractedAt: Date; public var extractor: Extractor
    public init(kind: SourceKind, fileName: String, sha256: String, extractedAt: Date, extractor: Extractor) {
        self.kind = kind; self.fileName = fileName; self.sha256 = sha256
        self.extractedAt = extractedAt; self.extractor = extractor
    }
}

public struct SubjectRef: Codable, Equatable, Sendable {
    public var id: String       // UUID
    public var label: String
    public var hash: String     // sha256(name|dob)
    public var name: String?
    public var dob: String?
    public init(id: String, label: String, hash: String, name: String? = nil, dob: String? = nil) {
        self.id = id; self.label = label; self.hash = hash; self.name = name; self.dob = dob
    }
}

public struct BridgeDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var source: Source
    public var subject: SubjectRef
    public var observations: [Observation]
    public init(schemaVersion: Int, source: Source, subject: SubjectRef, observations: [Observation]) {
        self.schemaVersion = schemaVersion; self.source = source
        self.subject = subject; self.observations = observations
    }
}
