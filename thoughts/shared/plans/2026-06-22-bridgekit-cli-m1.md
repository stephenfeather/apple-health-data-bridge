# BridgeKit + healthbridge CLI (Milestone 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an all-Swift package that parses a FHIR R4 JSON medical-record document into a validated, subject-bound `*.bridge.json` Bridge Document, driven by a layered TOML config, with each observation pre-resolved against a LOINC→HealthKit mapping table and written to per-subject storage.

**Architecture:** One Swift Package Manager package. `BridgeKit` (platform-pure library: schema, mapping, ID derivation, validation). `HealthBridgeConfig` (library: TOML config model + layered settings resolution). `HealthBridgeParsing` (library: `DocumentParser` protocol + `FHIRParser`, depends on `BridgeKit` + `FHIRModels`). `healthbridge` (executable: `ArgumentParser` CLI with `parse` and `subject` subcommands). Data flows: config+flags → resolved `Settings`; FHIR JSON → `[Observation]` → resolve mapping → dedupe → subject-bound `BridgeDocument` → JSON file under the subject's storage dir.

**Tech Stack:** Swift 5.9+, SwiftPM, Apple `FHIRModels` (`ModelsR4`), `swift-argument-parser`, `TOMLKit`, `CryptoKit` (SHA-256, built-in).

## Global Constraints

- Swift tools version **5.9**. Platforms **`.macOS(.v13)`, `.iOS(.v16)`** (`BridgeKit` must compile for iOS; `CryptoKit` is on both).
- Verified dependency versions: **FHIRModels 0.9.3**, **swift-argument-parser 1.8.2**. `TOMLKit` is pinned at scaffold time (Task 1) and recorded in `Package.resolved`.
- `BridgeKit` imports only `Foundation` + `CryptoKit` — never `ModelsR4`, `ArgumentParser`, `TOMLKit`.
- Bridge Document JSON is **deterministic**: `JSONEncoder` with `outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`, `dateEncodingStrategy = .iso8601`; decoder `dateDecodingStrategy = .iso8601`. Dates normalize to **whole-second UTC** (no fractional seconds) — a deliberate, dedup-stable choice.
- `schemaVersion` current value: **1**. FHIR-derived observations carry `confidence = 1.0`.
- LOINC system URI: **`http://loinc.org`**.
- **Settings precedence (hard rule): CLI flag > TOML config > built-in default.** Every scalar config setting has a matching `--flag`. (The subject *roster* is a managed collection, not a scalar setting — managed via `healthbridge subject add/list`, selected per-run with `--subject <key>`.)
- **Subject binding:** every Bridge Document carries `subjectId` (UUID), `subjectLabel`, and `subjectHash` (`sha256` of canonical `name|dob`). The CLI cross-checks the selected subject against the FHIR `Patient` and refuses on mismatch. Per-file idempotency is scoped by `documentKey = source file sha256`; cross-file dedup is a later milestone.
- **No network in tests.** Fixtures are checked-in JSON/TOML. **No PHI** in the repo (synthetic/public data only); processed `*.bridge.json` are gitignored and never committed.
- **Commit protocol — NEVER run `git commit` or `git push`.** All implementation runs in a **git worktree on a feature branch** (never `main`). Each "Commit" step: `git add <files>` (and `git rm` for deletions) to stage — the only raw git permitted, because `github-agent-commit` reads `git diff --cached` — then **`github-agent-commit "<message>"`** (signed; refuses `main`; auto-creates the remote branch; resets local to `origin/<branch>` after, so stage everything first). Do NOT run `git commit`/`push`/`fetch`/`reset`/`checkout`/`update-ref`; read-only `git status`/`git diff` is fine. Confirm `GITHUB_APP_ID`/`GITHUB_APP_INSTALLATION_ID`/`GITHUB_APP_PRIVATE_KEY` are set (via repo `.envrc`/direnv) before the first commit; if empty, STOP. All GitHub API / PRs use **`agent-gh`**, never raw `gh`. The milestone lands as **one PR** to `main` via `agent-gh pr create … --body-file <file>`.
- TDD throughout: failing test first, minimal implementation, green, commit.

---

## File Structure

```
Package.swift
Sources/
  BridgeKit/
    BridgeDocument.swift     # BridgeDocument, Source, SourceKind, Extractor, SubjectRef
    Observation.swift        # Observation, ObservationValue, ObservationCategory, CodeableRef, SourceLocator
    HealthKitMapping.swift
    BridgeJSON.swift
    ObservationID.swift
    SubjectHash.swift        # canonical sha256(name|dob)
    MappingTable.swift
    Validation.swift
  HealthBridgeConfig/
    Config.swift             # TOML model: Config, SubjectEntry (snake_case keys)
    Settings.swift           # Settings, LogLevel, Overrides, SettingsResolver, ConfigLoader
  HealthBridgeParsing/
    DocumentParser.swift     # DocumentParser protocol, ParseResult, Skip, ParseError
    FHIRParser.swift
  healthbridge/
    HealthBridge.swift       # @main root + Parse + Subject subcommands
Tests/
  BridgeKitTests/...
  HealthBridgeConfigTests/...
  HealthBridgeParsingTests/{...,Fixtures/}
  healthbridgeTests/{...,Fixtures/}
```

---

## Task 1: Package scaffold

**Files:**
- Create: `Package.swift`
- Create stub sources: `Sources/BridgeKit/BridgeKit.swift`, `Sources/HealthBridgeConfig/Placeholder.swift`, `Sources/HealthBridgeParsing/Placeholder.swift`, `Sources/healthbridge/main.swift`
- Test: `Tests/BridgeKitTests/SmokeTests.swift`

