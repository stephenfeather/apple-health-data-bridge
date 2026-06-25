# bridge-eval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development — dispatch each `### Task N` block to a fresh subagent, one task per dispatch, in order. Each task is self-contained: it names the exact files, the exact Swift signatures it consumes/produces, and bite-sized red→green→commit steps with the FULL code to type. Do not skip the failing-test step. Do not batch tasks. Run the named test after each step and confirm the stated expected result before moving on.

- **Date:** 2026-06-25
- **Design source of truth:** `thoughts/shared/plans/2026-06-24-bridge-eval-design.md`
- **API surface source of truth:** `thoughts/shared/agents/scout/bridge-eval-api-surface.md`
- **Worktree:** `.claude/worktrees/bridgekit-eval` (base `main`, 6523551)
- **Premortem fixes folded in (2026-06-25):** date-parser unification (Task 4), missedRejected display-name linkage (Task 5), N=1 stdev (Tasks 6 & 11), manifest-first write (Task 12), per-run distinct prompt hashes (Tasks 3, 6, 10, 11, 12).

## Goal

Build a dev-only SwiftPM executable target `bridge-eval`: an offline-first LLM-extraction evaluation harness for the M3 PDF path. It reproduces the production extraction pipeline step-by-step (no reimplementation of parsing/contract logic), scores each model response against hand-verified gold fixtures, and emits machine-readable fitness numbers. v1 ships three subcommands: `run` (network), `score` (pure), `report` (pure). It is declared as a `.executableTarget` but NOT added to `products` — it never ships in the `healthbridge` binary.

## Architecture

The harness calls the production pipeline's PUBLIC steps directly, in sequence, teeing off each intermediate (this is cleaner for instrumentation than routing through `PDFExtractor.extractDocument`, which discards the raw JSON):

```
PDFText.pages(data) -> [String]                              (macOS-guarded)
ExtractionPrompt.make(pages:) -> String                      (pure)
LLMRequest(pages:instructions:model:)                        (pure)
extractor.extract(request) -> LLMRawResponse                 (network; stubbed in tests)
LLMResponseContract.distinctPatientCount(jsonText) -> Int    (pure)
LLMResponseContract.extractedPatient(jsonText) -> (name,dob)?(pure)
LLMResponseContract.decode(jsonText, subjectId:..) -> ParseResult  (pure)
```

Two layers, built pure-first:

1. **Pure core (platform-free, unit-tested everywhere, zero network/zero keys):** Codable artifact models, CryptoKit hashing helpers, Matcher (predicted vs expected observations), Scorer (`ParseResult` + `ExpectedDoc` -> `CaseScore`), Aggregator (`[CaseScore]` -> `RunResults`), Fixtures loader + git-tracked preflight guard, plus the `score` and `report` subcommands.
2. **Network shell (macOS-guarded, never in CI):** the `run` subcommand — PDF read, prompt build, real adapter call, artifact writing.

