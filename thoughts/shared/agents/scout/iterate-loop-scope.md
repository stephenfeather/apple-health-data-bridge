# Scope Report: `bridge-eval iterate` Subcommand
Generated: 2026-06-29
Scout: ref=main, all file:line citations verified via agent-gh

---

## Q1 — The mutable surface: `ExtractionPrompt.make`

**File:** `Sources/HealthBridgeParsing/ExtractionPrompt.swift`

✓ VERIFIED — exact signature:

```swift
public static func make(pages: [String]) -> String
```

Takes ONLY `pages: [String]`. No existing parameter or override for prompt text or template. The function is a pure string builder: it embeds the page text into a fixed multi-paragraph string literal and returns it. The only way to vary the prompt text today is to vary the input pages — there is no template slot, no `systemPrompt:` override, no `instructions:` parameter.

**The injection gap is total.** The iterate loop's mutable surface has no foothold in the current API. Adding one requires a code change. The question is where: in `ExtractionPrompt.make` (HealthBridgeParsing, production source) or in `RunCore.runCase` (bridge-eval-only). The design intent is bridge-eval-only changes — see §Q7 below.

---

## Q2 — The frozen harness: prompt flow in `RunCore.runCase`

**File:** `Sources/bridge-eval/RunCommand.swift`

✓ VERIFIED — annotated excerpt from `RunCore.runCase`:

```swift
static func runCase(pdfData: Data, pages: [String], model: String, fixture: String, sample: Int,
                    extractor: any LLMExtractor, expected: ExpectedDoc, subjectId: String,
                    subjectDOB: Date? = nil,
                    now: Date) async throws -> (raw: RawArtifact, score: CaseScore) {
    let prompt = ExtractionPrompt.make(pages: pages)          // ← prompt is built here, no override
    let promptHash = Hashing.promptHash(prompt)               // ← SHA-256(prompt.utf8)
    let inputHash = Hashing.sha256Hex(pdfData)
    let request = LLMRequest(pages: pages, instructions: prompt, model: model)
    ...
    let key = ArtifactWriter.key(promptHash: promptHash, model: model, fixture: fixture, sample: sample)
    let raw = RawArtifact(key: key, promptHash: promptHash, inputHash: inputHash, ...)
```

**Where to thread in the candidate-prompt override:**
Add `promptOverride: String? = nil` as a parameter to `RunCore.runCase`. The body becomes:
```
let prompt = promptOverride ?? ExtractionPrompt.make(pages: pages)
```
All downstream code (`promptHash`, `LLMRequest.instructions`, `ArtifactWriter.key`, `RawArtifact.promptHash`) then flows off the overridden value automatically. The `promptHash` in every artifact will correctly fingerprint the variant — the harness's provenance spine works unchanged.

`RunCore` is internal to the `bridge-eval` target (no `public` modifier). This change never touches `HealthBridgeParsing`.

**How `promptHash` flows into the manifest:**
`RunCommand.run()` computes `ExtractionPrompt.make(pages: pages)` a SECOND time in its pre-pass loop (to fill `promptHashSet` before the network loop). When `iterate` calls `RunCore.runCase` with a `promptOverride`, the manifest pre-pass must also use that override value — otherwise `manifest.promptHashes` will record the default hash. Flag: the pre-pass in `RunCommand.run()` is inside the macOS-guarded `run()` method and is not easily reused. `IterateCommand` will likely re-implement or extract a thin helper to build the per-variant manifest.

---

## Q3 — The fitness function: aggregate F1 in `results.json`

**File:** `Sources/bridge-eval/Aggregator.swift` (the function), `Sources/bridge-eval/EvalModels.swift` (the types)

✓ VERIFIED — function:

```swift
enum Aggregator {
    static func aggregate(_ scores: [CaseScore], promptHashes: [String]) -> RunResults
```

Groups `[CaseScore]` by `(fixture, model)`, computes population stdev over N samples per group.