**Interfaces:**
- Produces: a resolving, building package with `BridgeKit`, `HealthBridgeConfig`, `HealthBridgeParsing` libraries and the `healthbridge` executable.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "apple-health-data-bridge",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "BridgeKit", targets: ["BridgeKit"]),
        .library(name: "HealthBridgeConfig", targets: ["HealthBridgeConfig"]),
        .library(name: "HealthBridgeParsing", targets: ["HealthBridgeParsing"]),
        .executable(name: "healthbridge", targets: ["healthbridge"]),
    ],
    dependencies: [
        // Verified: FHIRModels 0.9.3, swift-argument-parser 1.8.2. TOMLKit pinned on resolve.
        .package(url: "https://github.com/apple/FHIRModels.git", .upToNextMinor(from: "0.9.3")),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .target(name: "BridgeKit"),
        .target(name: "HealthBridgeConfig", dependencies: [.product(name: "TOMLKit", package: "TOMLKit")]),
        .target(
            name: "HealthBridgeParsing",
            dependencies: ["BridgeKit", .product(name: "ModelsR4", package: "FHIRModels")]
        ),
        .executableTarget(
            name: "healthbridge",
            dependencies: [
                "HealthBridgeParsing", "HealthBridgeConfig", "BridgeKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "BridgeKitTests", dependencies: ["BridgeKit"]),
        // HealthBridgeConfigTests added in Task 2; HealthBridgeParsingTests in Task 8;
        // healthbridgeTests in Task 9. A test target with no .swift sources fails to build,
        // so each is declared in the task that creates its first test file.
    ]
)
```

- [ ] **Step 2: Create stub sources**

`Sources/BridgeKit/BridgeKit.swift` → `// BridgeKit — schema, mapping, validation.`
`Sources/HealthBridgeConfig/Placeholder.swift` → `// placeholder, replaced in Task 2`
`Sources/HealthBridgeParsing/Placeholder.swift` → `// placeholder, replaced in Task 7`
`Sources/healthbridge/main.swift` → `// placeholder entry point, replaced in Task 9` (MUST be `main.swift` — an executable target needs an entry point; SwiftPM accepts a comment-only `main.swift`, verified).

- [ ] **Step 3: Smoke test** — `Tests/BridgeKitTests/SmokeTests.swift`:
```swift
import XCTest
@testable import BridgeKit

final class SmokeTests: XCTestCase {
    func testPackageBuilds() { XCTAssertTrue(true) }
}
```

- [ ] **Step 4: Resolve & build** — Run: `swift package resolve && swift build`. Expected: resolves FHIRModels 0.9.3, swift-argument-parser 1.8.2, and TOMLKit (record the pinned version in `Package.resolved`); builds clean. First build compiles FHIRModels from source (slow once).

- [ ] **Step 5: Run smoke test** — Run: `swift test --filter BridgeKitTests.SmokeTests`. Expected: PASS.

- [ ] **Step 6: Commit**
```
git add Package.swift Package.resolved Sources Tests
github-agent-commit "chore: scaffold SwiftPM package (BridgeKit, Config, Parsing, CLI targets)"
```

---

## Task 2: Config & layered Settings

**Files:**
- Modify: `Package.swift` (add `HealthBridgeConfigTests` target)
- Create: `Sources/HealthBridgeConfig/Config.swift`, `Sources/HealthBridgeConfig/Settings.swift`
- Delete: `Sources/HealthBridgeConfig/Placeholder.swift`
- Test: `Tests/HealthBridgeConfigTests/SettingsTests.swift`

**Interfaces:**
- Produces:
  - `struct Config: Codable, Equatable` — TOML model: `dataRoot: String?`, `defaultSubject: String?`, `logLevel: String?`, `subjects: [SubjectEntry]` (snake_case TOML keys via `CodingKeys`).
  - `struct SubjectEntry: Codable, Equatable` — `key, subjectId, label, name, dob` (all `String`).
  - `enum LogLevel: String { case quiet, normal, verbose }`.
  - `struct Overrides` — optional `dataRoot`, `subject`, `logLevel` carrying CLI flag values.
  - `struct Settings` — resolved: `dataRoot: URL`, `logLevel: LogLevel`, `subjects: [SubjectEntry]`, `selectedSubject: SubjectEntry?`.
  - `enum ConfigLoader { static func load(path: String) throws -> Config?; static var defaultPath: String }`.
  - `enum SettingsResolver { static func resolve(config: Config?, overrides: Overrides) -> Settings }` — applies precedence **override ?? config ?? default**; default `dataRoot` = `~/Documents/apple-health-data-bridge` (tilde-expanded); selects subject by `overrides.subject ?? config.defaultSubject`.

- [ ] **Step 1: Declare the test target** — add to `Package.swift` `targets:`:
```swift
        .testTarget(name: "HealthBridgeConfigTests", dependencies: ["HealthBridgeConfig"]),
```

- [ ] **Step 2: Write the failing test** — `Tests/HealthBridgeConfigTests/SettingsTests.swift`:
```swift
import XCTest
@testable import HealthBridgeConfig

final class SettingsTests: XCTestCase {
    private func config() -> Config {
        Config(dataRoot: "~/from-toml", defaultSubject: "caleb", logLevel: "normal",
               subjects: [SubjectEntry(key: "caleb", subjectId: "uuid-c", label: "Caleb",
                                       name: "Caleb Feather", dob: "2015-04-12")])
    }

    func testDefaultsWhenNoConfigNoOverrides() {
        let s = SettingsResolver.resolve(config: nil, overrides: Overrides())
        XCTAssertTrue(s.dataRoot.path.hasSuffix("Documents/apple-health-data-bridge"))
        XCTAssertEqual(s.logLevel, .normal)
        XCTAssertNil(s.selectedSubject)
    }

    func testConfigOverridesDefault() {
        let s = SettingsResolver.resolve(config: config(), overrides: Overrides())
        XCTAssertTrue(s.dataRoot.path.hasSuffix("from-toml"))
        XCTAssertEqual(s.selectedSubject?.key, "caleb") // from default_subject
    }

    func testFlagOverridesConfig() {
        let s = SettingsResolver.resolve(config: config(),
                                         overrides: Overrides(dataRoot: "~/from-flag", subject: nil, logLevel: .verbose))
        XCTAssertTrue(s.dataRoot.path.hasSuffix("from-flag"))
        XCTAssertEqual(s.logLevel, .verbose)
    }

    func testTildeExpanded() {
        let s = SettingsResolver.resolve(config: nil, overrides: Overrides(dataRoot: "~/x"))
        XCTAssertFalse(s.dataRoot.path.contains("~"))
    }

    func testSubjectSelectionByFlag() {
        let s = SettingsResolver.resolve(config: config(), overrides: Overrides(subject: "caleb"))
        XCTAssertEqual(s.selectedSubject?.subjectId, "uuid-c")
    }
}
```

- [ ] **Step 3: Run to verify it fails** — Run: `swift test --filter SettingsTests`. Expected: FAIL — types undefined.

- [ ] **Step 4: Implement** — `Sources/HealthBridgeConfig/Config.swift`:
```swift
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

public struct Config: Codable, Equatable, Sendable {
    public var dataRoot: String?
    public var defaultSubject: String?
    public var logLevel: String?
    public var subjects: [SubjectEntry]
    public init(dataRoot: String? = nil, defaultSubject: String? = nil,
                logLevel: String? = nil, subjects: [SubjectEntry] = []) {
        self.dataRoot = dataRoot; self.defaultSubject = defaultSubject
        self.logLevel = logLevel; self.subjects = subjects
    }
    enum CodingKeys: String, CodingKey {
        case subjects
        case dataRoot = "data_root"
        case defaultSubject = "default_subject"
        case logLevel = "log_level"
    }
}
```

`Sources/HealthBridgeConfig/Settings.swift`:
```swift
import Foundation
import TOMLKit

public enum LogLevel: String, Sendable { case quiet, normal, verbose }

public struct Overrides: Sendable {
    public var dataRoot: String?
    public var subject: String?
    public var logLevel: LogLevel?
    public init(dataRoot: String? = nil, subject: String? = nil, logLevel: LogLevel? = nil) {
        self.dataRoot = dataRoot; self.subject = subject; self.logLevel = logLevel
    }
}

public struct Settings: Sendable {
    public let dataRoot: URL
    public let logLevel: LogLevel
    public let subjects: [SubjectEntry]
    public let selectedSubject: SubjectEntry?
}

public enum ConfigLoader {
    public static var defaultPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/apple-health-data-bridge/config.toml")
    }
    /// Returns nil if the file does not exist; throws on malformed TOML.
    public static func load(path: String) throws -> Config? {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }
        let text = try String(contentsOfFile: expanded, encoding: .utf8)
        return try TOMLDecoder().decode(Config.self, from: text)
    }
}

public enum SettingsResolver {
    private static let defaultDataRoot = "~/Documents/apple-health-data-bridge"

    public static func resolve(config: Config?, overrides: Overrides) -> Settings {
        let rawRoot = overrides.dataRoot ?? config?.dataRoot ?? defaultDataRoot
        let dataRoot = URL(fileURLWithPath: (rawRoot as NSString).expandingTildeInPath)

        let level = overrides.logLevel
            ?? config?.logLevel.flatMap(LogLevel.init(rawValue:))
            ?? .normal

        let subjects = config?.subjects ?? []
        let selectedKey = overrides.subject ?? config?.defaultSubject
        let selected = selectedKey.flatMap { key in subjects.first { $0.key == key } }

        return Settings(dataRoot: dataRoot, logLevel: level, subjects: subjects, selectedSubject: selected)
    }
}
```
Delete `Sources/HealthBridgeConfig/Placeholder.swift`.

> Note: `TOMLDecoder`/`TOMLEncoder` are TOMLKit's Codable entry points. If the pinned TOMLKit version spells them differently, the failing test surfaces it; adjust the two call sites.

- [ ] **Step 5: Run to verify pass** — Run: `swift test --filter SettingsTests`. Expected: all PASS.

- [ ] **Step 6: Commit**
```
git add Package.swift Sources/HealthBridgeConfig Tests/HealthBridgeConfigTests
git rm Sources/HealthBridgeConfig/Placeholder.swift
github-agent-commit "feat(config): TOML config model and layered settings resolution"
```

---

## Task 3: Bridge Document schema + subject binding + deterministic JSON

**Files:**
- Create: `Sources/BridgeKit/BridgeDocument.swift`, `Sources/BridgeKit/Observation.swift`, `Sources/BridgeKit/HealthKitMapping.swift`, `Sources/BridgeKit/BridgeJSON.swift`
- Delete: `Sources/BridgeKit/BridgeKit.swift`
- Test: `Tests/BridgeKitTests/BridgeDocumentCodingTests.swift`

**Interfaces:**
- Produces the schema types. **`BridgeDocument` carries a required `subject: SubjectRef`** binding the doc to a person.
  - `struct SubjectRef: Codable, Equatable, Sendable { var id: String; var label: String; var hash: String; var name: String?; var dob: String? }` — `id` = UUID, `hash` = `sha256(name|dob)`.
  - `BridgeDocument { schemaVersion: Int; source: Source; subject: SubjectRef; observations: [Observation] }`.
  - `Source { kind: SourceKind; fileName: String; sha256: String; extractedAt: Date; extractor: Extractor }`; `SourceKind: String { fhir, ccda, pdf }`; `Extractor { engine, version }`.
  - `Observation { id; code: CodeableRef?; name; value: ObservationValue; unit: String?; effectiveDate: Date; category: ObservationCategory; mapping: HealthKitMapping?; confidence: Double; sourceLocator: SourceLocator? }`.
  - `enum ObservationValue: Equatable { case quantity(Double); case string(String) }` with custom tagged `Codable`.
  - `enum ObservationCategory: String { vital, lab, other }`; `struct CodeableRef { system, code, display }`; `struct SourceLocator { page: Int?; snippet: String? }`.
  - `struct HealthKitMapping { quantityType, canonicalUnit, convertedValue }`.
  - `enum BridgeJSON { static let encoder; static let decoder }`.

- [ ] **Step 1: Write failing coding test** — `Tests/BridgeKitTests/BridgeDocumentCodingTests.swift`:
```swift
import XCTest
@testable import BridgeKit

final class BridgeDocumentCodingTests: XCTestCase {
    private func sampleDocument() -> BridgeDocument {
        let obs = Observation(
            id: "abc123",
            code: CodeableRef(system: "http://loinc.org", code: "29463-7", display: "Body weight"),
            name: "Body weight", value: .quantity(72.5), unit: "kg",
            effectiveDate: Date(timeIntervalSince1970: 1_700_000_000), category: .vital,
            mapping: HealthKitMapping(quantityType: "HKQuantityTypeIdentifierBodyMass",
                                      canonicalUnit: "kg", convertedValue: 72.5),
            confidence: 1.0, sourceLocator: nil)
        return BridgeDocument(
            schemaVersion: 1,
            source: Source(kind: .fhir, fileName: "x.json", sha256: "deadbeef",
                           extractedAt: Date(timeIntervalSince1970: 1_700_000_000),
                           extractor: Extractor(engine: "fhir-parser", version: "0.1.0")),
            subject: SubjectRef(id: "uuid-1", label: "Caleb", hash: "abcd",
                                name: "Caleb Feather", dob: "2015-04-12"),
            observations: [obs])
    }

    func testRoundTrip() throws {
        let original = sampleDocument()
        let data = try BridgeJSON.encoder.encode(original)
        let decoded = try BridgeJSON.decoder.decode(BridgeDocument.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testObservationValueEncodesTagged() throws {
        let json = String(decoding: try BridgeJSON.encoder.encode(ObservationValue.quantity(72.5)), as: UTF8.self)
        XCTAssertTrue(json.contains("\"type\" : \"quantity\""))
        XCTAssertTrue(json.contains("\"value\" : 72.5"))
    }

    func testDeterministicSortedKeys() throws {
        let json = String(decoding: try BridgeJSON.encoder.encode(sampleDocument()), as: UTF8.self)
        XCTAssertTrue(json.range(of: "\"category\"")!.lowerBound < json.range(of: "\"confidence\"")!.lowerBound)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — Run: `swift test --filter BridgeDocumentCodingTests`. Expected: FAIL.

- [ ] **Step 3: Implement** — `Sources/BridgeKit/HealthKitMapping.swift`:
```swift
import Foundation

public struct HealthKitMapping: Codable, Equatable, Sendable {
    public var quantityType: String
    public var canonicalUnit: String
    public var convertedValue: Double
    public init(quantityType: String, canonicalUnit: String, convertedValue: Double) {
        self.quantityType = quantityType; self.canonicalUnit = canonicalUnit; self.convertedValue = convertedValue
    }
}
```
`Sources/BridgeKit/Observation.swift`:
```swift
import Foundation

public struct CodeableRef: Codable, Equatable, Sendable {
    public var system: String; public var code: String; public var display: String
    public init(system: String, code: String, display: String) {
        self.system = system; self.code = code; self.display = display
    }
}

public enum ObservationCategory: String, Codable, Sendable { case vital, lab, other }

public struct SourceLocator: Codable, Equatable, Sendable {
    public var page: Int?; public var snippet: String?
    public init(page: Int? = nil, snippet: String? = nil) { self.page = page; self.snippet = snippet }
}

public enum ObservationValue: Equatable, Sendable {
    case quantity(Double)
    case string(String)
    private enum Kind: String, Codable { case quantity, string }
    private enum CodingKeys: String, CodingKey { case type, value }
}

extension ObservationValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .quantity: self = .quantity(try c.decode(Double.self, forKey: .value))
        case .string:   self = .string(try c.decode(String.self, forKey: .value))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .quantity(let d): try c.encode(Kind.quantity, forKey: .type); try c.encode(d, forKey: .value)
        case .string(let s):   try c.encode(Kind.string, forKey: .type);   try c.encode(s, forKey: .value)
        }
    }
}