~80% of the harness (everything except `run`'s PDF/network legs) is TDD-able with synthetic fixtures and a stub `LLMExtractor`.

### Run-directory layout (design §7)
```
<runs-root>/<timestamp>/
  manifest.json      # promptHashes (distinct, per-run), models, params, sampleCount — NO PHI
  raw/<key>.json     # full LLM envelope (jsonText + meta) + per-case promptHash — replay/research input
  scored/<key>.json  # decoded result + per-case CaseScore
  results.json       # aggregate RunResults (the fitness objective)
```
Key format: `<promptHash>__<model>__<fixture>__<sample>`. Each fixture has its OWN page set → its OWN prompt → its OWN `promptHash`, so the per-case hash lives in the artifact key AND in each raw/scored artifact; the manifest records the DISTINCT set across the run (premortem Fix 5).

## Tech Stack

- Swift tools 5.9; platforms `.macOS(.v13)`, `.iOS(.v16)`.
- `swift-argument-parser` 1.8.2 (already a package dependency) — `@main AsyncParsableCommand`, mirroring `Sources/healthbridge/HealthBridge.swift`.
- **CryptoKit** (Apple-native, macOS-only — the harness is macOS-only anyway). SHA-256 hex via `SHA256.hash(data:).map { String(format: "%02x", $0) }.joined()`, exactly as `BridgeBuilder.sha256Hex` already does. **ZERO new package dependency. Do NOT add swift-crypto.**
- `HealthBridgeParsing` + `BridgeKit` for the production types and pipeline steps.
- XCTest, `@testable import`, `Bundle.module.url(forResource:withExtension:)`, `.copy("Fixtures")`.

## Global Constraints

1. **Swift 5.9 only.** No language features past 5.9.
2. **macOS guard rules.** `PDFText.pages` and `extractDocument` are `#if canImport(PDFKit) && os(macOS)` guarded. So the `run` command and its PDF reads MUST be wrapped in `#if canImport(PDFKit) && os(macOS)`. The pure core (models, hashing, matcher, scorer, aggregator, fixtures, guard, `score`, `report`) operates only on `Observation`/`ParseResult`/`Skip`/expected types — NO PDFKit — and MUST stay platform-free so it unit-tests everywhere.
3. **CryptoKit not swift-crypto.** Compute SHA-256 with `import CryptoKit`. No new package dependency.
4. **Exact numeric grading (design §13.1).** A predicted numeric value must equal gold exactly to score a Hit; a rounding/unit slip -> Partial. No tolerance knob in v1.
5. **Separate subcommands from day one (design §13.2).** `run` (network), `score` (pure), `report` (pure) are distinct subcommands. NO `iterate`/`research` loop in v1.
6. **Gitignore + preflight (design §9, §13.3).** Add `.gitignore` entries for `eval/fixtures/` and `eval/runs/` UP FRONT (Task 1). The preflight guard REFUSES to read fixtures from, or write artifacts into, a git-TRACKED path — fail loud.
7. **Public repo — synthetic fixtures only.** Never commit real PHI. Committed tests use Tier A synthetic data (Jane Public / John Sample style) ONLY. Real PDFs + `expected.json` are Tier B, gitignored, never in-tree.
8. **Reuse, don't reimplement.** The harness calls the real `LLMResponseContract` / `ExtractionPrompt` / `PDFText` — it never re-derives parsing or contract logic. This includes DATE PARSING: the Matcher parses expected dates with the SAME `LLMResponseContract.parseDate` the production decoder uses (premortem Fix 1), so both sides land on the same UTC day. The only re-implementation allowed is minimal JSON artifact writing (because `RawResponseLog` lives in the un-importable `healthbridge` executable target — design constraint, scout §7).
9. **Commits.** Plan shows conventional `git add <files>` + a single-line message; the executor translates to the repo's `github-agent-commit` helper. No HEREDOC, no `#` lines in messages.

---

### Task 1: Package wiring + gitignore + smoke test

**Files**
- modify `Package.swift`
- create `Sources/bridge-eval/BridgeEval.swift`
- modify `.gitignore`
- create `Tests/BridgeEvalTests/SmokeTests.swift`

**Interfaces**
- Produces: `enum BridgeEvalVersion { static let current: String }` (trivial, just to give the smoke test something real to assert and prove the target compiles + links).

**Steps**

- [ ] Add the executable target and test target to `Package.swift`. Insert into the `targets:` array (after the `healthbridge` executableTarget, before the test targets):
  ```swift
  .executableTarget(
      name: "bridge-eval",
      dependencies: [
          "HealthBridgeParsing", "BridgeKit",
          .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
  ),
  ```
  and add this test target alongside the existing `.testTarget(...)` entries:
  ```swift
  .testTarget(
      name: "BridgeEvalTests",
      dependencies: ["bridge-eval", "HealthBridgeParsing", "BridgeKit"],
      resources: [.copy("Fixtures")]
  ),
  ```
  Do NOT add `bridge-eval` to `products:` — it stays dev-only.
- [ ] Add gitignore entries. Append to `.gitignore`:
  ```
  # bridge-eval harness — synthetic fixtures are committed in Tests/; these are the
  # local-only Tier B real-PHI fixtures and run artifacts. Never commit.
  eval/fixtures/
  eval/runs/
  ```
- [ ] Create the version stub so the smoke test has a real symbol. Write `Sources/bridge-eval/BridgeEval.swift`:
  ```swift
  import Foundation

  /// bridge-eval — dev-only LLM-extraction evaluation harness. NOT shipped in `healthbridge`.
  /// `@main` root + subcommands are wired in Task 13; this stub exists so Task 1 proves the
  /// target compiles and links before any feature code lands.
  enum BridgeEvalVersion {
      static let current = "0.1.0"
  }
  ```
- [ ] Create the Fixtures resource dir so `.copy("Fixtures")` resolves. Run:
  ```bash
  mkdir -p Tests/BridgeEvalTests/Fixtures
  touch Tests/BridgeEvalTests/Fixtures/.gitkeep
  ```
- [ ] Write the failing smoke test. Write `Tests/BridgeEvalTests/SmokeTests.swift`:
  ```swift
  import XCTest
  @testable import bridge_eval

  final class SmokeTests: XCTestCase {
      func testVersionIsPresent() {
          XCTAssertEqual(BridgeEvalVersion.current, "0.1.0")
      }
  }
  ```
- [ ] Run it and expect it to PASS (this task's "red" is really "does it compile and wire up"): `swift test --filter BridgeEvalTests.SmokeTests`. Expected: 1 test passes, target links. If the module name import fails, note SPM maps `bridge-eval` -> `bridge_eval` for `import`; the test uses `@testable import bridge_eval`.
- [ ] Commit:
  ```bash
  git add Package.swift .gitignore Sources/bridge-eval/BridgeEval.swift Tests/BridgeEvalTests/SmokeTests.swift Tests/BridgeEvalTests/Fixtures/.gitkeep
  git commit -m "chore(eval): scaffold dev-only bridge-eval target, tests, and gitignore guards"
  ```

---

### Task 2: Hashing — CryptoKit SHA-256 hex helpers

**Files**
- create `Sources/bridge-eval/Hashing.swift`
- create `Tests/BridgeEvalTests/HashingTests.swift`

**Interfaces**
- Produces:
  ```swift
  enum Hashing {
      static func sha256Hex(_ data: Data) -> String        // hex digest of arbitrary bytes (inputHash from PDF bytes)
      static func promptHash(_ prompt: String) -> String    // sha256Hex of prompt.utf8
  }
  ```

**Steps**

- [ ] Write the failing test with a known SHA-256 vector. Write `Tests/BridgeEvalTests/HashingTests.swift`:
  ```swift
  import XCTest
  @testable import bridge_eval

  final class HashingTests: XCTestCase {
      // SHA-256("abc") known vector.
      private let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

      func testSha256HexEmptyData() {
          // SHA-256 of zero bytes, known vector.
          XCTAssertEqual(Hashing.sha256Hex(Data()),
                         "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
      }

      func testSha256HexKnownVector() {
          XCTAssertEqual(Hashing.sha256Hex(Data("abc".utf8)), abcDigest)
      }

      func testPromptHashMatchesUTF8Bytes() {
          XCTAssertEqual(Hashing.promptHash("abc"), abcDigest)
      }

      func testPromptHashIsStableAndDistinct() {
          XCTAssertEqual(Hashing.promptHash("prompt v1"), Hashing.promptHash("prompt v1"))
          XCTAssertNotEqual(Hashing.promptHash("prompt v1"), Hashing.promptHash("prompt v2"))
      }
  }
  ```
- [ ] Run it and expect FAILURE: `swift test --filter BridgeEvalTests.HashingTests`. Expected: compile error / unresolved `Hashing` (red).
- [ ] Write the minimal implementation. Write `Sources/bridge-eval/Hashing.swift`:
  ```swift
  import Foundation
  import CryptoKit

  /// SHA-256 hex helpers. CryptoKit is Apple-native (macOS) — the harness is macOS-only, so this
  /// adds ZERO package dependency. Mirrors `BridgeBuilder.sha256Hex`'s lowercase-hex format so eval
  /// digests are comparable to the shipping CLI's `contentSHA256`.
  enum Hashing {
      static func sha256Hex(_ data: Data) -> String {
          SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      }

      static func promptHash(_ prompt: String) -> String {
          sha256Hex(Data(prompt.utf8))
      }
  }
  ```
- [ ] Run it and expect PASS: `swift test --filter BridgeEvalTests.HashingTests`. Expected: 4 tests pass.
- [ ] Commit:
  ```bash
  git add Sources/bridge-eval/Hashing.swift Tests/BridgeEvalTests/HashingTests.swift
  git commit -m "feat(eval): add CryptoKit SHA-256 hex helpers for prompt and input hashing"
  ```

---

### Task 3: EvalModels — Codable artifact types

**Files**
- create `Sources/bridge-eval/EvalModels.swift`
- create `Tests/BridgeEvalTests/EvalModelsTests.swift`

The artifact model `ExpectedObservation` mirrors the contract's `ObservationDTO` shape (loinc/display/value/valueText/unit/effectiveDate/category) so `expected.json` compares like-to-like with the contract output (design §5). `effectiveDate` is stored as an ISO-8601 string and parsed by the Matcher to a UTC calendar day VIA `LLMResponseContract.parseDate` (one source of truth — premortem Fix 1). Numeric value vs qualitative value is represented by which of `value`/`valueText` is present — mirroring `ObservationDTO`.

**Premortem Fix 5 — per-run distinct prompt hashes:** each fixture produces a different prompt and therefore a different `promptHash`. A single manifest-level `promptHash` would be misleading (it would only record one fixture's hash). So `Manifest` carries `promptHashes: [String]` (the DISTINCT hashes seen across the run, sorted) and `RunResults` carries `promptHashes: [String]` likewise. The authoritative per-case hash lives in the artifact key and in each `RawArtifact.promptHash`.

**Interfaces**
- Produces:
  ```swift
  struct ExpectedPatient: Codable, Equatable { let name: String; let dob: String }
  struct ExpectedObservation: Codable, Equatable {
      let loinc: String
      let display: String?
      let value: Double?
      let valueText: String?
      let unit: String?
      let effectiveDate: String   // ISO-8601, e.g. "2024-01-15" or full timestamp
      let category: String        // "vital"|"lab"|"other"
  }
  struct ExpectedDoc: Codable, Equatable { let patients: [ExpectedPatient]; let observations: [ExpectedObservation] }

  enum MatchOutcome: String, Codable, Equatable { case hit, partial, missedRejected, missedAbsent, hallucinated }
  struct FieldErrors: Codable, Equatable { var value: Bool; var unit: Bool; var category: Bool; var date: Bool }
  struct MatchRecord: Codable, Equatable {
      let loinc: String
      let outcome: MatchOutcome
      let fieldErrors: FieldErrors?   // populated only for .partial
  }

  struct F1: Codable, Equatable { let precision: Double; let recall: Double; let f1: Double }
  struct PatientCorrectness: Codable, Equatable { let distinctCountCorrect: Bool; let identityCorrect: Bool }
  struct CaseScore: Codable, Equatable {
      let fixture: String
      let model: String
      let sample: Int
      let catastrophic: Bool            // decode threw ParseError.malformed
      let strict: F1                    // hits only
      let lenient: F1                   // partials = 0.5
      let skipHistogram: [String: Int]  // skip detail-key -> count
      let matches: [MatchRecord]
      let patient: PatientCorrectness
  }

  struct AggregateF1: Codable, Equatable { let mean: Double; let stdev: Double; let n: Int }
  struct FixtureModelStats: Codable, Equatable {
      let fixture: String
      let model: String
      let strictF1: AggregateF1
      let lenientF1: AggregateF1
      let outputConsistency: Double     // mean pairwise agreement across samples (0...1)
      let catastrophicRate: Double
  }
  struct RunResults: Codable, Equatable { let promptHashes: [String]; let stats: [FixtureModelStats] }

  struct Manifest: Codable, Equatable {
      let timestamp: String
      let promptHashes: [String]        // distinct prompt hashes seen across the run (Fix 5)
      let models: [String]
      let sampleCount: Int
      let fixtureNames: [String]
  }

  struct RawArtifact: Codable, Equatable {
      let key: String          // <promptHash>__<model>__<fixture>__<sample>
      let promptHash: String   // per-case (authoritative) prompt hash
      let inputHash: String
      let model: String
      let fixture: String
      let sample: Int
      let jsonText: String     // verbatim LLM reply (pre-trim)
      let inputTokens: Int?
      let outputTokens: Int?
      let stopReason: String?
      let latencyMillis: Int?
  }
  ```

**Steps**

- [ ] Write the failing round-trip test. Write `Tests/BridgeEvalTests/EvalModelsTests.swift`:
  ```swift
  import XCTest
  @testable import bridge_eval

  final class EvalModelsTests: XCTestCase {
      private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
          let data = try JSONEncoder().encode(value)
          return try JSONDecoder().decode(T.self, from: data)
      }

      func testExpectedDocDecodesContractShape() throws {
          let json = """
          {"patients":[{"name":"Jane Public","dob":"1990-05-01"}],
           "observations":[{"loinc":"8867-4","display":"Heart rate","value":72.5,"valueText":null,
                            "unit":"/min","effectiveDate":"2024-01-15","category":"vital"}]}
          """
          let doc = try JSONDecoder().decode(ExpectedDoc.self, from: Data(json.utf8))
          XCTAssertEqual(doc.patients.first?.name, "Jane Public")
          XCTAssertEqual(doc.observations.first?.loinc, "8867-4")
          XCTAssertEqual(doc.observations.first?.value, 72.5)
          XCTAssertEqual(doc.observations.first?.category, "vital")
      }

      func testCaseScoreRoundTrips() throws {
          let score = CaseScore(
              fixture: "vitals-basic", model: "claude-opus-4-8", sample: 0, catastrophic: false,
              strict: F1(precision: 1, recall: 1, f1: 1),
              lenient: F1(precision: 1, recall: 1, f1: 1),
              skipHistogram: ["noUsableValue": 1],
              matches: [MatchRecord(loinc: "8867-4", outcome: .hit, fieldErrors: nil)],
              patient: PatientCorrectness(distinctCountCorrect: true, identityCorrect: true))
          XCTAssertEqual(try roundTrip(score), score)
      }

      func testRunResultsRoundTrips() throws {
          let r = RunResults(promptHashes: ["abc", "def"], stats: [
              FixtureModelStats(fixture: "f", model: "m",
                                strictF1: AggregateF1(mean: 0.8, stdev: 0.1, n: 3),
                                lenientF1: AggregateF1(mean: 0.9, stdev: 0.05, n: 3),
                                outputConsistency: 0.66, catastrophicRate: 0.0)])
          XCTAssertEqual(try roundTrip(r), r)
      }

      func testManifestAndRawArtifactRoundTrip() throws {
          let m = Manifest(timestamp: "2026-06-25T00:00:00Z", promptHashes: ["abc", "xyz"],
                           models: ["m1", "m2"], sampleCount: 3, fixtureNames: ["f1"])
          XCTAssertEqual(try roundTrip(m), m)
          let raw = RawArtifact(key: "abc__m1__f1__0", promptHash: "abc", inputHash: "def",
                                model: "m1", fixture: "f1", sample: 0, jsonText: "{}",
                                inputTokens: 10, outputTokens: 20, stopReason: "stop", latencyMillis: 1234)
          XCTAssertEqual(try roundTrip(raw), raw)
      }
  }
  ```
- [ ] Run it and expect FAILURE: `swift test --filter BridgeEvalTests.EvalModelsTests`. Expected: unresolved types (red).
- [ ] Write the implementation. Write `Sources/bridge-eval/EvalModels.swift`:
  ```swift
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
      let timestamp: String
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
  ```
- [ ] Run it and expect PASS: `swift test --filter BridgeEvalTests.EvalModelsTests`. Expected: 4 tests pass.
- [ ] Commit:
  ```bash
  git add Sources/bridge-eval/EvalModels.swift Tests/BridgeEvalTests/EvalModelsTests.swift
  git commit -m "feat(eval): add Codable artifact models mirroring the contract output shape"
  ```

---

### Task 4: Matcher — identity matching + field grading (pure, design §6)

**Files**
- create `Sources/bridge-eval/Matcher.swift`
- create `Tests/BridgeEvalTests/MatcherTests.swift`

Identity = `(loinc, effectiveDate-at-UTC-day)`. Predicted `[Observation]` (the contract's valid output) is matched against `expected.observations`. Field grading on matched pairs: numeric value EXACT (design §13.1), qualitative value normalized string equality, unit exact UCUM string, date exact at UTC calendar day, category exact. Outcomes: `.hit` (matched + all fields correct), `.partial` (matched identity, some field wrong), `.hallucinated` (predicted, no expected match), `.missedAbsent` (expected, no predicted match). `.missedRejected` is NOT decided here — it requires the skip list and is assigned by the Scorer (Task 5); the Matcher only sees valid predictions and expected gold.

**Date parsing — ONE source of truth (premortem Fix 1 / Tiger 7):** the Matcher parses `expected.effectiveDate` with the PUBLIC `LLMResponseContract.parseDate(_ s: String) -> Date?` (verified at `LLMResponseContract.swift:257` — strict zero-padded `yyyy-MM-dd`, UTC-anchored, optional time component), the SAME parser the production decoder uses to build `Observation.effectiveDate`. The Matcher does NOT use `ISO8601DateFormatter` — that diverges on offset timestamps and could land an expected date on a different UTC day than the decoded observation, producing a FALSE identity miss. Both sides therefore reduce to the SAME UTC day. An unparseable expected date drops that gold entry from the index (it can only ever miss).

**Interfaces**
- Consumes:
  - `BridgeKit.Observation` (`code: CodeableRef?`, `value: ObservationValue`, `unit: String?`, `effectiveDate: Date`, `category: ObservationCategory`)
  - `HealthBridgeParsing.LLMResponseContract.parseDate(_ s: String) -> Date?` (the production date parser — one source of truth)
  - `ExpectedObservation`
- Produces:
  ```swift
  enum Matcher {
      static func utcDay(_ date: Date) -> Int                          // days since epoch in UTC
      static func match(predicted: [Observation], expected: [ExpectedObservation]) -> [MatchRecord]
  }
  ```

**Steps**

- [ ] Write the failing tests (error/edge first: hallucination + miss, then hit, then partial). Note the test `date(_:)` helper also uses `LLMResponseContract.parseDate` so the test and SUT agree on day boundaries. Write `Tests/BridgeEvalTests/MatcherTests.swift`:
  ```swift
  import XCTest
  import BridgeKit
  import HealthBridgeParsing
  @testable import bridge_eval

  final class MatcherTests: XCTestCase {
      // Same parser the matcher and production decoder use — one source of truth.
      private func date(_ s: String) -> Date {
          LLMResponseContract.parseDate(s)!
      }

      private func observation(loinc: String, value: ObservationValue, unit: String?,
                               date s: String, category: ObservationCategory) -> Observation {
          Observation(id: "id-\(loinc)-\(s)",
                      code: CodeableRef(system: "http://loinc.org", code: loinc, display: loinc),
                      name: loinc, value: value, unit: unit, effectiveDate: date(s),
                      category: category, mapping: nil, confidence: 1.0, sourceLocator: nil)
      }

      private func expected(loinc: String, value: Double?, valueText: String?, unit: String?,
                            date: String, category: String) -> ExpectedObservation {
          ExpectedObservation(loinc: loinc, display: loinc, value: value, valueText: valueText,
                              unit: unit, effectiveDate: date, category: category)
      }

      func testUnparseableExpectedDateNeverMatches() {
          // A garbage expected date drops out of the index -> the prediction can only hallucinate.
          let preds = [observation(loinc: "8867-4", value: .quantity(72), unit: "/min",
                                   date: "2024-01-15", category: .vital)]
          let exp = [expected(loinc: "8867-4", value: 72, valueText: nil, unit: "/min",
                              date: "not-a-date", category: "vital")]
          let records = Matcher.match(predicted: preds, expected: exp)
          XCTAssertEqual(records.map { $0.outcome }, [.hallucinated])
      }

      func testUnmatchedPredictedIsHallucinated() {
          let preds = [observation(loinc: "8867-4", value: .quantity(72), unit: "/min",
                                   date: "2024-01-15", category: .vital)]
          let records = Matcher.match(predicted: preds, expected: [])
          XCTAssertEqual(records.count, 1)
          XCTAssertEqual(records.first?.outcome, .hallucinated)
      }

      func testUnmatchedExpectedIsMissedAbsent() {
          let exp = [expected(loinc: "8867-4", value: 72, valueText: nil, unit: "/min",
                              date: "2024-01-15", category: "vital")]
          let records = Matcher.match(predicted: [], expected: exp)
          XCTAssertEqual(records.first?.outcome, .missedAbsent)
      }

      func testExactMatchIsHit() {
          let preds = [observation(loinc: "8867-4", value: .quantity(72), unit: "/min",
                                   date: "2024-01-15", category: .vital)]
          let exp = [expected(loinc: "8867-4", value: 72, valueText: nil, unit: "/min",
                              date: "2024-01-15", category: "vital")]
          let records = Matcher.match(predicted: preds, expected: exp)
          XCTAssertEqual(records.count, 1)
          XCTAssertEqual(records.first?.outcome, .hit)
          XCTAssertNil(records.first?.fieldErrors)
      }

      func testOffsetTimestampLandsOnSameUTCDayAsDateOnly() {
          // A fixture timestamp with an offset must reduce to the SAME UTC day as the decoded
          // observation's date-only value — the whole point of unifying on parseDate (Fix 1).
          let preds = [observation(loinc: "8867-4", value: .quantity(72), unit: "/min",
                                   date: "2024-01-15", category: .vital)]
          let exp = [expected(loinc: "8867-4", value: 72, valueText: nil, unit: "/min",
                              date: "2024-01-15T08:00:00+00:00", category: "vital")]
          let records = Matcher.match(predicted: preds, expected: exp)
          XCTAssertEqual(records.first?.outcome, .hit)
      }

      func testRoundingSlipIsPartialNotHit() {
          // 72.4 vs 72.5 — exact grading => Partial, not Hit (design §13.1).
          let preds = [observation(loinc: "8867-4", value: .quantity(72.4), unit: "/min",
                                   date: "2024-01-15", category: .vital)]
          let exp = [expected(loinc: "8867-4", value: 72.5, valueText: nil, unit: "/min",
                              date: "2024-01-15", category: "vital")]
          let records = Matcher.match(predicted: preds, expected: exp)
          XCTAssertEqual(records.first?.outcome, .partial)
          XCTAssertEqual(records.first?.fieldErrors?.value, true)
          XCTAssertEqual(records.first?.fieldErrors?.unit, false)
      }

      func testWrongUnitIsPartial() {
          let preds = [observation(loinc: "718-7", value: .quantity(13), unit: "g/L",
                                   date: "2024-01-15", category: .lab)]
          let exp = [expected(loinc: "718-7", value: 13, valueText: nil, unit: "g/dL",
                              date: "2024-01-15", category: "lab")]
          let records = Matcher.match(predicted: preds, expected: exp)
          XCTAssertEqual(records.first?.outcome, .partial)
          XCTAssertEqual(records.first?.fieldErrors?.unit, true)
          XCTAssertEqual(records.first?.fieldErrors?.value, false)
      }

      func testQualitativeValueNormalizedEquality() {
          let preds = [observation(loinc: "5778-6", value: .string("  Yellow  "), unit: nil,
                                   date: "2024-01-15", category: .lab)]
          let exp = [expected(loinc: "5778-6", value: nil, valueText: "yellow", unit: nil,
                              date: "2024-01-15", category: "lab")]
          let records = Matcher.match(predicted: preds, expected: exp)
          XCTAssertEqual(records.first?.outcome, .hit)
      }

      func testSameLoincDifferentDayDoesNotMatch() {
          let preds = [observation(loinc: "8867-4", value: .quantity(72), unit: "/min",
                                   date: "2024-01-15", category: .vital)]
          let exp = [expected(loinc: "8867-4", value: 72, valueText: nil, unit: "/min",
                              date: "2024-01-16", category: "vital")]
          let records = Matcher.match(predicted: preds, expected: exp)
          XCTAssertEqual(Set(records.map { $0.outcome }), [.hallucinated, .missedAbsent])
      }
  }
  ```
- [ ] Run it and expect FAILURE: `swift test --filter BridgeEvalTests.MatcherTests`. Expected: unresolved `Matcher` (red).
- [ ] Write the implementation. Write `Sources/bridge-eval/Matcher.swift`:
  ```swift
  import Foundation
  import BridgeKit
  import HealthBridgeParsing

  /// PURE matcher (design §6). Identity = (loinc, effectiveDate at UTC calendar day). Matched pairs are
  /// graded field-by-field with EXACT numeric equality (design §13.1). Platform-free — no PDFKit — so it
  /// unit-tests everywhere. `.missedRejected` is assigned by the Scorer (it needs the skip list); the
  /// Matcher only distinguishes hit/partial/hallucinated/missedAbsent over VALID predictions vs gold.
  ///
  /// DATE PARSING is delegated to `LLMResponseContract.parseDate` — the SAME parser the production decoder
  /// uses for `Observation.effectiveDate` — so an offset timestamp in a fixture and a date-only decoded
  /// observation reduce to the SAME UTC day (premortem Fix 1). No ISO8601DateFormatter here.
  enum Matcher {
      private static let secondsPerDay = 86_400.0

      static func utcDay(_ date: Date) -> Int {
          Int((date.timeIntervalSince1970 / secondsPerDay).rounded(.down))
      }

      private struct Key: Hashable { let loinc: String; let day: Int }

      private static func normalize(_ s: String) -> String {
          s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      }

      private static func gradeValue(predicted: ObservationValue, expected: ExpectedObservation) -> Bool {
          switch predicted {
          case .quantity(let q):
              guard let want = expected.value else { return false }   // expected qualitative, got numeric
              return q == want                                         // EXACT (design §13.1)
          case .string(let s):
              guard let want = expected.valueText else { return false }
              return normalize(s) == normalize(want)
          }
      }

      static func match(predicted: [Observation], expected: [ExpectedObservation]) -> [MatchRecord] {
          // Index expected by identity; allow at most one match per expected entry. An expected date that
          // the production parser rejects drops out of the index (it can only ever be a miss).
          var expectedByKey: [Key: ExpectedObservation] = [:]
          var unmatchedExpected = Set<Key>()
          for e in expected {
              guard let d = LLMResponseContract.parseDate(e.effectiveDate) else { continue }
              let k = Key(loinc: e.loinc, day: utcDay(d))
              expectedByKey[k] = e
              unmatchedExpected.insert(k)
          }

          var records: [MatchRecord] = []
          for p in predicted {
              let loinc = p.code?.code ?? ""
              let k = Key(loinc: loinc, day: utcDay(p.effectiveDate))
              guard let e = expectedByKey[k], unmatchedExpected.contains(k) else {
                  records.append(MatchRecord(loinc: loinc, outcome: .hallucinated, fieldErrors: nil))
                  continue
              }
              unmatchedExpected.remove(k)
              let valueWrong = !gradeValue(predicted: p.value, expected: e)
              let unitWrong = (p.unit ?? "") != (e.unit ?? "")
              let categoryWrong = p.category.rawValue != e.category
              let dateWrong = false   // identity already pins the UTC day; matched pairs share it
              if !valueWrong && !unitWrong && !categoryWrong && !dateWrong {
                  records.append(MatchRecord(loinc: loinc, outcome: .hit, fieldErrors: nil))
              } else {
                  records.append(MatchRecord(loinc: loinc, outcome: .partial,
                      fieldErrors: FieldErrors(value: valueWrong, unit: unitWrong,
                                               category: categoryWrong, date: dateWrong)))
              }
          }

          for k in unmatchedExpected {
              records.append(MatchRecord(loinc: k.loinc, outcome: .missedAbsent, fieldErrors: nil))
          }
          return records
      }
  }
  ```
- [ ] Run it and expect PASS: `swift test --filter BridgeEvalTests.MatcherTests`. Expected: 9 tests pass.
- [ ] Commit:
  ```bash
  git add Sources/bridge-eval/Matcher.swift Tests/BridgeEvalTests/MatcherTests.swift
  git commit -m "feat(eval): add pure matcher unifying date parsing on the production parser"
  ```

---

### Task 5: Scorer — ParseResult + ExpectedDoc -> CaseScore (pure, design §6)

**Files**
- create `Sources/bridge-eval/Scorer.swift`
- create `Tests/BridgeEvalTests/ScorerTests.swift`

Combines Matcher output with the skip list to: (a) reclassify a `.missedAbsent` as `.missedRejected` when a `Skip` references the same expected observation (links the miss to the contract rejection, design §6); (b) build the skip histogram keyed by `detail ?? .fromReason(reason)`; (c) compute strict F1 (hits only) and lenient F1 (partials = 0.5); (d) compute patient correctness. Catastrophic case: `decode` threw -> caller passes a sentinel; Scorer produces an all-zero `CaseScore` with `catastrophic: true`.

**Premortem Fix 2 — display-name linkage:** production sets `label = dto.display ?? dto.loinc ?? "Unknown"` (verified at `LLMResponseContract.swift:116`). When the model emits a display name, the LOINC is NOT in the skip label. So the linkage matches a skip to an expected observation when `skip.label` contains EITHER the expected loinc OR the expected `display`/`name` string. This is a best-effort DIAGNOSTIC linkage only (it splits missed-rejected from missed-absent for the research stage) — it does NOT affect F1, which counts both as recall misses identically. No change to the `Skip` API for v1.

**Interfaces**
- Consumes: `HealthBridgeParsing.ParseResult` (`observations: [Observation]`, `skipped: [Skip]`), `HealthBridgeParsing.Skip` (`reason: Skip.Reason`, `label: String`, `detail: Skip.Detail?`), `ExpectedDoc`, `(name: String, dob: String)?` extracted patient, `Int` distinct count.
- Produces:
  ```swift
  enum Scorer {
      static func skipDetailKey(_ skip: Skip) -> String
      static func score(fixture: String, model: String, sample: Int,
                        result: ParseResult, expected: ExpectedDoc,
                        extractedPatient: (name: String, dob: String)?,
                        distinctPatientCount: Int) -> CaseScore
      static func catastrophic(fixture: String, model: String, sample: Int) -> CaseScore
  }
  ```

**Steps**

- [ ] Write the failing tests (catastrophic + skip-key first, then F1, then display-name missed-rejected linkage, then patient). Write `Tests/BridgeEvalTests/ScorerTests.swift`:
  ```swift
  import XCTest
  import BridgeKit
  import HealthBridgeParsing
  @testable import bridge_eval

  final class ScorerTests: XCTestCase {
      private func date(_ s: String) -> Date { LLMResponseContract.parseDate(s)! }
      private func obs(_ loinc: String, _ value: Double, _ unit: String, _ s: String) -> Observation {
          Observation(id: "id-\(loinc)", code: CodeableRef(system: "http://loinc.org", code: loinc, display: loinc),
                      name: loinc, value: .quantity(value), unit: unit, effectiveDate: date(s),
                      category: .vital, mapping: nil, confidence: 1.0, sourceLocator: nil)
      }
      private func exp(_ loinc: String, _ value: Double, _ unit: String, _ s: String,
                       display: String? = nil) -> ExpectedObservation {
          ExpectedObservation(loinc: loinc, display: display ?? loinc, value: value, valueText: nil, unit: unit,
                              effectiveDate: s, category: "vital")
      }

      func testCatastrophicIsAllZero() {
          let s = Scorer.catastrophic(fixture: "f", model: "m", sample: 2)
          XCTAssertTrue(s.catastrophic)
          XCTAssertEqual(s.strict.f1, 0)
          XCTAssertEqual(s.lenient.f1, 0)
          XCTAssertEqual(s.sample, 2)
      }

      func testSkipDetailKeyPrefersDetail() {
          let withDetail = Skip(reason: .unrepresentableValue, label: "x", detail: .noUsableValue)
          XCTAssertEqual(Scorer.skipDetailKey(withDetail), "noUsableValue")
          let confidence = Skip(reason: .unrepresentableValue, label: "x", detail: .confidenceOutOfRange(got: "1.5"))
          XCTAssertEqual(Scorer.skipDetailKey(confidence), "confidenceOutOfRange(1.5)")
          let noDetail = Skip(reason: .noDate, label: "x", detail: nil)
          XCTAssertEqual(Scorer.skipDetailKey(noDetail), "reason:noDate")
      }

      func testPerfectExtractionScoresF1One() {
          let result = ParseResult(observations: [obs("8867-4", 72, "/min", "2024-01-15")], skipped: [])
          let expected = ExpectedDoc(patients: [], observations: [exp("8867-4", 72, "/min", "2024-01-15")])
          let s = Scorer.score(fixture: "f", model: "m", sample: 0, result: result, expected: expected,
                               extractedPatient: nil, distinctPatientCount: 0)
          XCTAssertEqual(s.strict.f1, 1.0)
          XCTAssertEqual(s.matches.first?.outcome, .hit)
          XCTAssertFalse(s.catastrophic)
      }

      func testSkipHistogramCountsDetails() {
          let skip = Skip(reason: .unrepresentableValue, label: "Glucose", detail: .noUsableValue)
          let result = ParseResult(observations: [], skipped: [skip, skip])
          let expected = ExpectedDoc(patients: [], observations: [])
          let s = Scorer.score(fixture: "f", model: "m", sample: 0, result: result, expected: expected,
                               extractedPatient: nil, distinctPatientCount: 0)
          XCTAssertEqual(s.skipHistogram["noUsableValue"], 2)
      }

      func testMissedAbsentBecomesMissedRejectedViaDisplayName() {
          // PRODUCTION shape: label is the display name only (`dto.display ?? dto.loinc ?? "Unknown"`),
          // so the LOINC is NOT in the label. The linkage must still match on the expected display string.
          let skip = Skip(reason: .unrepresentableValue, label: "Heart rate", detail: .noUsableValue)
          let result = ParseResult(observations: [], skipped: [skip])
          let expected = ExpectedDoc(patients: [], observations: [
              exp("8867-4", 72, "/min", "2024-01-15", display: "Heart rate")])
          let s = Scorer.score(fixture: "f", model: "m", sample: 0, result: result, expected: expected,
                               extractedPatient: nil, distinctPatientCount: 0)
          XCTAssertEqual(s.matches.first?.outcome, .missedRejected)
      }

      func testMissedAbsentBecomesMissedRejectedViaLoincInLabel() {
          // Some reasons append the loinc (e.g. implausible-date labels); the loinc branch still links.
          let skip = Skip(reason: .implausibleDate, label: "8867-4 [dateAfterNow]", detail: .dateAfterNow)
          let result = ParseResult(observations: [], skipped: [skip])
          let expected = ExpectedDoc(patients: [], observations: [
              exp("8867-4", 72, "/min", "2024-01-15", display: "Heart rate")])
          let s = Scorer.score(fixture: "f", model: "m", sample: 0, result: result, expected: expected,
                               extractedPatient: nil, distinctPatientCount: 0)
          XCTAssertEqual(s.matches.first?.outcome, .missedRejected)
      }

      func testLenientF1CreditsPartialAsHalf() {
          // One partial (wrong unit) and one expected = recall_lenient 0.5.
          let result = ParseResult(observations: [obs("718-7", 13, "g/L", "2024-01-15")], skipped: [])
          let expected = ExpectedDoc(patients: [], observations: [
              ExpectedObservation(loinc: "718-7", display: "Hb", value: 13, valueText: nil, unit: "g/dL",
                                  effectiveDate: "2024-01-15", category: "vital")])
          let s = Scorer.score(fixture: "f", model: "m", sample: 0, result: result, expected: expected,
                               extractedPatient: nil, distinctPatientCount: 0)
          XCTAssertEqual(s.strict.f1, 0.0)
          XCTAssertEqual(s.lenient.precision, 0.5)
          XCTAssertEqual(s.lenient.recall, 0.5)
      }

      func testPatientCorrectness() {
          let expected = ExpectedDoc(patients: [ExpectedPatient(name: "Jane Public", dob: "1990-05-01")],
                                     observations: [])
          let s = Scorer.score(fixture: "f", model: "m", sample: 0,
                               result: ParseResult(observations: [], skipped: []), expected: expected,
                               extractedPatient: (name: "Jane Public", dob: "1990-05-01"),
                               distinctPatientCount: 1)
          XCTAssertTrue(s.patient.distinctCountCorrect)
          XCTAssertTrue(s.patient.identityCorrect)
      }
  }
  ```
- [ ] Run it and expect FAILURE: `swift test --filter BridgeEvalTests.ScorerTests`. Expected: unresolved `Scorer` (red).
- [ ] Write the implementation. Write `Sources/bridge-eval/Scorer.swift`:
  ```swift
  import Foundation
  import BridgeKit
  import HealthBridgeParsing

  /// PURE scorer (design §6). Folds Matcher output together with the contract's skip list into a
  /// `CaseScore`: strict F1 (hits only) headline, lenient F1 (partials = ½) secondary, a skip-detail
  /// histogram, and patient-extraction correctness. Platform-free — no PDFKit.
  enum Scorer {
      /// Histogram key: structured `detail` when present, else a `reason:` fallback (design §8).
      static func skipDetailKey(_ skip: Skip) -> String {
          guard let detail = skip.detail else { return "reason:\(skip.reason)" }
          switch detail {
          case .bothValueAndText: return "bothValueAndText"
          case .noUsableValue: return "noUsableValue"
          case .nonFiniteValue: return "nonFiniteValue"
          case .confidenceOutOfRange(let got): return "confidenceOutOfRange(\(got))"
          case .dateMalformed: return "dateMalformed"
          case .dateBeforeDOB: return "dateBeforeDOB"
          case .dateAfterNow: return "dateAfterNow"
          case .missingCode: return "missingCode"
          }
      }

      static func catastrophic(fixture: String, model: String, sample: Int) -> CaseScore {
          let zero = F1(precision: 0, recall: 0, f1: 0)
          return CaseScore(fixture: fixture, model: model, sample: sample, catastrophic: true,
                           strict: zero, lenient: zero, skipHistogram: [:], matches: [],
                           patient: PatientCorrectness(distinctCountCorrect: false, identityCorrect: false))
      }

      static func score(fixture: String, model: String, sample: Int,
                        result: ParseResult, expected: ExpectedDoc,
                        extractedPatient: (name: String, dob: String)?,
                        distinctPatientCount: Int) -> CaseScore {
          var matches = Matcher.match(predicted: result.observations, expected: expected.observations)

          // A skip that references an expected observation reclassifies that miss: absent -> rejected.
          let rejectedLoincs = rejectedLoincSet(result.skipped, expected: expected.observations)
          matches = matches.map { record in
              guard record.outcome == .missedAbsent, rejectedLoincs.contains(record.loinc) else { return record }
              return MatchRecord(loinc: record.loinc, outcome: .missedRejected, fieldErrors: nil)
          }

          var histogram: [String: Int] = [:]
          for skip in result.skipped { histogram[skipDetailKey(skip), default: 0] += 1 }

          let strict = f1(matches: matches, partialWeight: 0.0)
          let lenient = f1(matches: matches, partialWeight: 0.5)

          let patient = patientCorrectness(expected: expected.patients,
                                           extracted: extractedPatient,
                                           distinctCount: distinctPatientCount)

          return CaseScore(fixture: fixture, model: model, sample: sample, catastrophic: false,
                           strict: strict, lenient: lenient, skipHistogram: histogram,
                           matches: matches, patient: patient)
      }

      // MARK: - Helpers

      /// Best-effort DIAGNOSTIC linkage; does not affect F1. Production sets a skip's `label` to
      /// `dto.display ?? dto.loinc ?? "Unknown"` (LLMResponseContract.mapEntry), so when the model emits a
      /// display name the LOINC is NOT in the label. Match an expected observation when the skip label
      /// contains EITHER its loinc OR its display/name string (premortem Fix 2).
      private static func rejectedLoincSet(_ skipped: [Skip], expected: [ExpectedObservation]) -> Set<String> {
          var hit = Set<String>()
          for skip in skipped {
              let label = skip.label
              for e in expected {
                  let display = e.display ?? ""
                  if label.contains(e.loinc) || (!display.isEmpty && label.contains(display)) {
                      hit.insert(e.loinc)
                  }
              }
          }
          return hit
      }

      private static func f1(matches: [MatchRecord], partialWeight: Double) -> F1 {
          let hits = Double(matches.filter { $0.outcome == .hit }.count)
          let partials = Double(matches.filter { $0.outcome == .partial }.count)
          let predictedValid = Double(matches.filter { $0.outcome == .hit || $0.outcome == .partial || $0.outcome == .hallucinated }.count)
          let expectedTotal = Double(matches.filter { $0.outcome == .hit || $0.outcome == .partial || $0.outcome == .missedAbsent || $0.outcome == .missedRejected }.count)
          let credit = hits + partialWeight * partials
          let precision = predictedValid == 0 ? 0 : credit / predictedValid
          let recall = expectedTotal == 0 ? 0 : credit / expectedTotal
          let denom = precision + recall
          let f1 = denom == 0 ? 0 : 2 * precision * recall / denom
          return F1(precision: precision, recall: recall, f1: f1)
      }

      private static func patientCorrectness(expected: [ExpectedPatient],
                                             extracted: (name: String, dob: String)?,
                                             distinctCount: Int) -> PatientCorrectness {
          let expectedCount = Set(expected.map { "\($0.name.lowercased())|\($0.dob.lowercased())" }).count
          let countCorrect = distinctCount == expectedCount
          let identityCorrect: Bool
          if let e = expected.first, let got = extracted {
              identityCorrect = got.name.lowercased() == e.name.lowercased()
                  && got.dob.lowercased() == e.dob.lowercased()
          } else {
              identityCorrect = expected.isEmpty && extracted == nil
          }
          return PatientCorrectness(distinctCountCorrect: countCorrect, identityCorrect: identityCorrect)
      }
  }
  ```
- [ ] Run it and expect PASS: `swift test --filter BridgeEvalTests.ScorerTests`. Expected: 8 tests pass.
- [ ] Commit:
  ```bash
  git add Sources/bridge-eval/Scorer.swift Tests/BridgeEvalTests/ScorerTests.swift
  git commit -m "feat(eval): add pure scorer with display-name missed-rejected linkage and F1"
  ```

---

### Task 6: Aggregator — [CaseScore] -> RunResults (pure, design §7)

**Files**
- create `Sources/bridge-eval/Aggregator.swift`
- create `Tests/BridgeEvalTests/AggregatorTests.swift`

Groups `[CaseScore]` by `(fixture, model)` and computes mean ± stdev of strict and lenient F1 across the N samples, the catastrophic rate, and an output-consistency score (mean pairwise agreement of the per-sample hit loinc-sets, design §7). Population stdev. Stable ordering by `(fixture, model)`. Takes `promptHashes: [String]` (distinct, per-run — premortem Fix 5) and threads them onto `RunResults`.

**Premortem Fix 3 — N=1 stdev:** with population stdev, a single sample yields `stdev = 0.0, n = 1`. The added test documents this is intentional (not a divide-by-zero bug) and guards against a future divide-by-`(n-1)` regression. The `n` field carries the sample count so a consumer (Report) can distinguish "no variance" from "single sample".

**Interfaces**
- Consumes: `[CaseScore]`, `promptHashes: [String]`
- Produces:
  ```swift
  enum Aggregator {
      static func aggregate(_ scores: [CaseScore], promptHashes: [String]) -> RunResults
  }
  ```

**Steps**

- [ ] Write the failing tests (empty/single first, then mean+stdev, then N=1, then consistency). Write `Tests/BridgeEvalTests/AggregatorTests.swift`:
  ```swift
  import XCTest
  @testable import bridge_eval

  final class AggregatorTests: XCTestCase {
      private func score(fixture: String, model: String, sample: Int, f1: Double,
                         catastrophic: Bool = false, hitLoincs: [String] = []) -> CaseScore {
          CaseScore(fixture: fixture, model: model, sample: sample, catastrophic: catastrophic,
                    strict: F1(precision: f1, recall: f1, f1: f1),
                    lenient: F1(precision: f1, recall: f1, f1: f1),
                    skipHistogram: [:],
                    matches: hitLoincs.map { MatchRecord(loinc: $0, outcome: .hit, fieldErrors: nil) },
                    patient: PatientCorrectness(distinctCountCorrect: true, identityCorrect: true))
      }

      func testEmptyProducesNoStats() {
          let r = Aggregator.aggregate([], promptHashes: ["abc"])
          XCTAssertEqual(r.promptHashes, ["abc"])
          XCTAssertTrue(r.stats.isEmpty)
      }

      func testMeanAndStdevAcrossSamples() {
          let scores = [
              score(fixture: "f", model: "m", sample: 0, f1: 0.6),
              score(fixture: "f", model: "m", sample: 1, f1: 0.8),
              score(fixture: "f", model: "m", sample: 2, f1: 1.0),
          ]
          let r = Aggregator.aggregate(scores, promptHashes: ["abc"])
          XCTAssertEqual(r.stats.count, 1)
          let s = r.stats[0]
          XCTAssertEqual(s.strictF1.n, 3)
          XCTAssertEqual(s.strictF1.mean, 0.8, accuracy: 1e-9)
          // population stdev of [0.6,0.8,1.0] = sqrt((0.04+0+0.04)/3) ≈ 0.163299
          XCTAssertEqual(s.strictF1.stdev, 0.16329931618, accuracy: 1e-6)
      }

      func testSingleSampleStdevIsZeroWithNOne() {
          // Default --samples 1: population stdev is 0.0 with n=1 (intentional; not a divide bug). Report
          // surfaces n=1 as "single sample" rather than "no variance" (Fix 3).
          let r = Aggregator.aggregate([score(fixture: "f", model: "m", sample: 0, f1: 0.7)],
                                       promptHashes: ["abc"])
          XCTAssertEqual(r.stats[0].strictF1.n, 1)
          XCTAssertEqual(r.stats[0].strictF1.stdev, 0.0)
          XCTAssertEqual(r.stats[0].strictF1.mean, 0.7, accuracy: 1e-9)
      }

      func testCatastrophicRate() {
          let scores = [
              score(fixture: "f", model: "m", sample: 0, f1: 0, catastrophic: true),
              score(fixture: "f", model: "m", sample: 1, f1: 1.0),
          ]
          let r = Aggregator.aggregate(scores, promptHashes: ["abc"])
          XCTAssertEqual(r.stats[0].catastrophicRate, 0.5, accuracy: 1e-9)
      }

      func testOutputConsistencyIdenticalSamplesIsOne() {
          let scores = [
              score(fixture: "f", model: "m", sample: 0, f1: 1, hitLoincs: ["8867-4", "718-7"]),
              score(fixture: "f", model: "m", sample: 1, f1: 1, hitLoincs: ["718-7", "8867-4"]),
          ]
          let r = Aggregator.aggregate(scores, promptHashes: ["abc"])
          XCTAssertEqual(r.stats[0].outputConsistency, 1.0, accuracy: 1e-9)
      }

      func testGroupsByFixtureAndModel() {
          let scores = [
              score(fixture: "f1", model: "m1", sample: 0, f1: 1),
              score(fixture: "f1", model: "m2", sample: 0, f1: 0.5),
          ]
          let r = Aggregator.aggregate(scores, promptHashes: ["abc"])
          XCTAssertEqual(r.stats.count, 2)
          XCTAssertEqual(r.stats.map { $0.model }, ["m1", "m2"])
      }
  }
  ```
- [ ] Run it and expect FAILURE: `swift test --filter BridgeEvalTests.AggregatorTests`. Expected: unresolved `Aggregator` (red).
- [ ] Write the implementation. Write `Sources/bridge-eval/Aggregator.swift`:
  ```swift
  import Foundation

  /// PURE aggregator (design §7). Groups per-case scores by (fixture, model) and computes mean ± stdev
  /// F1 across the N samples, catastrophic rate, and output-consistency (mean pairwise Jaccard agreement
  /// of per-sample hit loinc-sets). Population stdev (so n=1 -> stdev 0.0, n carried for the Report's
  /// "single sample" note — Fix 3). Platform-free.
  enum Aggregator {
      static func aggregate(_ scores: [CaseScore], promptHashes: [String]) -> RunResults {
          let groups = Dictionary(grouping: scores, by: { Pair(fixture: $0.fixture, model: $0.model) })
          let stats = groups.keys.sorted().map { key -> FixtureModelStats in
              let group = groups[key]!.sorted { $0.sample < $1.sample }
              let strict = aggregateF1(group.map { $0.strict.f1 })
              let lenient = aggregateF1(group.map { $0.lenient.f1 })
              let catRate = Double(group.filter { $0.catastrophic }.count) / Double(group.count)
              let consistency = outputConsistency(group)
              return FixtureModelStats(fixture: key.fixture, model: key.model,
                                       strictF1: strict, lenientF1: lenient,
                                       outputConsistency: consistency, catastrophicRate: catRate)
          }
          return RunResults(promptHashes: promptHashes, stats: stats)
      }

      private struct Pair: Hashable, Comparable {
          let fixture: String
          let model: String
          static func < (lhs: Pair, rhs: Pair) -> Bool {
              lhs.fixture == rhs.fixture ? lhs.model < rhs.model : lhs.fixture < rhs.fixture
          }
      }

      private static func aggregateF1(_ values: [Double]) -> AggregateF1 {
          guard !values.isEmpty else { return AggregateF1(mean: 0, stdev: 0, n: 0) }
          let mean = values.reduce(0, +) / Double(values.count)
          let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
          return AggregateF1(mean: mean, stdev: variance.squareRoot(), n: values.count)
      }

      private static func hitSet(_ score: CaseScore) -> Set<String> {
          Set(score.matches.filter { $0.outcome == .hit }.map { $0.loinc })
      }

      private static func outputConsistency(_ group: [CaseScore]) -> Double {
          guard group.count > 1 else { return 1.0 }
          let sets = group.map(hitSet)
          var total = 0.0
          var pairs = 0
          for i in 0..<sets.count {
              for j in (i + 1)..<sets.count {
                  let union = sets[i].union(sets[j])
                  let agreement = union.isEmpty ? 1.0 : Double(sets[i].intersection(sets[j]).count) / Double(union.count)
                  total += agreement
                  pairs += 1
              }
          }
          return pairs == 0 ? 1.0 : total / Double(pairs)
      }
  }
  ```
- [ ] Run it and expect PASS: `swift test --filter BridgeEvalTests.AggregatorTests`. Expected: 6 tests pass.
- [ ] Commit:
  ```bash
  git add Sources/bridge-eval/Aggregator.swift Tests/BridgeEvalTests/AggregatorTests.swift
  git commit -m "feat(eval): add pure aggregator for mean/stdev F1 and output consistency"
  ```

---

### Task 7: Preflight guard — refuse git-tracked fixture/artifact paths (design §9)

**Files**
- create `Sources/bridge-eval/Preflight.swift`
- create `Tests/BridgeEvalTests/PreflightTests.swift`

The guard refuses to read fixtures from, or write artifacts into, a git-TRACKED path — fail loud (design §9, §13.3). It shells out to `git ls-files --error-unmatch <path>` from the path's repo root: exit 0 means tracked (REFUSE), non-zero means untracked (allow). A path outside any git repo is allowed. Pure decision split from the I/O probe so the decision is unit-testable without git.

**Interfaces**
- Produces:
  ```swift
  enum Preflight {
      struct GuardError: Error, CustomStringConvertible { let message: String; var description: String { message } }
      // Pure decision: given "is this path tracked by git?", decide.
      static func decide(path: String, isTracked: Bool) -> Result<Void, GuardError>
      // I/O probe + decision, used by RunCommand.
      static func assertUntracked(_ path: String, role: String) throws
      static func isGitTracked(_ path: String) -> Bool
  }
  ```

**Steps**

- [ ] Write the failing tests for the PURE decision (no git needed). Write `Tests/BridgeEvalTests/PreflightTests.swift`:
  ```swift
  import XCTest
  @testable import bridge_eval

  final class PreflightTests: XCTestCase {
      func testTrackedPathIsRefused() {
          let result = Preflight.decide(path: "Tests/Fixtures/real.pdf", isTracked: true)
          guard case .failure(let err) = result else { return XCTFail("expected refusal") }
          XCTAssertTrue(err.message.lowercased().contains("tracked"))
      }

      func testUntrackedPathIsAllowed() {
          let result = Preflight.decide(path: "eval/fixtures/case/input.pdf", isTracked: false)
          guard case .success = result else { return XCTFail("expected allow") }
      }

      func testAssertUntrackedThrowsOnTracked() throws {
          // .gitignore is committed -> tracked -> must throw.
          XCTAssertThrowsError(try Preflight.assertUntracked(".gitignore", role: "fixtures")) { error in
              let g = error as? Preflight.GuardError
              XCTAssertNotNil(g)
              XCTAssertTrue((g?.message ?? "").contains("fixtures"))
          }
      }

      func testAssertUntrackedAllowsNonexistentLocalPath() throws {
          // A path not tracked by git (here: a scratch path) must NOT throw.
          let scratch = NSTemporaryDirectory() + "bridge-eval-untracked-\(UUID().uuidString)/input.pdf"
          XCTAssertNoThrow(try Preflight.assertUntracked(scratch, role: "fixtures"))
      }
  }
  ```
- [ ] Run it and expect FAILURE: `swift test --filter BridgeEvalTests.PreflightTests`. Expected: unresolved `Preflight` (red).
- [ ] Write the implementation. Write `Sources/bridge-eval/Preflight.swift`:
  ```swift
  import Foundation

  /// PHI git-safety guard (design §9). `run` must NEVER read fixtures from, or write artifacts into, a
  /// git-TRACKED path — real PDFs and raw/scored artifacts contain PHI and this repo is public. Fail loud.
  /// The pure `decide` is unit-tested without git; `assertUntracked` adds the `git ls-files` probe.
  enum Preflight {
      struct GuardError: Error, CustomStringConvertible {
          let message: String
          var description: String { message }
      }

      static func decide(path: String, isTracked: Bool) -> Result<Void, GuardError> {
          if isTracked {
              return .failure(GuardError(message: "Refusing: '\(path)' is git-tracked. Fixtures and run "
                  + "artifacts may contain PHI and must never live on a tracked path. Move it under a "
                  + "gitignored dir (eval/fixtures, eval/runs) or pass an off-repo --fixtures path."))
          }
          return .success(())
      }

      static func assertUntracked(_ path: String, role: String) throws {
          let tracked = isGitTracked(path)
          if case .failure(let err) = decide(path: path, isTracked: tracked) {
              throw GuardError(message: "[\(role)] " + err.message)
          }
      }

      /// `git ls-files --error-unmatch` exits 0 iff the path is tracked. Run from the path's directory so
      /// the correct repo root is used. Any failure to even run git (no repo) means "not tracked" -> allow.
      static func isGitTracked(_ path: String) -> Bool {
          let url = URL(fileURLWithPath: path)
          let dir = url.deletingLastPathComponent().path
          let process = Process()
          process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
          process.arguments = ["git", "-C", dir.isEmpty ? "." : dir,
                               "ls-files", "--error-unmatch", url.lastPathComponent]
          process.standardOutput = FileHandle.nullDevice
          process.standardError = FileHandle.nullDevice
          do {
              try process.run()
              process.waitUntilExit()
              return process.terminationStatus == 0
          } catch {
              return false
          }
      }
  }
  ```
- [ ] Run it and expect PASS: `swift test --filter BridgeEvalTests.PreflightTests`. Expected: 4 tests pass. Note: `testAssertUntrackedThrowsOnTracked` depends on `.gitignore` being committed at the repo root; this is true after Task 1.
- [ ] Commit:
  ```bash
  git add Sources/bridge-eval/Preflight.swift Tests/BridgeEvalTests/PreflightTests.swift
  git commit -m "feat(eval): add preflight guard refusing git-tracked fixture and artifact paths"
  ```

---

### Task 8: Fixtures loader — load expected.json + input.pdf from a case dir (design §5)

**Files**
- create `Sources/bridge-eval/Fixtures.swift`
- create `Tests/BridgeEvalTests/FixturesTests.swift`
- create `Tests/BridgeEvalTests/Fixtures/vitals-basic/expected.json` (Tier A synthetic)

A case dir is `<root>/<case-name>/` containing `expected.json` (always) and `input.pdf` (for `run`). The loader parses `expected.json` into `ExpectedDoc` and, for `run`, returns the raw PDF `Data` + `inputHash` (it does NOT parse PDFs — that is the macOS-guarded `run` leg). `loadExpected` is platform-free and tested with the committed synthetic fixture. `discoverCases` lists case-name subdirectories containing `expected.json`.

**Interfaces**
- Produces:
  ```swift
  enum Fixtures {
      struct LoadError: Error, CustomStringConvertible { let message: String; var description: String { message } }
      static func discoverCases(root: String) throws -> [String]              // sorted case names
      static func loadExpected(root: String, caseName: String) throws -> ExpectedDoc
      static func inputPDFURL(root: String, caseName: String) -> URL
  }
  ```

**Steps**

- [ ] Create the committed synthetic Tier A fixture. Write `Tests/BridgeEvalTests/Fixtures/vitals-basic/expected.json`:
  ```json
  {
    "patients": [
      { "name": "Jane Public", "dob": "1990-05-01" }
    ],
    "observations": [
      { "loinc": "8867-4", "display": "Heart rate", "value": 72.5, "valueText": null,
        "unit": "/min", "effectiveDate": "2024-01-15", "category": "vital" },
      { "loinc": "8480-6", "display": "Systolic blood pressure", "value": 118, "valueText": null,
        "unit": "mm[Hg]", "effectiveDate": "2024-01-15", "category": "vital" }
    ]
  }
  ```
- [ ] Write the failing tests (missing-dir error first, then happy path). Write `Tests/BridgeEvalTests/FixturesTests.swift`:
  ```swift
  import XCTest
  @testable import bridge_eval

  final class FixturesTests: XCTestCase {
      private func fixturesRoot() throws -> String {
          // Bundle.module .copy("Fixtures") -> resources root; the case dirs live directly under it.
          let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/vitals-basic/expected", withExtension: "json"))
          return url.deletingLastPathComponent().deletingLastPathComponent().path
      }

      func testMissingExpectedThrows() throws {
          let root = try fixturesRoot()
          XCTAssertThrowsError(try Fixtures.loadExpected(root: root, caseName: "does-not-exist")) { error in
              XCTAssertTrue(error is Fixtures.LoadError)
          }
      }

      func testLoadExpectedParsesSyntheticGold() throws {
          let root = try fixturesRoot()
          let doc = try Fixtures.loadExpected(root: root, caseName: "vitals-basic")
          XCTAssertEqual(doc.patients.first?.name, "Jane Public")
          XCTAssertEqual(doc.observations.count, 2)
          XCTAssertEqual(doc.observations.first?.loinc, "8867-4")
      }

      func testDiscoverCasesFindsCaseDir() throws {
          let root = try fixturesRoot()
          let cases = try Fixtures.discoverCases(root: root)
          XCTAssertTrue(cases.contains("vitals-basic"))
      }

      func testInputPDFURLComposesPath() {
          let url = Fixtures.inputPDFURL(root: "/x", caseName: "c")
          XCTAssertEqual(url.path, "/x/c/input.pdf")
      }
  }
  ```
- [ ] Run it and expect FAILURE: `swift test --filter BridgeEvalTests.FixturesTests`. Expected: unresolved `Fixtures` (red).
- [ ] Write the implementation. Write `Sources/bridge-eval/Fixtures.swift`:
  ```swift
  import Foundation

  /// Loads a fixture case (design §5): `<root>/<case>/expected.json` (always) + `input.pdf` (for `run`).
  /// `loadExpected`/`discoverCases` are platform-free and exercised with the committed Tier A synthetic
  /// gold. PDF bytes are read by the macOS-guarded `run` leg, not here.
  enum Fixtures {
      struct LoadError: Error, CustomStringConvertible {
          let message: String
          var description: String { message }
      }

      static func discoverCases(root: String) throws -> [String] {
          let fm = FileManager.default
          guard let entries = try? fm.contentsOfDirectory(atPath: root) else {
              throw LoadError(message: "fixtures root not readable: \(root)")
          }
          return entries.filter { name in
              var isDir: ObjCBool = false
              let casePath = (root as NSString).appendingPathComponent(name)
              guard fm.fileExists(atPath: casePath, isDirectory: &isDir), isDir.boolValue else { return false }
              let expected = (casePath as NSString).appendingPathComponent("expected.json")
              return fm.fileExists(atPath: expected)
          }.sorted()
      }

      static func loadExpected(root: String, caseName: String) throws -> ExpectedDoc {
          let path = (root as NSString)
              .appendingPathComponent(caseName)
              .appending("/expected.json")
          guard let data = FileManager.default.contents(atPath: path) else {
              throw LoadError(message: "missing expected.json for case '\(caseName)' at \(path)")
          }
          do {
              return try JSONDecoder().decode(ExpectedDoc.self, from: data)
          } catch {
              throw LoadError(message: "expected.json for '\(caseName)' is not valid: \(error)")
          }
      }

      static func inputPDFURL(root: String, caseName: String) -> URL {
          URL(fileURLWithPath: root)
              .appendingPathComponent(caseName)
              .appendingPathComponent("input.pdf")
      }
  }
  ```
- [ ] Run it and expect PASS: `swift test --filter BridgeEvalTests.FixturesTests`. Expected: 4 tests pass.
- [ ] Commit:
  ```bash
  git add Sources/bridge-eval/Fixtures.swift Tests/BridgeEvalTests/FixturesTests.swift Tests/BridgeEvalTests/Fixtures/vitals-basic/expected.json
  git commit -m "feat(eval): add fixtures loader with committed synthetic Tier A gold"
  ```

---

### Task 9: Artifact writer — manifest/raw/scored/results JSON (design §7, re-impl per scout §7)

**Files**
- create `Sources/bridge-eval/ArtifactWriter.swift`
- create `Tests/BridgeEvalTests/ArtifactWriterTests.swift`

`RawResponseLog` lives in the un-importable `healthbridge` executable target (scout §7), so the harness writes its OWN richer per-case JSON artifacts into the run-dir layout (design §7). Pure path/key composition split from the disk I/O so most of it unit-tests without touching the filesystem; the actual writes go to a temp dir in tests (NOT a tracked path — the preflight guard from Task 7 enforces this at `run` time).

**Interfaces**
- Produces:
  ```swift
  enum ArtifactWriter {
      static func key(promptHash: String, model: String, fixture: String, sample: Int) -> String
      static func runDir(runsRoot: String, timestamp: String) -> URL
      static func writeManifest(_ manifest: Manifest, runDir: URL) throws
      static func writeRaw(_ raw: RawArtifact, runDir: URL) throws
      static func writeScored(_ score: CaseScore, key: String, runDir: URL) throws
      static func writeResults(_ results: RunResults, runDir: URL) throws
  }
  ```

**Steps**

- [ ] Write the failing tests (key composition first, then write+readback). Write `Tests/BridgeEvalTests/ArtifactWriterTests.swift`:
  ```swift
  import XCTest
  @testable import bridge_eval

  final class ArtifactWriterTests: XCTestCase {
      private func tempRunDir() -> URL {
          let dir = URL(fileURLWithPath: NSTemporaryDirectory())
              .appendingPathComponent("bridge-eval-\(UUID().uuidString)")
          return dir
      }

      func testKeyComposition() {
          XCTAssertEqual(ArtifactWriter.key(promptHash: "abc", model: "claude-opus-4-8",
                                            fixture: "vitals-basic", sample: 2),
                         "abc__claude-opus-4-8__vitals-basic__2")
      }

      func testRunDirComposesUnderRoot() {
          let url = ArtifactWriter.runDir(runsRoot: "/runs", timestamp: "2026-06-25T00-00-00Z")
          XCTAssertEqual(url.path, "/runs/2026-06-25T00-00-00Z")
      }

      func testWriteAndReadbackManifest() throws {
          let runDir = tempRunDir()
          let manifest = Manifest(timestamp: "2026-06-25T00:00:00Z", promptHashes: ["abc"],
                                  models: ["m"], sampleCount: 1, fixtureNames: ["vitals-basic"])
          try ArtifactWriter.writeManifest(manifest, runDir: runDir)
          let data = try Data(contentsOf: runDir.appendingPathComponent("manifest.json"))
          XCTAssertEqual(try JSONDecoder().decode(Manifest.self, from: data), manifest)
      }

      func testWriteRawAndScoredIntoSubdirs() throws {
          let runDir = tempRunDir()
          let raw = RawArtifact(key: "k", promptHash: "abc", inputHash: "def", model: "m",
                                fixture: "f", sample: 0, jsonText: "{}", inputTokens: nil,
                                outputTokens: nil, stopReason: nil, latencyMillis: nil)
          try ArtifactWriter.writeRaw(raw, runDir: runDir)
          let score = Scorer.catastrophic(fixture: "f", model: "m", sample: 0)
          try ArtifactWriter.writeScored(score, key: "k", runDir: runDir)
          XCTAssertTrue(FileManager.default.fileExists(atPath: runDir.appendingPathComponent("raw/k.json").path))
          XCTAssertTrue(FileManager.default.fileExists(atPath: runDir.appendingPathComponent("scored/k.json").path))
      }

      func testWriteResults() throws {
          let runDir = tempRunDir()
          let results = RunResults(promptHashes: ["abc"], stats: [])
          try ArtifactWriter.writeResults(results, runDir: runDir)
          let data = try Data(contentsOf: runDir.appendingPathComponent("results.json"))
          XCTAssertEqual(try JSONDecoder().decode(RunResults.self, from: data), results)
      }
  }
  ```
- [ ] Run it and expect FAILURE: `swift test --filter BridgeEvalTests.ArtifactWriterTests`. Expected: unresolved `ArtifactWriter` (red).
- [ ] Write the implementation. Write `Sources/bridge-eval/ArtifactWriter.swift`:
  ```swift
  import Foundation

  /// Writes the run-dir artifacts (design §7). Re-implements minimal JSON writing because `RawResponseLog`
  /// lives in the un-importable `healthbridge` executable target (scout §7) — the shipping CLI stays
  /// untouched. Key/path composition is pure; writes create dirs lazily and pretty-print with sorted keys
  /// for diff-friendliness.
  enum ArtifactWriter {
      private static func encoder() -> JSONEncoder {
          let e = JSONEncoder()
          e.outputFormatting = [.prettyPrinted, .sortedKeys]
          return e
      }

      static func key(promptHash: String, model: String, fixture: String, sample: Int) -> String {
          "\(promptHash)__\(model)__\(fixture)__\(sample)"
      }

      static func runDir(runsRoot: String, timestamp: String) -> URL {
          URL(fileURLWithPath: runsRoot).appendingPathComponent(timestamp)
      }

      private static func write<T: Encodable>(_ value: T, to url: URL) throws {
          try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
          try encoder().encode(value).write(to: url, options: .atomic)
      }

      static func writeManifest(_ manifest: Manifest, runDir: URL) throws {
          try write(manifest, to: runDir.appendingPathComponent("manifest.json"))
      }

      static func writeRaw(_ raw: RawArtifact, runDir: URL) throws {
          try write(raw, to: runDir.appendingPathComponent("raw").appendingPathComponent("\(raw.key).json"))
      }

      static func writeScored(_ score: CaseScore, key: String, runDir: URL) throws {
          try write(score, to: runDir.appendingPathComponent("scored").appendingPathComponent("\(key).json"))
      }

      static func writeResults(_ results: RunResults, runDir: URL) throws {
          try write(results, to: runDir.appendingPathComponent("results.json"))
      }
  }
  ```
- [ ] Run it and expect PASS: `swift test --filter BridgeEvalTests.ArtifactWriterTests`. Expected: 5 tests pass.
- [ ] Commit:
  ```bash
  git add Sources/bridge-eval/ArtifactWriter.swift Tests/BridgeEvalTests/ArtifactWriterTests.swift
  git commit -m "feat(eval): add run-dir artifact writer for manifest/raw/scored/results JSON"
  ```

---

### Task 10: Artifact reader + ScoreCommand (pure subcommand, design §3 `score`)

**Files**
- create `Sources/bridge-eval/ArtifactReader.swift`
- create `Sources/bridge-eval/ScoreCommand.swift`
- create `Tests/BridgeEvalTests/ScoreCommandTests.swift`

`score` re-scores already-saved raw responses OFFLINE (design §3) — pure, zero network, replayable. It reads `raw/*.json` from a run dir, re-runs the contract decode on each `jsonText`, rescores against the matching fixture's `expected.json`, and rewrites `scored/*.json` + `results.json`. The decode-rescore core is extracted as a pure function `rescore` so it unit-tests with a synthetic `RawArtifact` + `ExpectedDoc`, no disk. The run-level `promptHashes` for `results.json` are the DISTINCT per-case `RawArtifact.promptHash` values, sorted (premortem Fix 5).

**Interfaces**
- Consumes: `LLMResponseContract.decode/.distinctPatientCount/.extractedPatient`, `ArtifactReader`, `Scorer`, `Aggregator`.
- Produces:
  ```swift
  enum ArtifactReader {
      static func readRaws(runDir: URL) throws -> [RawArtifact]
      static func readManifest(runDir: URL) throws -> Manifest
  }
  enum ScoreCore {
      static func rescore(raw: RawArtifact, expected: ExpectedDoc, subjectId: String, now: Date) -> CaseScore
  }
  struct ScoreCommand: AsyncParsableCommand { ... }   // wired here, exercised via ScoreCore + ArtifactReader
  ```

**Steps**

- [ ] Write the failing tests for the PURE rescore core + reader. Write `Tests/BridgeEvalTests/ScoreCommandTests.swift`:
  ```swift
  import XCTest
  import HealthBridgeParsing
  @testable import bridge_eval

  final class ScoreCommandTests: XCTestCase {
      private let goodJSON = """
      {"patients":[{"name":"Jane Public","dob":"1990-05-01"}],
       "observations":[{"loinc":"8867-4","display":"Heart rate","value":72.5,"unit":"/min",
                        "effectiveDate":"2024-01-15","category":"vital","confidence":0.9}]}
      """
      private func expectedDoc() -> ExpectedDoc {
          ExpectedDoc(patients: [ExpectedPatient(name: "Jane Public", dob: "1990-05-01")],
                      observations: [ExpectedObservation(loinc: "8867-4", display: "Heart rate", value: 72.5,
                                     valueText: nil, unit: "/min", effectiveDate: "2024-01-15", category: "vital")])
      }
      private func raw(_ jsonText: String) -> RawArtifact {
          RawArtifact(key: "abc__m__vitals-basic__0", promptHash: "abc", inputHash: "def", model: "m",
                      fixture: "vitals-basic", sample: 0, jsonText: jsonText, inputTokens: nil,
                      outputTokens: nil, stopReason: nil, latencyMillis: nil)
      }

      func testRescoreMalformedIsCatastrophic() {
          let score = ScoreCore.rescore(raw: raw("not json"), expected: expectedDoc(),
                                        subjectId: "subj", now: Date())
          XCTAssertTrue(score.catastrophic)
      }

      func testRescoreGoodResponseHits() {
          let score = ScoreCore.rescore(raw: raw(goodJSON), expected: expectedDoc(),
                                        subjectId: "subj", now: Date())
          XCTAssertFalse(score.catastrophic)
          XCTAssertEqual(score.strict.f1, 1.0, accuracy: 1e-9)
          XCTAssertEqual(score.matches.first?.outcome, .hit)
      }

      func testReadRawsRoundTrip() throws {
          let runDir = URL(fileURLWithPath: NSTemporaryDirectory())
              .appendingPathComponent("bridge-eval-read-\(UUID().uuidString)")
          try ArtifactWriter.writeRaw(raw(goodJSON), runDir: runDir)
          let raws = try ArtifactReader.readRaws(runDir: runDir)
          XCTAssertEqual(raws.count, 1)
          XCTAssertEqual(raws.first?.fixture, "vitals-basic")
          XCTAssertEqual(raws.first?.promptHash, "abc")
      }
  }
  ```
- [ ] Run it and expect FAILURE: `swift test --filter BridgeEvalTests.ScoreCommandTests`. Expected: unresolved `ScoreCore`/`ArtifactReader` (red).
- [ ] Write the reader. Write `Sources/bridge-eval/ArtifactReader.swift`:
  ```swift
  import Foundation

  /// Reads run-dir artifacts back for the pure `score`/`report` subcommands (design §3). Platform-free.
  enum ArtifactReader {
      struct ReadError: Error, CustomStringConvertible {
          let message: String
          var description: String { message }
      }

      static func readRaws(runDir: URL) throws -> [RawArtifact] {
          let rawDir = runDir.appendingPathComponent("raw")
          let fm = FileManager.default
          guard let names = try? fm.contentsOfDirectory(atPath: rawDir.path) else {
              throw ReadError(message: "no raw/ dir at \(rawDir.path)")
          }
          return try names.filter { $0.hasSuffix(".json") }.sorted().map { name in
              let data = try Data(contentsOf: rawDir.appendingPathComponent(name))
              return try JSONDecoder().decode(RawArtifact.self, from: data)
          }
      }

      static func readManifest(runDir: URL) throws -> Manifest {
          let data = try Data(contentsOf: runDir.appendingPathComponent("manifest.json"))
          return try JSONDecoder().decode(Manifest.self, from: data)
      }
  }
  ```
- [ ] Write the pure rescore core + the subcommand. Write `Sources/bridge-eval/ScoreCommand.swift`:
  ```swift
  import Foundation
  import ArgumentParser
  import HealthBridgeParsing

  /// Pure decode+score of a saved raw response against gold (design §3 `score`). Decoupled from disk so
  /// it unit-tests with a synthetic RawArtifact + ExpectedDoc, zero network. A malformed reply (decode
  /// throws ParseError.malformed) becomes a catastrophic CaseScore.
  enum ScoreCore {
      static func rescore(raw: RawArtifact, expected: ExpectedDoc, subjectId: String, now: Date) -> CaseScore {
          do {
              let result = try LLMResponseContract.decode(raw.jsonText, subjectId: subjectId, now: now)
              let distinct = (try? LLMResponseContract.distinctPatientCount(raw.jsonText)) ?? 0
              let patient = (try? LLMResponseContract.extractedPatient(raw.jsonText)) ?? nil
              return Scorer.score(fixture: raw.fixture, model: raw.model, sample: raw.sample,
                                  result: result, expected: expected,
                                  extractedPatient: patient, distinctPatientCount: distinct)
          } catch {
              return Scorer.catastrophic(fixture: raw.fixture, model: raw.model, sample: raw.sample)
          }
      }
  }

  /// `score` subcommand: re-score saved raw responses offline (pure). Reads raw/*.json from a run dir,
  /// rescores each against the matching fixture's expected.json, rewrites scored/*.json + results.json.
  /// The run-level promptHashes are the DISTINCT per-case RawArtifact.promptHash values (Fix 5).
  struct ScoreCommand: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
          commandName: "score",
          abstract: "Re-score saved raw responses offline against gold fixtures (no network).")

      @Option(name: .long, help: "Run directory containing raw/*.json and manifest.json.") var runDir: String
      @Option(name: .long, help: "Fixtures root (default: eval/fixtures).") var fixtures: String = "eval/fixtures"
      @Option(name: .long, help: "Subject id used for the contract's single-subject decode.") var subjectId: String = "eval-subject"

      func run() async throws {
          let dir = URL(fileURLWithPath: runDir)
          let raws = try ArtifactReader.readRaws(runDir: dir)
          var expectedCache: [String: ExpectedDoc] = [:]
          var scores: [CaseScore] = []
          for raw in raws {
              let expected: ExpectedDoc
              if let cached = expectedCache[raw.fixture] {
                  expected = cached
              } else {
                  expected = try Fixtures.loadExpected(root: fixtures, caseName: raw.fixture)
                  expectedCache[raw.fixture] = expected
              }
              let score = ScoreCore.rescore(raw: raw, expected: expected, subjectId: subjectId, now: Date())
              try ArtifactWriter.writeScored(score, key: raw.key, runDir: dir)
              scores.append(score)
          }
          let promptHashes = Set(raws.map { $0.promptHash }).sorted()
          let results = Aggregator.aggregate(scores, promptHashes: promptHashes)
          try ArtifactWriter.writeResults(results, runDir: dir)
          FileHandle.standardError.write(Data("scored \(scores.count) case(s) -> \(dir.path)/results.json\n".utf8))
      }
  }
  ```
- [ ] Run it and expect PASS: `swift test --filter BridgeEvalTests.ScoreCommandTests`. Expected: 3 tests pass.
- [ ] Commit:
  ```bash
  git add Sources/bridge-eval/ArtifactReader.swift Sources/bridge-eval/ScoreCommand.swift Tests/BridgeEvalTests/ScoreCommandTests.swift
  git commit -m "feat(eval): add offline score subcommand with pure decode-rescore core"
  ```

---

### Task 11: ReportCommand — aggregate a run dir to table + results.json (pure, design §3 `report`)

**Files**
- create `Sources/bridge-eval/ReportCommand.swift`
- create `Tests/BridgeEvalTests/ReportCommandTests.swift`

`report` aggregates a run dir into a human table + machine `results.json` (design §3). The pure piece is table rendering from `RunResults`; the command re-reads `scored/*.json` (already-computed `CaseScore`s) and re-aggregates, so `report` works even on a run dir produced by an older scorer. It threads the manifest's `promptHashes` onto the results.

**Premortem Fix 3 — N=1 rendering:** when a stat's sample count is 1, the table renders the stdev cell as `n=1 (single sample)` rather than a bare `±0.00`, so a reader does not mistake "single sample" for "zero variance".

**Interfaces**
- Produces:
  ```swift
  enum Report {
      static func renderTable(_ results: RunResults) -> String
  }
  enum ArtifactReader { static func readScores(runDir: URL) throws -> [CaseScore] }   // extend Task 10's enum
  struct ReportCommand: AsyncParsableCommand { ... }
  ```

**Steps**

- [ ] Write the failing tests for the PURE table renderer + readScores. Write `Tests/BridgeEvalTests/ReportCommandTests.swift`:
  ```swift
  import XCTest
  @testable import bridge_eval

  final class ReportCommandTests: XCTestCase {
      func testRenderTableHasHeaderAndRow() {
          let results = RunResults(promptHashes: ["abc123"], stats: [
              FixtureModelStats(fixture: "vitals-basic", model: "claude-opus-4-8",
                                strictF1: AggregateF1(mean: 0.8, stdev: 0.1, n: 3),
                                lenientF1: AggregateF1(mean: 0.9, stdev: 0.05, n: 3),
                                outputConsistency: 0.66, catastrophicRate: 0.0)])
          let table = Report.renderTable(results)
          XCTAssertTrue(table.contains("fixture"))
          XCTAssertTrue(table.contains("vitals-basic"))
          XCTAssertTrue(table.contains("claude-opus-4-8"))
          XCTAssertTrue(table.contains("0.80"))   // strict mean, 2dp
      }

      func testRenderTableSingleSampleAnnotatesN1() {
          let results = RunResults(promptHashes: ["abc"], stats: [
              FixtureModelStats(fixture: "f", model: "m",
                                strictF1: AggregateF1(mean: 0.7, stdev: 0.0, n: 1),
                                lenientF1: AggregateF1(mean: 0.7, stdev: 0.0, n: 1),
                                outputConsistency: 1.0, catastrophicRate: 0.0)])
          let table = Report.renderTable(results)
          XCTAssertTrue(table.contains("n=1 (single sample)"))
          XCTAssertFalse(table.contains("0.70±0.00"))   // must NOT render a misleading ±0.00
      }

      func testRenderTableEmpty() {
          let table = Report.renderTable(RunResults(promptHashes: ["x"], stats: []))
          XCTAssertTrue(table.contains("no results"))
      }

      func testReadScoresRoundTrip() throws {
          let runDir = URL(fileURLWithPath: NSTemporaryDirectory())
              .appendingPathComponent("bridge-eval-report-\(UUID().uuidString)")
          let score = Scorer.catastrophic(fixture: "f", model: "m", sample: 0)
          try ArtifactWriter.writeScored(score, key: "f__m__0", runDir: runDir)
          let scores = try ArtifactReader.readScores(runDir: runDir)
          XCTAssertEqual(scores.count, 1)
          XCTAssertTrue(scores.first?.catastrophic ?? false)
      }
  }
  ```
- [ ] Run it and expect FAILURE: `swift test --filter BridgeEvalTests.ReportCommandTests`. Expected: unresolved `Report`/`readScores` (red).
- [ ] Extend the reader. Add to `Sources/bridge-eval/ArtifactReader.swift` (inside the existing `enum ArtifactReader`, after `readManifest`):
  ```swift
      static func readScores(runDir: URL) throws -> [CaseScore] {
          let scoredDir = runDir.appendingPathComponent("scored")
          let fm = FileManager.default
          guard let names = try? fm.contentsOfDirectory(atPath: scoredDir.path) else {
              throw ReadError(message: "no scored/ dir at \(scoredDir.path)")
          }
          return try names.filter { $0.hasSuffix(".json") }.sorted().map { name in
              let data = try Data(contentsOf: scoredDir.appendingPathComponent(name))
              return try JSONDecoder().decode(CaseScore.self, from: data)
          }
      }
  ```
- [ ] Write the renderer + subcommand. Write `Sources/bridge-eval/ReportCommand.swift`:
  ```swift
  import Foundation
  import ArgumentParser

  /// Pure human-table rendering of aggregate results (design §3 `report`). A single-sample stat renders
  /// `n=1 (single sample)` instead of a misleading `±0.00` (premortem Fix 3).
  enum Report {
      static func renderTable(_ results: RunResults) -> String {
          guard !results.stats.isEmpty else {
              return "no results (prompts \(results.promptHashes.joined(separator: ",")))\n"
          }
          func f(_ x: Double) -> String { String(format: "%.2f", x) }
          func cell(_ a: AggregateF1) -> String {
              a.n <= 1 ? "\(f(a.mean)) n=1 (single sample)" : "\(f(a.mean))±\(f(a.stdev))"
          }
          var lines = ["prompts \(results.promptHashes.joined(separator: ","))",
                       "fixture\tmodel\tstrictF1\tlenientF1\tconsistency\tcatastrophic"]
          for s in results.stats {
              lines.append([
                  s.fixture, s.model,
                  cell(s.strictF1),
                  cell(s.lenientF1),
                  f(s.outputConsistency),
                  f(s.catastrophicRate),
              ].joined(separator: "\t"))
          }
          return lines.joined(separator: "\n") + "\n"
      }
  }

  /// `report` subcommand: re-aggregate a run dir's scored/*.json into a table + results.json (pure).
  struct ReportCommand: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
          commandName: "report",
          abstract: "Aggregate a run directory into a human table and machine results.json (no network).")

      @Option(name: .long, help: "Run directory containing scored/*.json and manifest.json.") var runDir: String

      func run() async throws {
          let dir = URL(fileURLWithPath: runDir)
          let manifest = try ArtifactReader.readManifest(runDir: dir)
          let scores = try ArtifactReader.readScores(runDir: dir)
          let results = Aggregator.aggregate(scores, promptHashes: manifest.promptHashes)
          try ArtifactWriter.writeResults(results, runDir: dir)
          print(Report.renderTable(results))
      }
  }
  ```
- [ ] Run it and expect PASS: `swift test --filter BridgeEvalTests.ReportCommandTests`. Expected: 4 tests pass.
- [ ] Commit:
  ```bash
  git add Sources/bridge-eval/ArtifactReader.swift Sources/bridge-eval/ReportCommand.swift Tests/BridgeEvalTests/ReportCommandTests.swift
  git commit -m "feat(eval): add report subcommand with single-sample-aware table renderer"
  ```

---

### Task 12: RunCommand — network/PDF subcommand (macOS-guarded, design §3 `run`)

**Files**
- create `Sources/bridge-eval/RunCommand.swift`
- create `Tests/BridgeEvalTests/RunCommandTests.swift`

`run` is the ONLY network-touching path (design §3, §10) and the ONLY one that reads PDFs — so the PDF/network leg is wrapped in `#if canImport(PDFKit) && os(macOS)`. It is unit-tested with a STUB `LLMExtractor` (zero network, zero keys — design §10): a pure `RunCore.runCase` takes an injected extractor + pre-read PDF bytes + prompt, executes the production step sequence, and produces `(RawArtifact, CaseScore)`. The CLI `run()` wires preflight guard -> fixtures discovery -> manifest write (BEFORE the loop) -> per-case PDF read -> `RunCore.runCase` -> artifact writes -> aggregate. Provider/extractor selection mirrors the CLI's `Provider` enum and `AnthropicExtractor`/`OpenAIExtractor` initializers (scout §5).

**Premortem Fix 4 — manifest-first:** the manifest is written BEFORE the fixture loop begins. It needs only models, params, sampleCount, fixture list, and the distinct prompt hashes — all known up front (the prompt hashes are computed by pre-reading each fixture's pages once before the network loop). A mid-run transport error then still leaves a readable run dir that `score` can replay.

**Premortem Fix 5 — distinct prompt hashes:** the manifest and results carry the DISTINCT set of per-case prompt hashes (one per fixture prompt), computed in the pre-pass.

**Interfaces**
- Consumes: `PDFText.pages` (guarded), `ExtractionPrompt.make`, `LLMRequest`, `any LLMExtractor`, `LLMResponseContract.*`, `Hashing`, `Scorer`, `ArtifactWriter`, `Preflight`, `Fixtures`.
- Produces:
  ```swift
  enum RunCore {
      static func runCase(pdfData: Data, pages: [String], model: String, fixture: String, sample: Int,
                          extractor: any LLMExtractor, expected: ExpectedDoc, subjectId: String,
                          now: Date) async throws -> (raw: RawArtifact, score: CaseScore)
  }
  struct RunCommand: AsyncParsableCommand { ... }   // macOS-guarded network body
  ```

**Steps**

- [ ] Write the failing tests with a STUB extractor (no `#if` needed — `RunCore` itself is platform-free; only the PDF READ is guarded, and the test supplies `pages` directly). Write `Tests/BridgeEvalTests/RunCommandTests.swift`:
  ```swift
  import XCTest
  import HealthBridgeParsing
  @testable import bridge_eval

  private struct StubExtractor: LLMExtractor {
      let response: LLMRawResponse
      let error: LLMError?
      init(json: String, meta: LLMResponseMeta? = nil) {
          self.response = LLMRawResponse(jsonText: json, meta: meta); self.error = nil
      }
      init(error: LLMError) {
          self.response = LLMRawResponse(jsonText: ""); self.error = error
      }
      func extract(_ request: LLMRequest) async throws -> LLMRawResponse {
          if let error { throw error }
          return response
      }
  }

  final class RunCommandTests: XCTestCase {
      private let goodJSON = """
      {"patients":[{"name":"Jane Public","dob":"1990-05-01"}],
       "observations":[{"loinc":"8867-4","display":"Heart rate","value":72.5,"unit":"/min",
                        "effectiveDate":"2024-01-15","category":"vital","confidence":0.9}]}
      """
      private func expectedDoc() -> ExpectedDoc {
          ExpectedDoc(patients: [ExpectedPatient(name: "Jane Public", dob: "1990-05-01")],
                      observations: [ExpectedObservation(loinc: "8867-4", display: "Heart rate", value: 72.5,
                                     valueText: nil, unit: "/min", effectiveDate: "2024-01-15", category: "vital")])
      }

      func testRunCaseProducesRawAndScore() async throws {
          let meta = LLMResponseMeta(inputTokens: 10, outputTokens: 20, stopReason: "stop")
          let (raw, score) = try await RunCore.runCase(
              pdfData: Data("%PDF-1.4".utf8), pages: ["Heart rate 72.5 /min on 2024-01-15"],
              model: "m", fixture: "vitals-basic", sample: 0,
              extractor: StubExtractor(json: goodJSON, meta: meta), expected: expectedDoc(),
              subjectId: "subj", now: Date())
          XCTAssertEqual(raw.jsonText, goodJSON)
          XCTAssertEqual(raw.inputTokens, 10)
          XCTAssertEqual(raw.stopReason, "stop")
          XCTAssertFalse(raw.promptHash.isEmpty)
          XCTAssertFalse(raw.inputHash.isEmpty)
          XCTAssertEqual(score.strict.f1, 1.0, accuracy: 1e-9)
      }

      func testRunCaseMalformedResponseIsCatastrophicButStillRaw() async throws {
          let (raw, score) = try await RunCore.runCase(
              pdfData: Data("%PDF".utf8), pages: ["x"], model: "m", fixture: "f", sample: 0,
              extractor: StubExtractor(json: "not json"), expected: expectedDoc(),
              subjectId: "subj", now: Date())
          XCTAssertEqual(raw.jsonText, "not json")   // raw preserved for replay/research
          XCTAssertTrue(score.catastrophic)
      }

      func testRunCasePropagatesTransportError() async {
          do {
              _ = try await RunCore.runCase(
                  pdfData: Data("%PDF".utf8), pages: ["x"], model: "m", fixture: "f", sample: 0,
                  extractor: StubExtractor(error: .transport("boom")), expected: expectedDoc(),
                  subjectId: "subj", now: Date())
              XCTFail("expected throw")
          } catch let e as LLMError {
              XCTAssertEqual(e, .transport("boom"))
          } catch { XCTFail("wrong error \(error)") }
      }
  }
  ```
- [ ] Run it and expect FAILURE: `swift test --filter BridgeEvalTests.RunCommandTests`. Expected: unresolved `RunCore` (red).
- [ ] Write the implementation. Write `Sources/bridge-eval/RunCommand.swift`:
  ```swift
  import Foundation
  import ArgumentParser
  import HealthBridgeParsing

  /// PURE-ish per-case execution of the production step sequence with an INJECTED extractor (design §3,
  /// §10). It takes pre-read `pdfData` + `pages` so it is platform-free and stub-testable without PDFKit;
  /// the macOS-guarded `PDFText.pages` read happens in the `RunCommand.run()` shell. A transport/HTTP
  /// error propagates (the run records nothing for that sample); a malformed reply still yields a raw
  /// artifact (preserved for replay/research) plus a catastrophic score.
  enum RunCore {
      static func runCase(pdfData: Data, pages: [String], model: String, fixture: String, sample: Int,
                          extractor: any LLMExtractor, expected: ExpectedDoc, subjectId: String,
                          now: Date) async throws -> (raw: RawArtifact, score: CaseScore) {
          let prompt = ExtractionPrompt.make(pages: pages)
          let promptHash = Hashing.promptHash(prompt)
          let inputHash = Hashing.sha256Hex(pdfData)
          let request = LLMRequest(pages: pages, instructions: prompt, model: model)

          let start = Date()
          let response = try await extractor.extract(request)   // network error propagates
          let latencyMillis = Int(Date().timeIntervalSince(start) * 1000)

          let key = ArtifactWriter.key(promptHash: promptHash, model: model, fixture: fixture, sample: sample)
          let raw = RawArtifact(key: key, promptHash: promptHash, inputHash: inputHash, model: model,
                                fixture: fixture, sample: sample, jsonText: response.jsonText,
                                inputTokens: response.meta?.inputTokens, outputTokens: response.meta?.outputTokens,
                                stopReason: response.meta?.stopReason, latencyMillis: latencyMillis)

          let score: CaseScore
          do {
              let result = try LLMResponseContract.decode(response.jsonText, subjectId: subjectId, now: now)
              let distinct = (try? LLMResponseContract.distinctPatientCount(response.jsonText)) ?? 0
              let patient = (try? LLMResponseContract.extractedPatient(response.jsonText)) ?? nil
              score = Scorer.score(fixture: fixture, model: model, sample: sample, result: result,
                                   expected: expected, extractedPatient: patient, distinctPatientCount: distinct)
          } catch {
              score = Scorer.catastrophic(fixture: fixture, model: model, sample: sample)
          }
          return (raw, score)
      }
  }

  /// `run` subcommand: fixtures × models × N samples → call models → write raw + scored + results.
  /// The PDF read and adapter calls touch disk/network, so the body is macOS-guarded (PDFKit) and never
  /// runs in CI (design §10). The preflight guard refuses git-tracked fixture/run paths (design §9). The
  /// manifest is written BEFORE the network loop (Fix 4) so a mid-run failure leaves a replayable run dir.
  struct RunCommand: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
          commandName: "run",
          abstract: "Run fixtures × models × N samples against live models; write run artifacts.")

      @Option(name: .long, help: "Fixtures root (default: eval/fixtures).") var fixtures: String = "eval/fixtures"
      @Option(name: .long, help: "Runs root (default: eval/runs).") var runsRoot: String = "eval/runs"
      @Option(name: .long, parsing: .upToNextOption, help: "Model ids to evaluate.") var models: [String] = ["claude-opus-4-8"]
      @Option(name: .long, help: "Provider (anthropic|openai).") var provider: String = "anthropic"
      @Option(name: .long, help: "API key (else the provider env var). Never persisted/logged.") var apiKey: String?
      @Option(name: .long, help: "Samples per (fixture, model).") var samples: Int = 1
      @Option(name: .long, help: "Subject id used for the contract's single-subject decode.") var subjectId: String = "eval-subject"

      func run() async throws {
          #if canImport(PDFKit) && os(macOS)
          // PHI git-safety: refuse a tracked fixtures root or runs root (design §9).
          try Preflight.assertUntracked(fixtures, role: "fixtures")
          try Preflight.assertUntracked(runsRoot, role: "runs")

          let extractor = try makeExtractor()
          let cases = try Fixtures.discoverCases(root: fixtures)
          let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
          let dir = ArtifactWriter.runDir(runsRoot: runsRoot, timestamp: timestamp)

          // Pre-pass: read each fixture's pages ONCE, compute its prompt hash, and keep pages for the loop.
          // This lets the manifest be written BEFORE any network call (Fix 4) and record the DISTINCT
          // per-fixture prompt hashes (Fix 5).
          var pagesByCase: [String: [String]] = [:]
          var pdfDataByCase: [String: Data] = [:]
          var promptHashSet = Set<String>()
          for caseName in cases {
              let pdfData = try Data(contentsOf: Fixtures.inputPDFURL(root: fixtures, caseName: caseName))
              let pages = try PDFText.pages(pdfData)
              pagesByCase[caseName] = pages
              pdfDataByCase[caseName] = pdfData
              promptHashSet.insert(Hashing.promptHash(ExtractionPrompt.make(pages: pages)))
          }
          let promptHashes = promptHashSet.sorted()

          let manifest = Manifest(timestamp: timestamp, promptHashes: promptHashes,
                                  models: models, sampleCount: samples, fixtureNames: cases)
          try ArtifactWriter.writeManifest(manifest, runDir: dir)   // BEFORE the loop (Fix 4)

          var allScores: [CaseScore] = []
          for caseName in cases {
              let expected = try Fixtures.loadExpected(root: fixtures, caseName: caseName)
              let pages = pagesByCase[caseName] ?? []
              let pdfData = pdfDataByCase[caseName] ?? Data()
              for model in models {
                  for sample in 0..<samples {
                      let (raw, score) = try await RunCore.runCase(
                          pdfData: pdfData, pages: pages, model: model, fixture: caseName, sample: sample,
                          extractor: extractor, expected: expected, subjectId: subjectId, now: Date())
                      try ArtifactWriter.writeRaw(raw, runDir: dir)
                      try ArtifactWriter.writeScored(score, key: raw.key, runDir: dir)
                      allScores.append(score)
                  }
              }
          }

          let results = Aggregator.aggregate(allScores, promptHashes: promptHashes)
          try ArtifactWriter.writeResults(results, runDir: dir)
          FileHandle.standardError.write(Data("run complete -> \(dir.path)\n".utf8))
          #else
          throw ValidationError("`run` requires macOS (PDFKit). Use `score`/`report` on existing run dirs elsewhere.")
          #endif
      }

      #if canImport(PDFKit) && os(macOS)
      private func makeExtractor() throws -> any LLMExtractor {
          let envKey = ProcessInfo.processInfo.environment[provider == "openai" ? "OPENAI_API_KEY" : "ANTHROPIC_API_KEY"]
          guard let key = apiKey ?? envKey else {
              throw ValidationError("missing API key — pass --api-key or set the provider env var")
          }
          switch provider.lowercased() {
          case "anthropic": return AnthropicExtractor(apiKey: key)
          case "openai": return OpenAIExtractor(apiKey: key)
          default: throw ValidationError("unknown provider '\(provider)' — use anthropic or openai")
          }
      }
      #endif
  }
  ```
- [ ] Run it and expect PASS: `swift test --filter BridgeEvalTests.RunCommandTests`. Expected: 3 tests pass. (The macOS-guarded CLI body is compiled but not exercised by tests; `RunCore` is.)
- [ ] Commit:
  ```bash
  git add Sources/bridge-eval/RunCommand.swift Tests/BridgeEvalTests/RunCommandTests.swift
  git commit -m "feat(eval): add macOS-guarded run subcommand with manifest-first write"
  ```

---

### Task 13: @main root — wire the three subcommands + full-suite green

**Files**
- modify `Sources/bridge-eval/BridgeEval.swift`
- create `Tests/BridgeEvalTests/RootCommandTests.swift`

Replace the Task 1 stub's role: `BridgeEval` becomes the `@main AsyncParsableCommand` root with `subcommands: [RunCommand, ScoreCommand, ReportCommand]`, mirroring `HealthBridge` (scout §9 / `Sources/healthbridge/HealthBridge.swift`). Keep `BridgeEvalVersion` so the Task 1 smoke test still passes.

**Interfaces**
- Produces: `@main struct BridgeEval: AsyncParsableCommand` with the three subcommands.

**Steps**

- [ ] Write the failing test asserting the root wiring. Write `Tests/BridgeEvalTests/RootCommandTests.swift`:
  ```swift
  import XCTest
  import ArgumentParser
  @testable import bridge_eval

  final class RootCommandTests: XCTestCase {
      func testRootHasThreeSubcommands() {
          let names = BridgeEval.configuration.subcommands.map { $0.configuration.commandName }
          XCTAssertEqual(Set(names.compactMap { $0 }), ["run", "score", "report"])
      }

      func testRootCommandName() {
          XCTAssertEqual(BridgeEval.configuration.commandName, "bridge-eval")
      }

      func testScoreCommandParsesRunDirOption() throws {
          let parsed = try ScoreCommand.parse(["--run-dir", "/tmp/run", "--fixtures", "/tmp/fx"])
          XCTAssertEqual(parsed.runDir, "/tmp/run")
          XCTAssertEqual(parsed.fixtures, "/tmp/fx")
      }
  }
  ```
- [ ] Run it and expect FAILURE: `swift test --filter BridgeEvalTests.RootCommandTests`. Expected: `BridgeEval` is not a command yet (red).
- [ ] Rewrite the root. Write `Sources/bridge-eval/BridgeEval.swift` (full replacement):
  ```swift
  import Foundation
  import ArgumentParser

  /// bridge-eval — dev-only LLM-extraction evaluation harness (design §3). NOT in `products`, so it never
  /// ships in `healthbridge`. Three subcommands: `run` (network, macOS-guarded), `score` (pure offline
  /// rescore), `report` (pure aggregate). No iterate/research loop in v1 (design §11–12).
  @main
  struct BridgeEval: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
          commandName: "bridge-eval",
          abstract: "Evaluate LLM PDF-extraction responses against gold fixtures.",
          subcommands: [RunCommand.self, ScoreCommand.self, ReportCommand.self])
  }

  enum BridgeEvalVersion {
      static let current = "0.1.0"
  }
  ```
- [ ] Run the targeted test and expect PASS: `swift test --filter BridgeEvalTests.RootCommandTests`. Expected: 3 tests pass.
- [ ] Run the FULL bridge-eval suite and confirm everything is green: `swift test --filter BridgeEvalTests`. Expected: all tests across Tasks 1–13 pass (smoke, hashing, models, matcher, scorer, aggregator, preflight, fixtures, artifact writer/reader, score, report, run, root).
- [ ] Confirm the shipping CLI is untouched: `swift build --target healthbridge`. Expected: builds clean; `bridge-eval` is NOT in `products` (design §12).
- [ ] Commit:
  ```bash
  git add Sources/bridge-eval/BridgeEval.swift Tests/BridgeEvalTests/RootCommandTests.swift
  git commit -m "feat(eval): wire @main root with run/score/report subcommands"
  ```

---

## Self-review

### Spec-coverage map (design §1–§12 → tasks)

| Design ref | Requirement | Task(s) |
|---|---|---|
| §1, §3 | Reproduce production pipeline via public steps, not `extractDocument` | 12 (`RunCore` calls PDFText.pages→ExtractionPrompt.make→LLMRequest→extract→contract) |
| §2, §13.2 | Separate `run`/`score`/`report` subcommands | 10, 11, 12, 13 |
| §3 | Dev-only target, not in `products` | 1, 13 |
| §4 | Capture input hash, prompt hash, raw envelope + tokens + stop_reason, decode outcome, observations, skips, patient, timing | 2 (hashes), 3 (`RawArtifact` fields), 12 (`RunCore` populates all) |
| §5 | Two-tier fixtures; `expected.json` = contract shape; `--fixtures` override; Tier A committed synthetic | 3 (`ExpectedDoc` shape), 8 (loader + synthetic gold), 10/12 (`--fixtures`) |
| §6 | Contract conformance (catastrophic + skip histogram) + extraction quality (hit/partial/missed-rejected/missed-absent/hallucinated), field grading, strict/lenient F1, exact numeric grading | 4 (matcher), 5 (scorer, display-name missed-rejected linkage, histogram, F1) |
| §7 | N samples, mean±stdev F1, output-consistency, run-dir layout (manifest/raw/scored/results), key format | 6 (aggregator + N=1 stdev), 9 (writer + key + layout), 12 (sampling loop + manifest-first) |
| §8 | Structured `Skip.Detail` histogram keying | 5 (`skipDetailKey`) — consumes the already-merged `Skip.Detail` |
| §9, §13.3 | gitignore up front, preflight git-tracked refusal, manifest no-PHI, synthetic-only tests | 1 (gitignore), 7 (preflight), 3/9 (manifest = hashes/params only), all tests Tier A |
| §10 | Pure matcher/scorer unit-tested; `run` only network path, key-gated; preflight unit-tested | 4–6 (pure tests), 7 (preflight tests), 12 (stub-tested `RunCore`) |
| §11 | Growth path: results.json fitness, raw/ as research input; no loop in v1 | covered structurally (artifacts), explicitly excluded |
| §12 | YAGNI: no iterate/research, no calibration, no third provider, no CLI change | excluded; CryptoKit/JSON re-impl keeps `healthbridge` untouched (Task 9 note) |

**No spec gaps for §1–§12.** Two deliberate, design-sanctioned simplifications (flagged for the user's call): (a) numeric value EXACT only — tolerance knob deferred per §13.1; (b) confidence-calibration data is captured in `Observation.confidence` via the decoded result but no calibration analysis is built, per §12.

### Premortem-fix coverage (the five folded-in items)

| Fix | Item | Where applied |
|---|---|---|
| 1 | Date-parser unification on `LLMResponseContract.parseDate` | Task 4 (interface, narrative, impl, tests incl. offset-timestamp + unparseable); Tasks 3/5 narrative + test helpers use `parseDate` |
| 2 | `missedRejected` display-name linkage (label = display, not loinc) | Task 5 (`rejectedLoincSet` matches loinc OR display; `// best-effort diagnostic … does not affect F1` comment; production-shape display-only test + loinc-in-label test) |
| 3 | N=1 stdev | Task 6 (`testSingleSampleStdevIsZeroWithNOne`); Task 11 (`n=1 (single sample)` cell + `testRenderTableSingleSampleAnnotatesN1`) |
| 4 | Manifest-first write | Task 12 (pre-pass reads pages once, writes manifest BEFORE the network loop) |
| 5 | Per-run distinct prompt hashes | Task 3 (`Manifest.promptHashes: [String]`, `RunResults.promptHashes: [String]`, per-case `RawArtifact.promptHash`); Task 6 (`aggregate(_:promptHashes:)`); Task 10 (distinct from raws); Task 11 (from manifest); Task 12 (pre-pass distinct set) |

### Placeholder scan
No placeholders. Every Swift code block is complete and compilable: every type referenced (`Observation`, `ObservationValue`, `CodeableRef`, `ParseResult`, `Skip`, `Skip.Detail`, `LLMRequest`, `LLMRawResponse`, `LLMResponseMeta`, `LLMError`, `LLMResponseContract.parseDate`, `AnthropicExtractor`, `OpenAIExtractor`) is defined either in the scout map / verified source (consumed) or in an earlier task (produced). No "similar to Task N", no "add error handling" — error paths are written out (catastrophic, transport-error propagation, missing-key, guard refusal, unparseable expected date).

### Type-consistency check
- `ExtractionPrompt.make(pages: [String]) -> String` — used verbatim in Task 12; promptHash computed via `Hashing.promptHash` (Task 2), NOT from `make` (mismatch #1 baked in). ✓
- `LLMResponseContract.parseDate(_ s: String) -> Date?` — VERIFIED public at `LLMResponseContract.swift:257`; used by Matcher (Task 4) and the Task 4/5 test helpers as the single date-parsing source of truth (Fix 1). ✓
- `LLMResponseContract.mapEntry` sets `label = dto.display ?? dto.loinc ?? "Unknown"` — VERIFIED at `LLMResponseContract.swift:116`; drives the Task 5 display-name linkage (Fix 2). ✓
- `PDFText.pages(_ data: Data) throws -> [String]` — macOS-guarded; called only in `RunCommand.run()` body inside `#if canImport(PDFKit) && os(macOS)` (mismatch #4 baked in). ✓
- `extractor.extract(_:) async throws -> LLMRawResponse` + `LLMResponseMeta(inputTokens:outputTokens:stopReason:)` — Task 12 reads `response.meta?.inputTokens/.outputTokens/.stopReason`. ✓
- `LLMResponseContract.decode(_:subjectId:subjectDOB:now:) throws -> ParseResult`, `.distinctPatientCount(_:) throws -> Int`, `.extractedPatient(_:) throws -> (name:String,dob:String)?` — used in Tasks 10 and 12 with exactly these signatures (verified by reading the source). ✓
- `Skip(reason:label:detail:)`, `Skip.Reason`, `Skip.Detail` cases (`bothValueAndText/noUsableValue/nonFiniteValue/confidenceOutOfRange(got:)/dateMalformed/dateBeforeDOB/dateAfterNow/missingCode`) — `skipDetailKey` (Task 5) handles every case. ✓
- `Observation` fields (`code: CodeableRef?`, `value: ObservationValue`, `unit: String?`, `effectiveDate: Date`, `category: ObservationCategory`, `confidence: Double`) — matcher/scorer use exactly these. ✓
- `Manifest.promptHashes: [String]` / `RunResults.promptHashes: [String]` (Fix 5) — produced in Task 3, consumed consistently by `Aggregator.aggregate(_:promptHashes:)` (Task 6), `ScoreCommand` (distinct from raws, Task 10), `ReportCommand` (from manifest, Task 11), `RunCommand` (pre-pass distinct set, Task 12). No stale `promptHash:` singular references remain. ✓
- `RawResponseLog` NOT imported anywhere — Task 9 re-implements writing (mismatch #3 baked in). ✓
- Cross-task type continuity: `CaseScore`/`RunResults`/`Manifest`/`RawArtifact` produced in Task 3 are consumed unchanged by Tasks 5, 6, 9, 10, 11, 12. ✓
- ArgumentParser style mirrors `HealthBridge` exactly: `@main`, `CommandConfiguration(commandName:abstract:subcommands:)`, `@Option(name: .long)`, `AsyncParsableCommand`. ✓

All consistent — no fixes required. (`ScoreCommand` no longer reads the manifest, so its earlier `readManifest` call was removed; results' `promptHashes` now derive from the raw artifacts, which is more accurate than trusting a possibly-partial manifest.)