**results.json shape** (`RunResults` → `[FixtureModelStats]`):

```swift
struct RunResults: Codable, Equatable {
    let promptHashes: [String]       // distinct prompt hashes across the run
    let stats: [FixtureModelStats]
}

struct FixtureModelStats: Codable, Equatable {
    let fixture: String
    let model: String
    let strictF1: AggregateF1        // ← headline metric
    let lenientF1: AggregateF1
    let outputConsistency: Double
    let catastrophicRate: Double
}

struct AggregateF1: Codable, Equatable {
    let mean: Double                  // ← champion comparison target
    let stdev: Double                 // ← noise-aware comparison input
    let n: Int
}
```

The noise-aware decision rule for iterate will use `strictF1.mean` and `strictF1.stdev` from the challenger's `RunResults.stats` versus the current champion's. `Aggregator.aggregate` is already the correct function to call on each variant's `[CaseScore]` batch.

---

## Q4 — Subcommand registration

**File:** `Sources/bridge-eval/BridgeEval.swift`

✓ VERIFIED:

```swift
@main
struct BridgeEval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bridge-eval",
        abstract: "Evaluate LLM PDF-extraction responses against gold fixtures.",
        subcommands: [RunCommand.self, ScoreCommand.self, ReportCommand.self])
}
```

Add `IterateCommand.self` to the `subcommands:` array — that is the only registration change.

**House style for @Option/@Argument** (from `RunCommand`):

```swift
@Option(name: .long, help: "...")                          // --fixtures, --runs-root, etc.
@Option(name: .long, parsing: .upToNextOption, help: "...") var models: [String]   // multi-value
@Option(name: .customLong("subject-dob"), help: "...")     // kebab-case long name
```

No `@Argument` positional args used in any existing subcommand — everything is `@Option`.

`validate()` is used in `RunCommand` for structured cross-option validation (the `--subject-dob` format check). `IterateCommand` should follow the same pattern for any cross-option constraint (e.g. budget > 0, variants file must exist).

**Test pattern for registration** (`Tests/BridgeEvalTests/RootCommandTests.swift`):

```swift
func testRootHasThreeSubcommands() {
    let names = BridgeEval.configuration.subcommands.map { $0.configuration.commandName }
    XCTAssertEqual(Set(names.compactMap { $0 }), ["run", "score", "report"])
}
```

The first test to write for iterate: assert the set includes `"iterate"` (four subcommands).

---

## Q5 — Run dir layout and Manifest struct

**Files:** `Sources/bridge-eval/ArtifactWriter.swift`, `Sources/bridge-eval/EvalModels.swift`

✓ VERIFIED — on-disk layout:

```
<runs-root>/<timestamp>/
  manifest.json                    # Manifest — provenance, NO PHI
  raw/<promptHash__model__fixture__sample>.json   # RawArtifact
  scored/<promptHash__model__fixture__sample>.json # CaseScore
  results.json                     # RunResults (fitness numbers)
```

✓ VERIFIED — `Manifest` struct as merged (includes Track C `subjectDOB`):

```swift
struct Manifest: Codable, Equatable {
    let timestamp: String           // filesystem-sanitized (colons → "-")
    let referenceDateISO: String    // ISO-8601; deterministic `now` for offline rescore
    let promptHashes: [String]      // distinct per-fixture prompt hashes
    let models: [String]
    let sampleCount: Int
    let fixtureNames: [String]
    let subjectDOB: String?         // RAW yyyy-MM-dd; nil = --subject-dob omitted (Track C)
}
```

**Where the iterate journal would live:**
The iterate loop sits above individual run dirs. Natural placement:

```
<iterate-root>/<session-timestamp>/
  variants.json       # input: the curated variant set (read-only during the loop)
  journal.json        # append-only champion history: [ChampionEntry]
  runs/               # one run dir per evaluated variant (standard layout inside)
    <variant-0-timestamp>/
    <variant-1-timestamp>/
    ...
```