public struct Observation: Codable, Equatable, Sendable {
    public var id: String
    public var code: CodeableRef?
    public var name: String
    public var value: ObservationValue
    public var unit: String?
    public var effectiveDate: Date
    public var category: ObservationCategory
    public var mapping: HealthKitMapping?
    public var confidence: Double
    public var sourceLocator: SourceLocator?
    public init(id: String, code: CodeableRef?, name: String, value: ObservationValue, unit: String?,
                effectiveDate: Date, category: ObservationCategory, mapping: HealthKitMapping?,
                confidence: Double, sourceLocator: SourceLocator?) {
        self.id = id; self.code = code; self.name = name; self.value = value; self.unit = unit
        self.effectiveDate = effectiveDate; self.category = category; self.mapping = mapping
        self.confidence = confidence; self.sourceLocator = sourceLocator
    }
}
```
`Sources/BridgeKit/BridgeDocument.swift`:
```swift
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
```
`Sources/BridgeKit/BridgeJSON.swift`:
```swift
import Foundation

public enum BridgeJSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
```
Delete `Sources/BridgeKit/BridgeKit.swift`.

- [ ] **Step 4: Run to verify pass** — Run: `swift test --filter BridgeDocumentCodingTests`. Expected: all PASS.

- [ ] **Step 5: Commit**
```
git add Sources/BridgeKit Tests/BridgeKitTests/BridgeDocumentCodingTests.swift
github-agent-commit "feat(bridgekit): schema with subject binding and deterministic JSON"
```

---

## Task 4: Stable observation ID + subject hash

**Files:**
- Create: `Sources/BridgeKit/ObservationID.swift`, `Sources/BridgeKit/SubjectHash.swift`
- Test: `Tests/BridgeKitTests/ObservationIDTests.swift`, `Tests/BridgeKitTests/SubjectHashTests.swift`

**Interfaces:**
- `enum ObservationID { static func derive(documentKey: String, system: String?, code: String?, effectiveDate: Date, rawValue: String, unit: String?) -> String }` — lowercase hex SHA-256. **`documentKey` is the source file's `sha256`** → per-file idempotency (re-importing the same document never duplicates samples); cross-file dedup is a later milestone.
- `enum SubjectHash { static func make(name: String, dob: String) -> String }` — `sha256` of canonicalized `"\(name.lowercased().trimmed)|\(dob.trimmed)"`, lowercase hex. Used to bind/cross-check subjects.

- [ ] **Step 1: Write failing tests** — `Tests/BridgeKitTests/ObservationIDTests.swift`:
```swift
import XCTest
@testable import BridgeKit

final class ObservationIDTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    func testDeterministic() {
        let a = ObservationID.derive(documentKey: "d", system: "http://loinc.org", code: "29463-7",
                                     effectiveDate: date, rawValue: "72.5", unit: "kg")
        let b = ObservationID.derive(documentKey: "d", system: "http://loinc.org", code: "29463-7",
                                     effectiveDate: date, rawValue: "72.5", unit: "kg")
        XCTAssertEqual(a, b); XCTAssertEqual(a.count, 64)
    }
    func testValueChangesID() {
        let a = ObservationID.derive(documentKey: "d", system: nil, code: nil, effectiveDate: date, rawValue: "72.5", unit: "kg")
        let b = ObservationID.derive(documentKey: "d", system: nil, code: nil, effectiveDate: date, rawValue: "73.0", unit: "kg")
        XCTAssertNotEqual(a, b)
    }
    func testDocumentKeyChangesID() {
        let a = ObservationID.derive(documentKey: "d1", system: nil, code: nil, effectiveDate: date, rawValue: "x", unit: nil)
        let b = ObservationID.derive(documentKey: "d2", system: nil, code: nil, effectiveDate: date, rawValue: "x", unit: nil)
        XCTAssertNotEqual(a, b)
    }
}
```
`Tests/BridgeKitTests/SubjectHashTests.swift`:
```swift
import XCTest
@testable import BridgeKit

