import Foundation

/// A single candidate prompt: a human-authored template whose body MUST contain exactly one
/// `{{DOCUMENT}}` placeholder (plan §4.1). The harness renders the per-fixture prompt by substituting
/// the page-numbered document block for the placeholder (`IterateCore.renderPrompt`). `id` is the source
/// `.txt` filename stem — a stable, lexically-ordered variant identifier used for resume keying.
struct PromptVariant: Codable, Equatable {
    let id: String
    let template: String
}

/// The full outcome of a champion-vs-challenger comparison (`IterateCore.selectWinner`, plan §4.2). A
/// superset of the journal's `DecisionRecord`: it additionally names the fixture that blocked a
/// per-fixture regression (Task 5c) so the journal can record *why* a per-fixture-regressing challenger
/// was held back. `blockingFixture` is nil unless condition 3 (per-fixture regression) fired.
struct WinnerDecision: Codable, Equatable {
    let promoted: Bool
    let deltaMean: Double
    let seDiff: Double
    let blockingFixture: String?
    let reason: String
}

/// The decision rationale persisted in a journal entry (plan §4.3). Includes `blockingFixture` (§4.2
/// requires the journal to record which fixture blocked a per-fixture-regressing promotion) — it mirrors
/// `WinnerDecision`, so a `DecisionRecord` is built directly from one.
struct DecisionRecord: Codable, Equatable {
    let promoted: Bool
    let deltaMean: Double
    let seDiff: Double
    let blockingFixture: String?
    let reason: String

    init(promoted: Bool, deltaMean: Double, seDiff: Double, blockingFixture: String?, reason: String) {
        self.promoted = promoted
        self.deltaMean = deltaMean
        self.seDiff = seDiff
        self.blockingFixture = blockingFixture
        self.reason = reason
    }

    init(_ decision: WinnerDecision) {
        self.init(promoted: decision.promoted, deltaMean: decision.deltaMean, seDiff: decision.seDiff,
                  blockingFixture: decision.blockingFixture, reason: decision.reason)
    }
}

/// One append-only journal record (plan §4.3) — EVERY evaluation, success or failure. On a failure entry
/// the metric/hash/runDir/decision fields are nil and `failure` carries a short error summary (NO PHI).
struct JournalEntry: Codable, Equatable {
    let variantId: String
    let promptHash: String?       // nil only for a failure entry that never produced a run
    let strictF1Mean: Double?     // nil on failure
    let strictF1Stdev: Double?    // nil on failure
    let sampleCount: Int          // total samples pooled (n); 0 on failure
    let runDir: String?           // relative path for traceability; nil on failure
    let evaluatedAt: String       // ISO-8601
    let decision: DecisionRecord? // nil on failure
    let failure: String?          // nil = evaluated OK; non-nil = error summary (NO PHI)
}

/// Batch parameters persisted in the journal header; compared on resume to refuse incomparable mixes
/// (plan §4.7 step 4). `subjectDOB` is included because cases are scored against it (the before-DOB
/// plausible-date guard) — a resume with a different --subject-dob would silently change the fitness.
/// Optional → legacy journals without the key decode as nil (backward compatible).
struct IterateConfig: Codable, Equatable {
    let models: [String]
    let samples: Int
    let fixturesRoot: String
    let noiseThreshold: Double
    let minImprovement: Double
    let minImprovementLowN: Double
    let maxFixtureRegression: Double
    let subjectDOB: String?
}

/// The append-only iterate journal (plan §4.3): a session id, the batch config, and the ordered entries.
struct IterateJournal: Codable, Equatable {
    let session: String
    let config: IterateConfig
    var entries: [JournalEntry]
}