`<iterate-root>` defaults to `eval/iterate/` (mirroring `eval/runs/` for single runs). The Preflight guard already refuses tracked paths — the same guard applies to the iterate root.

`ChampionEntry` is a new type (does not exist). Minimum shape:

```swift
struct ChampionEntry: Codable {
    let variantId: String          // stable id from the variants file
    let promptHash: String
    let strictF1Mean: Double
    let strictF1Stdev: Double
    let sampleCount: Int
    let runDir: String             // relative path for traceability
    let promotedAt: String         // ISO-8601
}
```

---

## Q6 — Existing test patterns and the offline seam for iterate

**File:** `Tests/BridgeEvalTests/ScoreCommandTests.swift`, `Tests/BridgeEvalTests/RunCommandTests.swift`

✓ VERIFIED — the house pattern for zero-network offline testing:

**Pattern A — stub the extractor protocol** (RunCommandTests):
```swift
private struct StubExtractor: LLMExtractor {
    let response: LLMRawResponse
    func extract(_ request: LLMRequest) async throws -> LLMRawResponse { response }
}
// Then call RunCore.runCase(..., extractor: StubExtractor(json: goodJSON), ...)
```

**Pattern B — build artifacts directly, call *Core functions** (ScoreCommandTests):
```swift
func raw(_ jsonText: String) -> RawArtifact { RawArtifact(key: "abc__m__vitals-basic__0", ...) }
let score = ScoreCore.rescore(raw: raw(goodJSON), expected: expectedDoc(), subjectId: "subj", now: fixedNow)
```

**Pattern C — write to NSTemporaryDirectory, run the AsyncParsableCommand.run()** (ScoreCommandTests `testScoreCommandUsesManifestReferenceDateNotWallClock`):
```swift
let runDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bridge-eval-X-\(UUID())")
try ArtifactWriter.writeManifest(manifest, runDir: runDir)
var cmd = ScoreCommand(); cmd.runDir = runDir.path; try await cmd.run()
let scores = try ArtifactReader.readScores(runDir: runDir)
```

**The seam for iterate's unit tests:**

Extract an `IterateCore` enum (following `RunCore`/`ScoreCore`) with pure functions:

```swift
enum IterateCore {
    static func selectWinner(champion: AggregateF1, challenger: AggregateF1,
                             noiseThreshold: Double) -> WinnerDecision
    static func appendJournal(entry: ChampionEntry, journalURL: URL) throws
    static func loadVariants(from url: URL) throws -> [PromptVariant]
}
```

These three functions require zero network, zero PDFKit, zero API keys — each is independently unit-testable with synthetic `AggregateF1` values and temp-dir journal files. The `IterateCommand.run()` shell (macOS-guarded, calls `RunCore.runCase` for actual network work) is only integration-tested manually, exactly like `RunCommand.run()` today.

The key isolation: `IterateCore.selectWinner` takes `AggregateF1` structs (already in EvalModels, no new dependencies), so the entire decision logic is a pure function with no I/O seam needed.

---

## Q7 — Reusable seams vs. gaps

### Reusable as-is (✓ VERIFIED)

| Component | File | What iterate uses it for |
|---|---|---|
| `RunCore.runCase` | RunCommand.swift | Per-variant live evaluation (with a new `promptOverride:` parameter) |
| `ScoreCore.rescore` | ScoreCommand.swift | Not directly — RunCore already scores; but available for batch rescore |
| `Aggregator.aggregate` | Aggregator.swift | Compute per-variant `RunResults` (fitness numbers) |
| `ArtifactWriter` | ArtifactWriter.swift | Write per-variant run dirs identically to `run` subcommand |
| `ArtifactReader` | ArtifactReader.swift | Read back scores to compare vs. champion |
| `LLMExtractor` protocol | HealthBridgeParsing | Stub pattern for offline tests |
| `Manifest`, `RunResults`, `AggregateF1`, `CaseScore`, `FixtureModelStats` | EvalModels.swift | All structs reused directly; no new fields needed |
| `Preflight.assertUntracked` | Preflight.swift | Guard the iterate-root path (same PHI safety) |
| `Hashing.promptHash` | Hashing.swift | Fingerprint each variant's prompt string |

