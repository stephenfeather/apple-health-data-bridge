import Foundation

// MARK: - Gold (expected) — mirrors the contract's ObservationDTO shape so scoring is like-to-like.

struct ExpectedPatient: Codable, Equatable {
    let name: String
    let dob: String
}

struct ExpectedObservation: Codable, Equatable {
    let loinc: String
    let display: String?
    let value: Double?
    let valueText: String?
    let unit: String?
    let effectiveDate: String   // ISO-8601 ("2024-01-15" or full timestamp)
    let category: String        // "vital" | "lab" | "other"
}

struct ExpectedDoc: Codable, Equatable {
    let patients: [ExpectedPatient]
    let observations: [ExpectedObservation]
}

// MARK: - Matching

enum MatchOutcome: String, Codable, Equatable {
    case hit, partial, missedRejected, missedAbsent, hallucinated
}

struct FieldErrors: Codable, Equatable {
    var value: Bool
    var unit: Bool
    var category: Bool
    var date: Bool
}

struct MatchRecord: Codable, Equatable {
    let loinc: String
    let outcome: MatchOutcome
    let fieldErrors: FieldErrors?   // populated only for .partial
}

// MARK: - Per-case score

struct F1: Codable, Equatable {
    let precision: Double
    let recall: Double
    let f1: Double
}

struct PatientCorrectness: Codable, Equatable {
    let distinctCountCorrect: Bool
    let identityCorrect: Bool
}

struct CaseScore: Codable, Equatable {
    let fixture: String
    let model: String
    let sample: Int
    let catastrophic: Bool
    let strict: F1
    let lenient: F1
    let skipHistogram: [String: Int]
    let matches: [MatchRecord]
    let patient: PatientCorrectness
}

// MARK: - Aggregate

struct AggregateF1: Codable, Equatable {
    let mean: Double
    let stdev: Double
    let n: Int
}

struct FixtureModelStats: Codable, Equatable {
    let fixture: String
    let model: String
    let strictF1: AggregateF1
    let lenientF1: AggregateF1
    let outputConsistency: Double
    let catastrophicRate: Double
}

struct RunResults: Codable, Equatable {
    let promptHashes: [String]   // distinct prompt hashes across the run (one per distinct fixture prompt)
    let stats: [FixtureModelStats]
}

// MARK: - Provenance / raw

struct Manifest: Codable, Equatable {
    let timestamp: String        // filesystem-sanitized run-dir name (colons -> "-"); NOT ISO-parseable
    let referenceDateISO: String // UNsanitized ISO-8601 instant of the run; the deterministic `now` for
                                 // offline rescoring (Finding 3) — same Date() that built `timestamp`
    let promptHashes: [String]   // distinct prompt hashes seen across the run — NOT a single value (Fix 5)
    let models: [String]
    let sampleCount: Int
    let fixtureNames: [String]
}

struct RawArtifact: Codable, Equatable {
    let key: String
    let promptHash: String       // per-case (authoritative) prompt hash; also embedded in `key`
    let inputHash: String
    let model: String
    let fixture: String
    let sample: Int
    let jsonText: String
    let inputTokens: Int?
    let outputTokens: Int?
    let stopReason: String?
    let latencyMillis: Int?
}
