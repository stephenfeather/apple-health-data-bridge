import Foundation

public struct SubjectEntry: Codable, Equatable, Sendable {
    public var key: String
    public var subjectId: String
    public var label: String
    public var name: String
    public var dob: String
    public init(key: String, subjectId: String, label: String, name: String, dob: String) {
        self.key = key; self.subjectId = subjectId; self.label = label; self.name = name; self.dob = dob
    }
    enum CodingKeys: String, CodingKey {
        case key, label, name, dob
        case subjectId = "subject_id"
    }
}

public enum ConfigError: Error, Equatable { case duplicateKey(String) }

public struct Config: Codable, Equatable, Sendable {
    public var dataRoot: String?
    public var defaultSubject: String?
    public var logLevel: String?
    /// #4 opt-in raw-response logging (PHI-safe offline eval capture). Nil/absent = OFF (default).
    public var rawResponseLog: Bool?
    /// #4 optional override for the JSONL log path (else `<dataRoot>/raw-responses.jsonl`).
    public var rawResponseLogPath: String?
    public var subjects: [SubjectEntry]
    public init(dataRoot: String? = nil, defaultSubject: String? = nil,
                logLevel: String? = nil, rawResponseLog: Bool? = nil,
                rawResponseLogPath: String? = nil, subjects: [SubjectEntry] = []) {
        self.dataRoot = dataRoot; self.defaultSubject = defaultSubject
        self.logLevel = logLevel
        self.rawResponseLog = rawResponseLog; self.rawResponseLogPath = rawResponseLogPath
        self.subjects = subjects
    }
    public mutating func addSubject(_ entry: SubjectEntry) throws {
        if subjects.contains(where: { $0.key == entry.key }) { throw ConfigError.duplicateKey(entry.key) }
        subjects.append(entry)
    }
    enum CodingKeys: String, CodingKey {
        case subjects
        case dataRoot = "data_root"
        case defaultSubject = "default_subject"
        case logLevel = "log_level"
        case rawResponseLog = "raw_response_log"
        case rawResponseLogPath = "raw_response_log_path"
    }
}