### Must be newly built (gaps)

| Gap | Scope | Notes |
|---|---|---|
| `promptOverride: String? = nil` param on `RunCore.runCase` | bridge-eval-only (RunCommand.swift) | One-line change to internal function; zero HealthBridgeParsing impact |
| `PromptVariant` type and variants-file loader | bridge-eval-only | Simple `Codable` struct: `{ id: String, prompt: String }` + JSON load |
| `ChampionEntry` type | bridge-eval-only | New Codable struct (shape in §Q5 above) |
| `IterateJournal` write helper (append-only) | bridge-eval-only | Reads existing array, appends, rewrites atomically (or line-append JSONL) |
| `IterateCore` enum | bridge-eval-only | Pure functions: selectWinner, appendJournal, loadVariants |
| `IterateCommand` struct | bridge-eval-only | AsyncParsableCommand; macOS-guarded run() like RunCommand |
| `BridgeEval.subcommands` registration | bridge-eval-only (BridgeEval.swift) | Add `IterateCommand.self` |
| `IterateCommandTests` + `IterateCoreTests` | Tests/BridgeEvalTests/ | Unit tests for IterateCore pure functions; registration test |

### Production-source changes required? No.

`ExtractionPrompt.make` does NOT need to change. The override is injected at the bridge-eval call site (`RunCore.runCase`), which is internal to the bridge-eval target. `HealthBridgeParsing` is untouched. This matches the design intent (§11: "drops in without reshaping anything here").

The only file outside `Sources/bridge-eval/` that would be touched is `BridgeEval.swift` itself to register the new subcommand — which is also in `Sources/bridge-eval/`.

### One flag to watch

The `RunCommand.run()` pre-pass re-computes `ExtractionPrompt.make(pages:)` independently to build `promptHashSet` for the `Manifest`. If `IterateCommand` reuses `RunCore.runCase` with a `promptOverride`, it will need its own manifest-building logic that uses the override rather than re-deriving from pages. Either extract a shared `buildPromptHashes(variants:pages:)` helper or let `IterateCommand` build the manifest directly — it is not a blocker, but it should be called out explicitly in the TDD plan so the implementation does not accidentally write the default hash into the iterate manifest.

---

## Architecture map

```
IterateCommand.run()      [new, macOS-guarded]
  │
  ├── IterateCore.loadVariants()       [new, pure]
  │     reads variants.json → [PromptVariant]
  │
  ├── for each variant:
  │     RunCore.runCase(..., promptOverride: variant.prompt)   [existing + 1 param]
  │       └── ExtractionPrompt.make(pages:) OR promptOverride  [existing, unchanged]
  │           └── LLMRequest → extractor.extract()
  │     Aggregator.aggregate(scores)                           [existing]
  │     IterateCore.selectWinner(champion, challenger)         [new, pure]
  │     IterateCore.appendJournal(entry)                       [new, pure-ish]
  │
  └── print final champion summary
```

```
Tests (zero network):
  IterateCoreTests
    testSelectWinnerChallengerBetterByThreshold  → IterateCore.selectWinner  (pure AggregateF1)
    testSelectWinnerNoiseFloor                   → IterateCore.selectWinner  (stdev guard)
    testAppendJournalRoundTrip                   → IterateCore.appendJournal (temp dir)
    testLoadVariantsValid                        → IterateCore.loadVariants  (temp JSON)
  RootCommandTests (extension)
    testRootHasFourSubcommands                   → BridgeEval.configuration
```