final class SubjectHashTests: XCTestCase {
    func testDeterministicAndCanonical() {
        XCTAssertEqual(SubjectHash.make(name: "Caleb Feather", dob: "2015-04-12"),
                       SubjectHash.make(name: "  caleb feather ", dob: "2015-04-12"))
    }
    func testDifferentPeopleDiffer() {
        XCTAssertNotEqual(SubjectHash.make(name: "Caleb Feather", dob: "2015-04-12"),
                          SubjectHash.make(name: "Stephen Feather", dob: "1975-01-01"))
    }
}
```

- [ ] **Step 2: Run to verify it fails** — Run: `swift test --filter "ObservationIDTests|SubjectHashTests"`. Expected: FAIL.

- [ ] **Step 3: Implement** — `Sources/BridgeKit/ObservationID.swift`:
```swift
import Foundation
import CryptoKit

public enum ObservationID {
    public static func derive(documentKey: String, system: String?, code: String?,
                              effectiveDate: Date, rawValue: String, unit: String?) -> String {
        let parts = [documentKey, system ?? "", code ?? "",
                     String(Int(effectiveDate.timeIntervalSince1970.rounded())), rawValue, unit ?? ""]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1f}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
```
`Sources/BridgeKit/SubjectHash.swift`:
```swift
import Foundation
import CryptoKit

public enum SubjectHash {
    public static func make(name: String, dob: String) -> String {
        let canonical = "\(name.lowercased().trimmingCharacters(in: .whitespaces))|\(dob.trimmingCharacters(in: .whitespaces))"
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: Run to verify pass** — Run: `swift test --filter "ObservationIDTests|SubjectHashTests"`. Expected: PASS.

- [ ] **Step 5: Commit**
```
git add Sources/BridgeKit/ObservationID.swift Sources/BridgeKit/SubjectHash.swift Tests/BridgeKitTests/ObservationIDTests.swift Tests/BridgeKitTests/SubjectHashTests.swift
github-agent-commit "feat(bridgekit): stable observation id and subject hash"
```

---

## Task 5: LOINC→HealthKit mapping table + unit conversion

**Files:**
- Create: `Sources/BridgeKit/MappingTable.swift`
- Test: `Tests/BridgeKitTests/MappingTableTests.swift`

**Interfaces:**
- `enum MappingTable { static func resolve(loinc: String?, value: ObservationValue, unit: String?) -> HealthKitMapping? }` — `nil` when LOINC unknown, value not `.quantity`, or unit unconvertible. Seed: **lean 10** (vitals + glucose); grow from CLI-reported unmapped evidence.

- [ ] **Step 1: Write failing test** — `Tests/BridgeKitTests/MappingTableTests.swift`:
```swift
import XCTest
@testable import BridgeKit

final class MappingTableTests: XCTestCase {
    func testMapsBodyWeightKilograms() {
        let m = MappingTable.resolve(loinc: "29463-7", value: .quantity(72.5), unit: "kg")
        XCTAssertEqual(m?.quantityType, "HKQuantityTypeIdentifierBodyMass")
        XCTAssertEqual(m?.convertedValue ?? 0, 72.5, accuracy: 0.0001)
    }
    func testConvertsPoundsToKilograms() {
        let m = MappingTable.resolve(loinc: "29463-7", value: .quantity(160), unit: "[lb_av]")
        XCTAssertEqual(m?.convertedValue ?? 0, 72.5747, accuracy: 0.01)
    }
    func testConvertsFahrenheitToCelsius() {
        let m = MappingTable.resolve(loinc: "8310-5", value: .quantity(98.6), unit: "[degF]")
        XCTAssertEqual(m?.quantityType, "HKQuantityTypeIdentifierBodyTemperature")
        XCTAssertEqual(m?.convertedValue ?? 0, 37.0, accuracy: 0.05)
    }
    func testUnknownLoincReturnsNil() { XCTAssertNil(MappingTable.resolve(loinc: "1234-5", value: .quantity(1), unit: "g")) }
    func testNonQuantityReturnsNil() { XCTAssertNil(MappingTable.resolve(loinc: "29463-7", value: .string("x"), unit: nil)) }
    func testUnconvertibleUnitReturnsNil() { XCTAssertNil(MappingTable.resolve(loinc: "29463-7", value: .quantity(1), unit: "banana")) }
}
```

- [ ] **Step 2: Run to verify it fails** — Run: `swift test --filter MappingTableTests`. Expected: FAIL.

- [ ] **Step 3: Implement** — `Sources/BridgeKit/MappingTable.swift`:
```swift
import Foundation

struct MappingEntry {
    let loinc: String
    let quantityType: String
    let canonicalUnit: String
    let convert: (Double, String?) -> Double?
}

public enum MappingTable {
    public static func resolve(loinc: String?, value: ObservationValue, unit: String?) -> HealthKitMapping? {
        guard let loinc, case .quantity(let raw) = value, let entry = table[loinc],
              let converted = entry.convert(raw, unit) else { return nil }
        return HealthKitMapping(quantityType: entry.quantityType, canonicalUnit: entry.canonicalUnit, convertedValue: converted)
    }

    private static func passthrough(_ ok: Set<String>) -> (Double, String?) -> Double? {
        { v, u in (u == nil || ok.contains(u!)) ? v : nil }
    }
    private static let mass: (Double, String?) -> Double? = { v, u in
        switch u { case "kg", nil: return v; case "g": return v/1000; case "[lb_av]", "lb": return v*0.45359237; default: return nil } }
    private static let length: (Double, String?) -> Double? = { v, u in
        switch u { case "cm", nil: return v; case "m": return v*100; case "[in_i]", "in": return v*2.54; default: return nil } }
    private static let temperature: (Double, String?) -> Double? = { v, u in
        switch u { case "Cel", "degC", nil: return v; case "[degF]", "degF": return (v-32)*5/9; default: return nil } }

    private static let table: [String: MappingEntry] = {
        let e: [MappingEntry] = [
            MappingEntry(loinc: "29463-7", quantityType: "HKQuantityTypeIdentifierBodyMass", canonicalUnit: "kg", convert: mass),
            MappingEntry(loinc: "8302-2",  quantityType: "HKQuantityTypeIdentifierHeight", canonicalUnit: "cm", convert: length),
            MappingEntry(loinc: "8310-5",  quantityType: "HKQuantityTypeIdentifierBodyTemperature", canonicalUnit: "degC", convert: temperature),
            MappingEntry(loinc: "39156-5", quantityType: "HKQuantityTypeIdentifierBodyMassIndex", canonicalUnit: "kg/m2", convert: passthrough(["kg/m2"])),
            MappingEntry(loinc: "8867-4",  quantityType: "HKQuantityTypeIdentifierHeartRate", canonicalUnit: "count/min", convert: passthrough(["/min","count/min","{beats}/min"])),
            MappingEntry(loinc: "9279-1",  quantityType: "HKQuantityTypeIdentifierRespiratoryRate", canonicalUnit: "count/min", convert: passthrough(["/min","count/min","{breaths}/min"])),
            MappingEntry(loinc: "2708-6",  quantityType: "HKQuantityTypeIdentifierOxygenSaturation", canonicalUnit: "%", convert: passthrough(["%"])),
            MappingEntry(loinc: "8480-6",  quantityType: "HKQuantityTypeIdentifierBloodPressureSystolic", canonicalUnit: "mmHg", convert: passthrough(["mm[Hg]","mmHg"])),
            MappingEntry(loinc: "8462-4",  quantityType: "HKQuantityTypeIdentifierBloodPressureDiastolic", canonicalUnit: "mmHg", convert: passthrough(["mm[Hg]","mmHg"])),
            MappingEntry(loinc: "2339-0",  quantityType: "HKQuantityTypeIdentifierBloodGlucose", canonicalUnit: "mg/dL", convert: { v, u in
                switch u { case "mg/dL","mg/dl",nil: return v; case "mmol/L","mmol/l": return v*18.0182; default: return nil } }),
        ]
        return Dictionary(uniqueKeysWithValues: e.map { ($0.loinc, $0) })
    }()
}
```

- [ ] **Step 4: Run to verify pass** — Run: `swift test --filter MappingTableTests`. Expected: PASS.

- [ ] **Step 5: Commit**
```
git add Sources/BridgeKit/MappingTable.swift Tests/BridgeKitTests/MappingTableTests.swift
github-agent-commit "feat(bridgekit): LOINC to HealthKit mapping with unit conversion"
```

---

## Task 6: Bridge Document validation

**Files:**
- Create: `Sources/BridgeKit/Validation.swift`
- Test: `Tests/BridgeKitTests/ValidationTests.swift`

**Interfaces:**
- `struct ValidationIssue { enum Severity { case error, warning }; let severity; let message }`, `func validate(_ document: BridgeDocument) -> [ValidationIssue]`. Rules: wrong `schemaVersion` → error; empty `source.sha256` → error; empty `subject.id` → error; duplicate observation ids → error (a **backstop** — Task 9's builder dedupes first); `confidence` outside `0...1` → error; `mapping != nil` on a `.string` value → error; zero observations → warning.

- [ ] **Step 1: Write failing test** — `Tests/BridgeKitTests/ValidationTests.swift`:
```swift
import XCTest
@testable import BridgeKit

final class ValidationTests: XCTestCase {
    private func doc(_ obs: [Observation], schemaVersion: Int = 1, sha: String = "abc",
                     subjectId: String = "uuid-1") -> BridgeDocument {
        BridgeDocument(schemaVersion: schemaVersion,
            source: Source(kind: .fhir, fileName: "f.json", sha256: sha,
                           extractedAt: Date(timeIntervalSince1970: 0), extractor: Extractor(engine: "x", version: "1")),
            subject: SubjectRef(id: subjectId, label: "L", hash: "h"), observations: obs)
    }
    private func obs(_ id: String, value: ObservationValue = .quantity(1),
                     mapping: HealthKitMapping? = nil, confidence: Double = 1.0) -> Observation {
        Observation(id: id, code: nil, name: "x", value: value, unit: "kg",
                    effectiveDate: Date(timeIntervalSince1970: 0), category: .vital,
                    mapping: mapping, confidence: confidence, sourceLocator: nil)
    }
    func testValid() { XCTAssertFalse(validate(doc([obs("a")])).contains { $0.severity == .error }) }
    func testWrongSchema() { XCTAssertTrue(validate(doc([obs("a")], schemaVersion: 99)).contains { $0.severity == .error }) }
    func testEmptySubjectId() { XCTAssertTrue(validate(doc([obs("a")], subjectId: "")).contains { $0.severity == .error }) }
    func testDuplicateIDs() { XCTAssertTrue(validate(doc([obs("a"), obs("a")])).contains { $0.severity == .error && $0.message.contains("duplicate") }) }
    func testMappingOnString() {
        let bad = obs("a", value: .string("p"), mapping: HealthKitMapping(quantityType: "X", canonicalUnit: "kg", convertedValue: 1))
        XCTAssertTrue(validate(doc([bad])).contains { $0.severity == .error })
    }
    func testEmptyObservationsWarns() {
        let issues = validate(doc([]))
        XCTAssertTrue(issues.contains { $0.severity == .warning })
        XCTAssertFalse(issues.contains { $0.severity == .error })
    }
}
```

- [ ] **Step 2: Run to verify it fails** — Run: `swift test --filter ValidationTests`. Expected: FAIL.

- [ ] **Step 3: Implement** — `Sources/BridgeKit/Validation.swift`:
```swift
import Foundation

public struct ValidationIssue: Equatable, Sendable {
    public enum Severity: Sendable { case error, warning }
    public let severity: Severity
    public let message: String
    public init(severity: Severity, message: String) { self.severity = severity; self.message = message }
}

public func validate(_ document: BridgeDocument) -> [ValidationIssue] {
    var issues: [ValidationIssue] = []
    if document.schemaVersion != BridgeDocument.currentSchemaVersion {
        issues.append(.init(severity: .error, message: "schemaVersion \(document.schemaVersion) != \(BridgeDocument.currentSchemaVersion)"))
    }
    if document.source.sha256.isEmpty { issues.append(.init(severity: .error, message: "source.sha256 is empty")) }
    if document.subject.id.isEmpty { issues.append(.init(severity: .error, message: "subject.id is empty")) }
    if document.observations.isEmpty { issues.append(.init(severity: .warning, message: "document has zero observations")) }
    var seen = Set<String>()
    for o in document.observations {
        if !seen.insert(o.id).inserted { issues.append(.init(severity: .error, message: "duplicate observation id: \(o.id)")) }
        if !(0.0...1.0).contains(o.confidence) { issues.append(.init(severity: .error, message: "confidence out of range for \(o.id)")) }
        if o.mapping != nil, case .string = o.value {
            issues.append(.init(severity: .error, message: "string-valued observation \(o.id) cannot carry a HealthKit mapping"))
        }
    }
    return issues
}
```

- [ ] **Step 4: Run to verify pass** — Run: `swift test --filter ValidationTests`. Expected: PASS. Then `swift test --filter BridgeKitTests` — entire BridgeKit suite green.

- [ ] **Step 5: Commit**
```
git add Sources/BridgeKit/Validation.swift Tests/BridgeKitTests/ValidationTests.swift
github-agent-commit "feat(bridgekit): Bridge Document validation rules"
```

---

## Task 7: DocumentParser protocol + ParseResult

**Files:**
- Modify: `Package.swift` (add `HealthBridgeParsingTests` target — no resources yet)
- Create: `Sources/HealthBridgeParsing/DocumentParser.swift`
- Delete: `Sources/HealthBridgeParsing/Placeholder.swift`
- Test: `Tests/HealthBridgeParsingTests/DocumentParserTests.swift`

**Interfaces:**
- `protocol DocumentParser { static func canParse(_ data: Data) -> Bool; func parse(_ data: Data, documentKey: String) throws -> ParseResult }`.
- `struct ParseResult { let observations: [Observation]; let skipped: [Skip] }`.
- `struct Skip { enum Reason { case noCode, noDate, unrepresentableValue }; let reason; let label: String }` — lets the CLI log what was dropped (the Task 8 drop-and-log requirement).
- `enum ParseError: Error, Equatable { case unrecognizedFormat; case malformed(String) }`.

- [ ] **Step 1: Declare the test target** — add to `Package.swift` `targets:`:
```swift
        .testTarget(name: "HealthBridgeParsingTests", dependencies: ["HealthBridgeParsing", "BridgeKit"]),
```

- [ ] **Step 2: Write failing test** — `Tests/HealthBridgeParsingTests/DocumentParserTests.swift`:
```swift
import XCTest
import BridgeKit
@testable import HealthBridgeParsing

private struct StubParser: DocumentParser {
    static func canParse(_ data: Data) -> Bool { !data.isEmpty }
    func parse(_ data: Data, documentKey: String) throws -> ParseResult {
        guard !data.isEmpty else { throw ParseError.malformed("empty") }
        return ParseResult(observations: [], skipped: [Skip(reason: .noCode, label: "x")])
    }
}

final class DocumentParserTests: XCTestCase {
    func testCanParse() { XCTAssertTrue(StubParser.canParse(Data([0x7b]))); XCTAssertFalse(StubParser.canParse(Data())) }
    func testParseThrowsOnEmpty() {
        XCTAssertThrowsError(try StubParser().parse(Data(), documentKey: "k")) { XCTAssertEqual($0 as? ParseError, .malformed("empty")) }
    }
    func testParseResultCarriesSkips() throws {
        let r = try StubParser().parse(Data([0x7b]), documentKey: "k")
        XCTAssertEqual(r.skipped.first?.reason, .noCode)
    }
}
```

- [ ] **Step 3: Run to verify it fails** — Run: `swift test --filter DocumentParserTests`. Expected: FAIL.

- [ ] **Step 4: Implement** — `Sources/HealthBridgeParsing/DocumentParser.swift`:
```swift
import Foundation
import BridgeKit

public enum ParseError: Error, Equatable { case unrecognizedFormat; case malformed(String) }

public struct Skip: Equatable, Sendable {
    public enum Reason: Equatable, Sendable { case noCode, noDate, unrepresentableValue }
    public let reason: Reason
    public let label: String
    public init(reason: Reason, label: String) { self.reason = reason; self.label = label }
}

public struct ParseResult: Sendable {
    public let observations: [Observation]
    public let skipped: [Skip]
    public init(observations: [Observation], skipped: [Skip]) { self.observations = observations; self.skipped = skipped }
}

public protocol DocumentParser {
    static func canParse(_ data: Data) -> Bool
    func parse(_ data: Data, documentKey: String) throws -> ParseResult
}
```
Delete `Sources/HealthBridgeParsing/Placeholder.swift`.

- [ ] **Step 5: Run to verify pass** — Run: `swift test --filter DocumentParserTests`. Expected: PASS.

- [ ] **Step 6: Commit**
```
git add Package.swift Sources/HealthBridgeParsing/DocumentParser.swift Tests/HealthBridgeParsingTests/DocumentParserTests.swift
git rm Sources/HealthBridgeParsing/Placeholder.swift
github-agent-commit "feat(parsing): DocumentParser protocol with ParseResult and skips"
```

---

## Task 8: FHIR R4 parser (drop-and-log code-less)

**Files:**
- Modify: `Package.swift` (add `resources: [.copy("Fixtures")]` to `HealthBridgeParsingTests`)
- Create: `Sources/HealthBridgeParsing/FHIRParser.swift`
- Create: `Tests/HealthBridgeParsingTests/Fixtures/observation-bodyweight.json`, `Tests/HealthBridgeParsingTests/Fixtures/bundle-vitals-and-labs.json`, `Tests/HealthBridgeParsingTests/Fixtures/observation-nocode.json`
- Test: `Tests/HealthBridgeParsingTests/FHIRParserTests.swift`

**Interfaces:**
- `struct FHIRParser: DocumentParser` — FHIR R4 JSON (single `Observation` or `Bundle`) → `ParseResult`. Each observation has `confidence = 1.0`, `mapping = nil` (the CLI resolves mapping). **Drops** observations with no coding (`.noCode`) or no effective date (`.noDate`), recording each in `skipped` with a human label.

> Verified against FHIRModels 0.9.3: `Observation.code` is non-optional `CodeableConcept`; `value`/`effective` are optional enums `Observation.ValueX?`/`EffectiveX?` (unwrap with `guard let`, switch the non-optional — `EffectiveX` has a `.timing` case, covered by `default`); `Decimal` has no `.doubleValue` (wrap in `NSDecimalNumber`); `asNSDate()` throws and is called on the unwrapped `DateTime`/`Instant` (`.value`); LOINC system URI `http://loinc.org`.

- [ ] **Step 1: Wire fixtures into the manifest, then create them** — update `HealthBridgeParsingTests` in `Package.swift`:
```swift
        .testTarget(
            name: "HealthBridgeParsingTests",
            dependencies: ["HealthBridgeParsing", "BridgeKit"],
            resources: [.copy("Fixtures")]
        ),
```
`Tests/HealthBridgeParsingTests/Fixtures/observation-bodyweight.json`:
```json
{
  "resourceType": "Observation", "id": "bw1", "status": "final",
  "category": [ { "coding": [ { "system": "http://terminology.hl7.org/CodeSystem/observation-category", "code": "vital-signs" } ] } ],
  "code": { "coding": [ { "system": "http://loinc.org", "code": "29463-7", "display": "Body weight" } ], "text": "Body weight" },
  "effectiveDateTime": "2025-03-19T09:30:00-04:00",
  "valueQuantity": { "value": 72.5, "unit": "kg", "system": "http://unitsofmeasure.org", "code": "kg" }
}
```
`Tests/HealthBridgeParsingTests/Fixtures/bundle-vitals-and-labs.json`:
```json
{
  "resourceType": "Bundle", "type": "collection",
  "entry": [
    { "resource": {
        "resourceType": "Observation", "id": "bw1", "status": "final",
        "category": [ { "coding": [ { "system": "http://terminology.hl7.org/CodeSystem/observation-category", "code": "vital-signs" } ] } ],
        "code": { "coding": [ { "system": "http://loinc.org", "code": "29463-7", "display": "Body weight" } ] },
        "effectiveDateTime": "2025-03-19T09:30:00-04:00",
        "valueQuantity": { "value": 72.5, "unit": "kg", "system": "http://unitsofmeasure.org", "code": "kg" } } },
    { "resource": {
        "resourceType": "Observation", "id": "alt1", "status": "final",
        "category": [ { "coding": [ { "system": "http://terminology.hl7.org/CodeSystem/observation-category", "code": "laboratory" } ] } ],
        "code": { "coding": [ { "system": "http://loinc.org", "code": "1742-6", "display": "ALT" } ] },
        "effectiveDateTime": "2025-03-19T09:30:00-04:00",
        "valueQuantity": { "value": 22, "unit": "U/L", "system": "http://unitsofmeasure.org", "code": "U/L" } } }
  ]
}
```
`Tests/HealthBridgeParsingTests/Fixtures/observation-nocode.json` (no `coding`, only `text` → dropped with `.noCode`):
```json
{
  "resourceType": "Observation", "id": "nc1", "status": "final",
  "code": { "text": "Free text only" },
  "effectiveDateTime": "2025-03-19T09:30:00-04:00",
  "valueQuantity": { "value": 1, "unit": "kg", "system": "http://unitsofmeasure.org", "code": "kg" }
}
```

- [ ] **Step 2: Write the failing test** — `Tests/HealthBridgeParsingTests/FHIRParserTests.swift`:
```swift
import XCTest
import BridgeKit
@testable import HealthBridgeParsing

final class FHIRParserTests: XCTestCase {
    private func fixture(_ n: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(n)", withExtension: "json")))
    }
    func testCanParseDetectsFHIR() throws {
        XCTAssertTrue(FHIRParser.canParse(try fixture("observation-bodyweight")))
        XCTAssertFalse(FHIRParser.canParse(Data("<ClinicalDocument/>".utf8)))
    }
    func testParsesSingleObservation() throws {
        let r = try FHIRParser().parse(try fixture("observation-bodyweight"), documentKey: "doc1")
        let o = try XCTUnwrap(r.observations.first)
        XCTAssertEqual(r.observations.count, 1)
        XCTAssertEqual(o.code?.code, "29463-7"); XCTAssertEqual(o.code?.system, "http://loinc.org")
        XCTAssertEqual(o.name, "Body weight"); XCTAssertEqual(o.value, .quantity(72.5)); XCTAssertEqual(o.unit, "kg")
        XCTAssertEqual(o.category, .vital); XCTAssertEqual(o.confidence, 1.0); XCTAssertNil(o.mapping)
        XCTAssertEqual(o.effectiveDate.timeIntervalSince1970, 1_742_391_000, accuracy: 1)
    }
    func testParsesBundle() throws {
        let r = try FHIRParser().parse(try fixture("bundle-vitals-and-labs"), documentKey: "doc1")
        XCTAssertEqual(r.observations.count, 2)
        XCTAssertEqual(r.observations.first?.category, .vital)
        XCTAssertEqual(r.observations.last?.category, .lab)
    }
    func testDropsAndRecordsCodeless() throws {
        let r = try FHIRParser().parse(try fixture("observation-nocode"), documentKey: "doc1")
        XCTAssertEqual(r.observations.count, 0)
        XCTAssertEqual(r.skipped.first?.reason, .noCode)
        XCTAssertEqual(r.skipped.first?.label, "Free text only")
    }
    func testMalformedThrows() { XCTAssertThrowsError(try FHIRParser().parse(Data("{ not".utf8), documentKey: "k")) }
}
```

- [ ] **Step 3: Run to verify it fails** — Run: `swift test --filter FHIRParserTests`. Expected: FAIL.

- [ ] **Step 4: Implement** — `Sources/HealthBridgeParsing/FHIRParser.swift`:
```swift
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

    public func parse(_ data: Data, documentKey: String) throws -> ParseResult {
        let fhir = try decodeObservations(data)
        var observations: [Observation] = []
        var skipped: [Skip] = []
        for o in fhir {
            switch convert(o, documentKey: documentKey) {
            case .success(let obs): observations.append(obs)
            case .failure(let skip): skipped.append(skip)
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

    private enum ConvertResult { case success(Observation); case failure(Skip) }

    private func convert(_ o: ModelsR4.Observation, documentKey: String) -> ConvertResult {
        let label = o.code.text?.value?.string
            ?? o.code.coding?.first?.display?.value?.string ?? "Unknown"
        guard let coding = loincCoding(o.code) else { return .failure(Skip(reason: .noCode, label: label)) }
        guard let effective = effectiveDate(o.effective) else { return .failure(Skip(reason: .noDate, label: label)) }
        guard let (value, unit, raw) = observationValue(o.value) else {
            return .failure(Skip(reason: .unrepresentableValue, label: label))
        }
        let code = coding.code?.value?.string
        let system = coding.system?.value?.url.absoluteString
        let display = coding.display?.value?.string ?? o.code.text?.value?.string ?? code ?? "Unknown"
        let id = ObservationID.derive(documentKey: documentKey, system: system, code: code,
                                      effectiveDate: effective, rawValue: raw, unit: unit)
        let ref = (system != nil && code != nil) ? CodeableRef(system: system!, code: code!, display: display) : nil
        return .success(Observation(id: id, code: ref, name: display, value: value, unit: unit,
                                    effectiveDate: effective, category: category(o.category),
                                    mapping: nil, confidence: 1.0, sourceLocator: nil))
    }

    private func loincCoding(_ code: CodeableConcept) -> Coding? {
        let codings = code.coding ?? []
        return codings.first { $0.system?.value?.url.absoluteString == "http://loinc.org" } ?? codings.first
    }

    private func observationValue(_ value: Observation.ValueX?) -> (ObservationValue, String?, String)? {
        guard let value else { return nil }
        switch value {
        case .quantity(let q):
            guard let decimal = q.value?.value?.decimal else { return nil }
            let d = NSDecimalNumber(decimal: decimal).doubleValue
            let unit = q.code?.value?.string ?? q.unit?.value?.string
            return (.quantity(d), unit, stableNumberString(d))
        case .string(let s):
            guard let str = s.value?.string else { return nil }
            return (.string(str), nil, str)
        default: return nil
        }
    }

    private func effectiveDate(_ effective: Observation.EffectiveX?) -> Date? {
        guard let effective else { return nil }
        switch effective {
        case .dateTime(let dt): return try? dt.value?.asNSDate()
        case .instant(let inst): return try? inst.value?.asNSDate()
        case .period(let p): if let start = p.start?.value { return try? start.asNSDate() }; return nil
        default: return nil
        }
    }

    private func category(_ categories: [CodeableConcept]?) -> ObservationCategory {
        let codes = (categories ?? []).flatMap { $0.coding ?? [] }.compactMap { $0.code?.value?.string }
        if codes.contains("vital-signs") { return .vital }
        if codes.contains("laboratory") { return .lab }
        return .other
    }

    private func stableNumberString(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%g", d)
    }
}
```

- [ ] **Step 5: Run to verify pass** — Run: `swift test --filter FHIRParserTests`. Expected: all PASS.

- [ ] **Step 6: Commit**
```
git add Package.swift Sources/HealthBridgeParsing/FHIRParser.swift Tests/HealthBridgeParsingTests
github-agent-commit "feat(parsing): FHIR R4 parser, drops and records code-less/date-less"
```

---

## Task 9: healthbridge CLI (parse + subject subcommands)

**Files:**
- Modify: `Package.swift` (add `healthbridgeTests` target with `resources: [.copy("Fixtures")]`)
- Create: `Sources/healthbridge/HealthBridge.swift`
- Delete: `Sources/healthbridge/main.swift`
- Create: `Tests/healthbridgeTests/Fixtures/bundle-vitals-and-labs.json`, `Tests/healthbridgeTests/Fixtures/patient-bundle.json`, `Tests/healthbridgeTests/Fixtures/bundle-duplicate.json`
- Test: `Tests/healthbridgeTests/BridgeBuilderTests.swift`

**Interfaces:**
- `BridgeBuilder.build(data:fileName:subject:) throws -> BridgeDocument` — sha256 → `FHIRParser` → resolve mapping → **dedupe by id** (keep first) → assemble with the passed `SubjectRef`. (Subject cross-check happens in the command layer, which has the FHIR `Patient`.)
- `enum PatientMatch { static func crossCheck(data: Data, subject: SubjectEntry) -> Bool }` — extract the bundle's `Patient` name/dob, compare `SubjectHash` to the subject's; `true` if no Patient present (nothing to contradict), `false` on mismatch.
- CLI: `healthbridge parse <input> [--config <p>] [--subject <key>] [--data-root <p>] [--verbose|--quiet]` and `healthbridge subject add --label --name --dob [--config <p>]` / `healthbridge subject list [--config <p>]`.
- Output path: `<dataRoot>/subjects/<subjectId>/<sourceSha>.bridge.json`.

- [ ] **Step 1: Declare the CLI test target + fixtures** — add to `Package.swift`:
```swift
        .testTarget(
            name: "healthbridgeTests",
            dependencies: ["healthbridge", "BridgeKit", "HealthBridgeConfig"],
            resources: [.copy("Fixtures")]
        ),
```
Then create the fixtures:
```
mkdir -p Tests/healthbridgeTests/Fixtures
cp Tests/HealthBridgeParsingTests/Fixtures/bundle-vitals-and-labs.json Tests/healthbridgeTests/Fixtures/bundle-vitals-and-labs.json
```
`Tests/healthbridgeTests/Fixtures/bundle-duplicate.json` — same observation twice (different FHIR resource ids `bw1`/`bw1-dup`, identical clinical content → one Bridge observation):
```json
{ "resourceType": "Bundle", "type": "collection", "entry": [
  { "resource": { "resourceType": "Observation", "id": "bw1", "status": "final",
    "category": [ { "coding": [ { "system": "http://terminology.hl7.org/CodeSystem/observation-category", "code": "vital-signs" } ] } ],
    "code": { "coding": [ { "system": "http://loinc.org", "code": "29463-7", "display": "Body weight" } ] },
    "effectiveDateTime": "2025-03-19T09:30:00-04:00",
    "valueQuantity": { "value": 72.5, "unit": "kg", "system": "http://unitsofmeasure.org", "code": "kg" } } },
  { "resource": { "resourceType": "Observation", "id": "bw1-dup", "status": "final",
    "category": [ { "coding": [ { "system": "http://terminology.hl7.org/CodeSystem/observation-category", "code": "vital-signs" } ] } ],
    "code": { "coding": [ { "system": "http://loinc.org", "code": "29463-7", "display": "Body weight" } ] },
    "effectiveDateTime": "2025-03-19T09:30:00-04:00",
    "valueQuantity": { "value": 72.5, "unit": "kg", "system": "http://unitsofmeasure.org", "code": "kg" } } }
]}
```
`Tests/healthbridgeTests/Fixtures/patient-bundle.json` — a bundle with a `Patient` resource for the cross-check (name "Caleb Feather", dob "2015-04-12") plus the body-weight observation:
```json
{ "resourceType": "Bundle", "type": "collection", "entry": [
  { "resource": { "resourceType": "Patient", "id": "p1",
    "name": [ { "family": "Feather", "given": ["Caleb"] } ], "birthDate": "2015-04-12" } },
  { "resource": { "resourceType": "Observation", "id": "bw1", "status": "final",
    "category": [ { "coding": [ { "system": "http://terminology.hl7.org/CodeSystem/observation-category", "code": "vital-signs" } ] } ],
    "code": { "coding": [ { "system": "http://loinc.org", "code": "29463-7", "display": "Body weight" } ] },
    "effectiveDateTime": "2025-03-19T09:30:00-04:00",
    "valueQuantity": { "value": 72.5, "unit": "kg", "system": "http://unitsofmeasure.org", "code": "kg" } } }
]}
```

- [ ] **Step 2: Write the failing test** — `Tests/healthbridgeTests/BridgeBuilderTests.swift`:
```swift
import XCTest
import BridgeKit
import HealthBridgeConfig
@testable import healthbridge

final class BridgeBuilderTests: XCTestCase {
    private func fixture(_ n: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(n)", withExtension: "json")))
    }
    private let subject = SubjectRef(id: "uuid-c", label: "Caleb", hash: "h", name: "Caleb Feather", dob: "2015-04-12")

    func testBuildsValidSubjectBoundDocument() throws {
        let doc = try BridgeBuilder.build(data: try fixture("bundle-vitals-and-labs"),
                                          fileName: "f.json", subject: subject)
        XCTAssertEqual(doc.subject.id, "uuid-c")
        XCTAssertEqual(doc.observations.count, 2)
        let weight = try XCTUnwrap(doc.observations.first { $0.code?.code == "29463-7" })
        XCTAssertEqual(weight.mapping?.quantityType, "HKQuantityTypeIdentifierBodyMass")
        XCTAssertNil(try XCTUnwrap(doc.observations.first { $0.code?.code == "1742-6" }).mapping)
        XCTAssertFalse(validate(doc).contains { $0.severity == .error })
    }
    func testDedupes() throws {
        let doc = try BridgeBuilder.build(data: try fixture("bundle-duplicate"), fileName: "d.json", subject: subject)
        XCTAssertEqual(doc.observations.count, 1)
    }
    func testDeterministic() throws {
        let d = try fixture("bundle-vitals-and-labs")
        let a = try BridgeJSON.encoder.encode(BridgeBuilder.build(data: d, fileName: "f.json", subject: subject))
        let b = try BridgeJSON.encoder.encode(BridgeBuilder.build(data: d, fileName: "f.json", subject: subject))
        XCTAssertEqual(a, b)
    }
    func testCrossCheckMatchesPatient() throws {
        let entry = SubjectEntry(key: "caleb", subjectId: "uuid-c", label: "Caleb",
                                 name: "Caleb Feather", dob: "2015-04-12")
        XCTAssertTrue(PatientMatch.crossCheck(data: try fixture("patient-bundle"), subject: entry))
    }
    func testCrossCheckRejectsWrongPatient() throws {
        let entry = SubjectEntry(key: "steve", subjectId: "uuid-s", label: "Steve",
                                 name: "Stephen Feather", dob: "1975-01-01")
        XCTAssertFalse(PatientMatch.crossCheck(data: try fixture("patient-bundle"), subject: entry))
    }
}
```

- [ ] **Step 3: Run to verify it fails** — Run: `swift test --filter BridgeBuilderTests`. Expected: FAIL.

- [ ] **Step 4: Implement** — `Sources/healthbridge/HealthBridge.swift`:
```swift
import Foundation
import CryptoKit
import ArgumentParser
import BridgeKit
import HealthBridgeConfig
import HealthBridgeParsing
import ModelsR4

public enum BridgeBuilder {
    public static func build(data: Data, fileName: String, subject: SubjectRef) throws -> BridgeDocument {
        let sha = sha256Hex(data)
        guard FHIRParser.canParse(data) else { throw ParseError.unrecognizedFormat }
        let result = try FHIRParser().parse(data, documentKey: sha)
        let resolved = result.observations.map { o -> Observation in
            var o = o
            o.mapping = MappingTable.resolve(loinc: o.code?.code, value: o.value, unit: o.unit)
            return o
        }
        var seen = Set<String>()
        let deduped = resolved.filter { seen.insert($0.id).inserted }
        return BridgeDocument(
            schemaVersion: BridgeDocument.currentSchemaVersion,
            source: Source(kind: .fhir, fileName: fileName, sha256: sha, extractedAt: Date(),
                           extractor: Extractor(engine: "fhir-parser", version: "0.1.0")),
            subject: subject, observations: deduped)
    }
    static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

public enum PatientMatch {
    /// True if the bundle has no Patient (nothing to contradict) or its Patient hash matches the subject.
    public static func crossCheck(data: Data, subject: SubjectEntry) -> Bool {
        guard let bundle = try? JSONDecoder().decode(ModelsR4.Bundle.self, from: data),
              let patient = bundle.entry?.compactMap({ $0.resource?.get(if: ModelsR4.Patient.self) }).first
        else { return true }
        guard let hn = patient.name?.first else { return true }
        let given = (hn.given ?? []).compactMap { $0.value?.string }.joined(separator: " ")
        let family = hn.family?.value?.string ?? ""
        let name = "\(given) \(family)".trimmingCharacters(in: .whitespaces)
        let dob = patient.birthDate?.value?.description ?? ""
        return SubjectHash.make(name: name, dob: dob) == SubjectHash.make(name: subject.name, dob: subject.dob)
    }
}

@main
struct HealthBridge: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "healthbridge",
        abstract: "Parse medical-record documents into subject-bound Bridge Documents.",
        subcommands: [Parse.self, Subject.self])
}

struct Parse: ParsableCommand {
    @Argument(help: "Input FHIR JSON file.") var input: String
    @Option(name: .long) var config: String = ConfigLoader.defaultPath
    @Option(name: .long) var subject: String?
    @Option(name: .long) var dataRoot: String?
    @Flag(name: .long) var verbose = false
    @Flag(name: .long) var quiet = false

    func run() throws {
        let cfg = try ConfigLoader.load(path: config)
        let overrides = Overrides(dataRoot: dataRoot, subject: subject,
                                  logLevel: verbose ? .verbose : (quiet ? .quiet : nil))
        let settings = SettingsResolver.resolve(config: cfg, overrides: overrides)
        guard let entry = settings.selectedSubject else { throw Fail("no subject selected (set --subject or default_subject)") }

        let inputURL = URL(fileURLWithPath: input)
        let data = try Data(contentsOf: inputURL)
        guard PatientMatch.crossCheck(data: data, subject: entry) else {
            throw Fail("document's Patient does not match subject '\(entry.key)' — refusing")
        }

        let subjectRef = SubjectRef(id: entry.subjectId, label: entry.label,
                                    hash: SubjectHash.make(name: entry.name, dob: entry.dob),
                                    name: entry.name, dob: entry.dob)
        let result = try FHIRParser().parse(data, documentKey: BridgeBuilder.sha256Hex(data))
        let doc = try BridgeBuilder.build(data: data, fileName: inputURL.lastPathComponent, subject: subjectRef)

        let issues = validate(doc)
        for i in issues { FileHandle.standardError.write(Data("[\(i.severity)] \(i.message)\n".utf8)) }
        if issues.contains(where: { $0.severity == .error }) { throw Fail("validation failed") }

        let dir = settings.dataRoot.appendingPathComponent("subjects/\(entry.subjectId)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("\(doc.source.sha256).bridge.json")
        try BridgeJSON.encoder.encode(doc).write(to: out)

        if settings.logLevel != .quiet {
            let mapped = doc.observations.filter { $0.mapping != nil }.count
            FileHandle.standardError.write(Data(
                "Wrote \(out.path): \(doc.observations.count) observations, \(mapped) mapped, \(doc.observations.count - mapped) unmapped, \(result.skipped.count) skipped.\n".utf8))
            for s in result.skipped {
                FileHandle.standardError.write(Data("  skipped (\(s.reason)): \(s.label)\n".utf8))
            }
        }
    }
}

struct Subject: ParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [Add.self, List.self])

    struct Add: ParsableCommand {
        @Option(name: .long) var label: String
        @Option(name: .long) var name: String
        @Option(name: .long) var dob: String
        @Option(name: .long) var config: String = ConfigLoader.defaultPath
        func run() throws {
            var cfg = (try ConfigLoader.load(path: config)) ?? Config()
            let key = label.lowercased().replacingOccurrences(of: " ", with: "-")
            let entry = SubjectEntry(key: key, subjectId: UUID().uuidString, label: label, name: name, dob: dob)
            cfg.subjects.append(entry)
            try ConfigWriter.write(cfg, path: config)
            print("Added subject '\(key)' with subjectId \(entry.subjectId)")
        }
    }
    struct List: ParsableCommand {
        @Option(name: .long) var config: String = ConfigLoader.defaultPath
        func run() throws {
            let cfg = (try ConfigLoader.load(path: config)) ?? Config()
            for s in cfg.subjects { print("\(s.key)\t\(s.label)\t\(s.subjectId)") }
        }
    }
}

struct Fail: Error, CustomStringConvertible { let m: String; init(_ m: String) { self.m = m }; var description: String { m } }
```
> `ConfigWriter.write(_:path:)` lives in `HealthBridgeConfig` (add it next to `ConfigLoader`): encodes `Config` to TOML via `TOMLEncoder`, creates parent dirs, writes atomically. Add a matching round-trip test in `HealthBridgeConfigTests` (write → load → equal).

Delete `Sources/healthbridge/main.swift`.

- [ ] **Step 5: Run to verify pass** — Run: `swift test --filter BridgeBuilderTests`. Expected: PASS. Fix any TOMLKit encoder spelling per Task 2's note if it surfaces.

- [ ] **Step 6: Manual end-to-end** — Run:
```
swift run healthbridge subject add --label "Caleb" --name "Caleb Feather" --dob 2015-04-12 --config /tmp/hb.toml
swift run healthbridge parse Tests/healthbridgeTests/Fixtures/patient-bundle.json --subject caleb --config /tmp/hb.toml --data-root /tmp/hbdata
```
Expected: subject added (prints a UUID); parse writes `/tmp/hbdata/subjects/<uuid>/<sha>.bridge.json` and prints the summary. Clean up `/tmp/hb.toml` and `/tmp/hbdata` after.

- [ ] **Step 7: Full suite** — Run: `swift test`. Expected: every test across all targets PASSES.

- [ ] **Step 8: Commit**
```
git add Package.swift Sources/healthbridge Sources/HealthBridgeConfig Tests/healthbridgeTests Tests/HealthBridgeConfigTests
git rm Sources/healthbridge/main.swift
github-agent-commit "feat(cli): parse + subject subcommands, config-driven, subject-bound output"
```

---

## Self-Review (plan author)

**Spec coverage:** config + layered precedence (Task 2) · subject identity/hash (Tasks 3–4) · mapping (5) · validation incl. subject.id (6) · parser protocol with skips (7) · FHIR parse + drop-and-log (8) · CLI with `--subject` cross-check, per-subject storage, flag parity, subject subcommand (9). Cross-file dedup, iOS device-binding gate, C-CDA, PDF/LLM remain out of scope (later milestones).

**Placeholder scan:** no TBD/"add error handling"/"similar to"; every code step has complete code. Two flagged-but-real follow-ups: `ConfigWriter` (Task 9 note) and the TOMLKit encoder/decoder spellings (verify on resolve) — both are concrete, not hand-waves.

**Type consistency:** `DocumentParser.parse → ParseResult` identical across Tasks 7–9. `SubjectRef` (BridgeKit, in docs) vs `SubjectEntry` (config/roster) are distinct by design: the roster entry resolves into the document's `SubjectRef`. `SettingsResolver.resolve`, `ConfigLoader.load`, `SubjectHash.make`, `MappingTable.resolve`, `BridgeBuilder.build(data:fileName:subject:)`, `PatientMatch.crossCheck` referenced consistently.
