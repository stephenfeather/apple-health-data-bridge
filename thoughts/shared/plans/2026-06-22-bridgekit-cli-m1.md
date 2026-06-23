# BridgeKit + healthbridge CLI (Milestone 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an all-Swift package that parses a FHIR R4 JSON medical-record document into a validated, subject-bound `*.bridge.json` Bridge Document, driven by a layered TOML config, with each observation pre-resolved against a LOINC→HealthKit mapping table and written to per-subject storage.

**Architecture:** One Swift Package Manager package. `BridgeKit` (platform-pure library: schema, mapping, ID derivation, subject hash, validation). `HealthBridgeConfig` (library: TOML config model + layered settings + config read/write). `HealthBridgeParsing` (library: `DocumentParser` protocol + `FHIRParser`, depends on `BridgeKit` + `FHIRModels`). `healthbridge` (executable: `ArgumentParser` CLI with `parse` and `subject` subcommands). Data flows: config+flags → resolved `Settings`; FHIR JSON → `[Observation]` → resolve mapping → dedupe → subject-bound `BridgeDocument` → JSON file under the subject's storage dir.

**Tech Stack:** Swift 5.9+, SwiftPM, Apple `FHIRModels` (`ModelsR4`), `swift-argument-parser`, `TOMLKit`, `CryptoKit` (SHA-256, built-in).

## Global Constraints

- Swift tools version **5.9**. Platforms **`.macOS(.v13)`, `.iOS(.v16)`** (`BridgeKit` must compile for iOS; `CryptoKit` is on both).
- Verified dependency versions: **FHIRModels 0.9.3**, **swift-argument-parser 1.8.2**. `TOMLKit` is pinned at scaffold time (Task 1). **`Package.resolved` IS committed** (reproducible dependency pins) — it is *not* gitignored.
- `BridgeKit` imports only `Foundation` + `CryptoKit` — never `ModelsR4`, `ArgumentParser`, `TOMLKit`.
- Bridge Document JSON is **deterministic**: `JSONEncoder` with `outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`, `dateEncodingStrategy = .iso8601`; decoder `dateDecodingStrategy = .iso8601`. Dates normalize to **whole-second UTC** (no fractional seconds). FHIR dates lacking a timezone are resolved **in UTC**, never `TimeZone.current`, so the same input yields the same `Date`/id on any machine.
- `schemaVersion` current value: **1**. FHIR-derived observations carry `confidence = 1.0`.
- LOINC system URI: **`http://loinc.org`**.
- **Settings precedence (hard rule): CLI flag > TOML config > built-in default.** Every scalar config setting has a matching `--flag`. (The subject *roster* is a managed collection, not a scalar setting — managed via `healthbridge subject add/list`, selected per-run with `--subject <key>`.)
- **Subject binding:** every Bridge Document carries a required nested `subject` with `subject.id` (UUID), `subject.label`, and `subject.hash` (`sha256` of canonical `name|dob`). The CLI cross-checks the selected subject against the FHIR `Patient` and refuses on mismatch.
- **Observation id is content-based:** `ObservationID.derive` hashes `subject.id + code.system + code.code + effectiveDate + rawValue + unit` — **no `documentKey`**. The same clinical observation gets the same id across files (it becomes the iOS `HKMetadataKeySyncIdentifier`, which must be stable forever), so cross-file duplicates collapse via the sync id. Within-file dedupe (keep first) still runs in the builder.
- **No network in tests.** Fixtures are checked-in JSON/TOML. **No PHI** in the repo (synthetic/public data only); processed `*.bridge.json` are gitignored and never committed.
- **Commit protocol — NEVER run `git commit` or `git push`.** All implementation runs in a **git worktree on a feature branch** (never `main`; created in Task 0). Each "Commit" step: `git add <files>` (and `git rm` for deletions) to stage — the only raw git permitted, because `github-agent-commit` reads `git diff --cached` — then **`github-agent-commit "<message>"`** (signed; refuses `main`; auto-creates the remote branch; resets local to `origin/<branch>` after, so stage everything first). Do NOT run `git commit`/`push`/`fetch`/`reset`/`checkout`/`update-ref`; read-only `git status`/`git diff` is fine. All GitHub API / PRs use **`agent-gh`**, never raw `gh`. The milestone lands as **one PR** to `main` via `agent-gh pr create … --body-file <file>`.
- TDD throughout: failing test first, minimal implementation, green, commit.

---

## File Structure

```
Package.swift
Package.resolved            # committed
Sources/
  BridgeKit/
    BridgeDocument.swift     # BridgeDocument, Source, SourceKind, Extractor, SubjectRef
    Observation.swift        # Observation, ObservationValue, ObservationCategory, CodeableRef, SourceLocator
    HealthKitMapping.swift
    BridgeJSON.swift
    ObservationID.swift      # content-based id (subject.id + code + date + value + unit)
    SubjectHash.swift        # canonical sha256(name|dob)
    MappingTable.swift
    Validation.swift
  HealthBridgeConfig/
    Config.swift             # TOML model: Config, SubjectEntry, addSubject, ConfigError
    TOMLCodec.swift          # thin TOMLKit decode/encode adapter (isolates the dependency)
    Settings.swift           # Settings, LogLevel, Overrides, SettingsResolver, ConfigLoader, ConfigWriter
  HealthBridgeParsing/
    DocumentParser.swift     # DocumentParser protocol, ParseResult, Skip, ParseError
    FHIRDate.swift           # UTC-stable FHIR DateTime/Instant -> Date
    FHIRParser.swift
  healthbridge/
    HealthBridge.swift       # @main root + Parse + Subject subcommands, BridgeBuilder, PatientMatch
Tests/
  BridgeKitTests/...
  HealthBridgeConfigTests/...
  HealthBridgeParsingTests/{...,Fixtures/}
  healthbridgeTests/{...,Fixtures/}
```

---

## Task 0: Repository preflight (no commit)

**Purpose:** the rest of the plan commits via `github-agent-commit`, which refuses `main`. Establish the worktree and verify the environment BEFORE any code is written. This task produces no commit.

- [ ] **Step 1: Verify not on `main` / create the feature worktree**

Use the `superpowers:using-git-worktrees` skill, or call `EnterWorktree({name: "bridgekit-m1"})` (creates the branch+worktree under `.claude/worktrees/`, switches the session in, and grants file-tool write access in one step). Then confirm:
```
git branch --show-current   # must NOT be "main" or "master"
```
Expected: a feature branch (e.g. `bridgekit-m1`). If it prints `main`, STOP and create the worktree.

- [ ] **Step 2: Verify the GitHub App commit env**
```
for v in GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY; do
  printf '%s: %s\n' "$v" "$(printenv "$v" >/dev/null 2>&1 && echo SET || echo empty)"
done
```
Expected: all three `SET` (loaded via the repo `.envrc`/direnv). If any is `empty`, STOP and report — do not fall back to `git commit`.

- [ ] **Step 3: Verify `.gitignore` policy**

Confirm `.gitignore` **does NOT** ignore `Package.resolved` (it must be committed) and **does** ignore `*.bridge.json`:
```
git check-ignore -v Package.resolved   # expect: no match (exit 1)
git check-ignore -v x.bridge.json      # expect: a match
```

- [ ] **Step 4: PHI guardrail — no private data tracked**
```
git ls-files | rg -i 'bridge\.json$|samples/private/' && echo "PHI LEAK — STOP" || echo "clean"
```
Expected: `clean` (no matches). If anything prints, STOP — PHI/processed output must never be tracked.

- [ ] **Step 5: Toolchain check**
```
swift --version   # expect Swift 5.9+ toolchain
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
        // Verified resolved versions: FHIRModels 0.9.3, swift-argument-parser 1.8.2.
        .package(url: "https://github.com/apple/FHIRModels.git", .upToNextMinor(from: "0.9.3")),
        .package(url: "https://github.com/apple/swift-argument-parser.git", .upToNextMinor(from: "1.8.2")),
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

- [ ] **Step 4: Resolve & build** — Run: `swift package resolve && swift build`. Expected: resolves FHIRModels 0.9.3, swift-argument-parser 1.8.2, and TOMLKit; `Package.resolved` is written and **will be committed**; builds clean. First build compiles FHIRModels from source (slow once).

- [ ] **Step 5: Run smoke test** — Run: `swift test --filter BridgeKitTests.SmokeTests`. Expected: PASS.

- [ ] **Step 6: Commit**
```
git add Package.swift Package.resolved Sources Tests
github-agent-commit "chore: scaffold SwiftPM package (BridgeKit, Config, Parsing, CLI targets)"
```

---

## Task 2: Config, layered Settings, and ConfigWriter

**Files:**
- Modify: `Package.swift` (add `HealthBridgeConfigTests` target)
- Create: `Sources/HealthBridgeConfig/Config.swift`, `Sources/HealthBridgeConfig/TOMLCodec.swift`, `Sources/HealthBridgeConfig/Settings.swift`
- Delete: `Sources/HealthBridgeConfig/Placeholder.swift`
- Test: `Tests/HealthBridgeConfigTests/SettingsTests.swift`, `Tests/HealthBridgeConfigTests/ConfigWriterTests.swift`

**Interfaces:**
- `struct Config: Codable, Equatable` — `dataRoot: String?`, `defaultSubject: String?`, `logLevel: String?`, `subjects: [SubjectEntry]` (snake_case TOML keys). `mutating func addSubject(_:) throws` rejects duplicate keys with `ConfigError.duplicateKey`.
- `struct SubjectEntry: Codable, Equatable` — `key, subjectId, label, name, dob` (all `String`).
- `enum ConfigError: Error, Equatable { case duplicateKey(String) }`.
- `enum TOMLCodec { static func decode<T:Decodable>(_:from:) throws -> T; static func encode<T:Encodable>(_:) throws -> String }` — the ONLY place TOMLKit is touched.
- `enum LogLevel`, `struct Overrides`, `struct Settings`, `enum ConfigLoader { static func load(path:) throws -> Config?; static var defaultPath }`, `enum ConfigWriter { static func write(_:path:) throws }`, `enum SettingsResolver { static func resolve(config:overrides:) -> Settings }` (precedence override ?? config ?? default; default `dataRoot` = `~/Documents/apple-health-data-bridge`).

- [ ] **Step 1: Declare the test target** — add to `Package.swift` `targets:`:
```swift
        .testTarget(name: "HealthBridgeConfigTests", dependencies: ["HealthBridgeConfig"]),
```

- [ ] **Step 2: Write the failing tests** — `Tests/HealthBridgeConfigTests/SettingsTests.swift`:
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
        XCTAssertEqual(s.logLevel, .normal); XCTAssertNil(s.selectedSubject)
    }
    func testConfigOverridesDefault() {
        let s = SettingsResolver.resolve(config: config(), overrides: Overrides())
        XCTAssertTrue(s.dataRoot.path.hasSuffix("from-toml"))
        XCTAssertEqual(s.selectedSubject?.key, "caleb")
    }
    func testFlagOverridesConfig() {
        let s = SettingsResolver.resolve(config: config(),
                                         overrides: Overrides(dataRoot: "~/from-flag", subject: nil, logLevel: .verbose))
        XCTAssertTrue(s.dataRoot.path.hasSuffix("from-flag")); XCTAssertEqual(s.logLevel, .verbose)
    }
    func testTildeExpanded() {
        let s = SettingsResolver.resolve(config: nil, overrides: Overrides(dataRoot: "~/x"))
        XCTAssertFalse(s.dataRoot.path.contains("~"))
    }
    func testSubjectSelectionByFlag() {
        let s = SettingsResolver.resolve(config: config(), overrides: Overrides(subject: "caleb"))
        XCTAssertEqual(s.selectedSubject?.subjectId, "uuid-c")
    }
    func testAddSubjectRejectsDuplicateKey() {
        var c = config()
        XCTAssertThrowsError(try c.addSubject(SubjectEntry(key: "caleb", subjectId: "x", label: "C", name: "n", dob: "d"))) {
            XCTAssertEqual($0 as? ConfigError, .duplicateKey("caleb"))
        }
    }
}
```
`Tests/HealthBridgeConfigTests/ConfigWriterTests.swift`:
```swift
import XCTest
@testable import HealthBridgeConfig

final class ConfigWriterTests: XCTestCase {
    private func tmpPath() -> String {
        NSTemporaryDirectory() + "hb-\(UUID().uuidString)/config.toml"
    }
    func testWriteCreatesParentDirsAndRoundTrips() throws {
        let path = tmpPath()
        var c = Config(dataRoot: "~/Documents/x", defaultSubject: "caleb", logLevel: "verbose")
        try c.addSubject(SubjectEntry(key: "caleb", subjectId: "uuid-c", label: "Caleb",
                                      name: "Caleb Feather", dob: "2015-04-12"))
        try ConfigWriter.write(c, path: path)            // parent dir did not exist
        let loaded = try XCTUnwrap(ConfigLoader.load(path: path))
        XCTAssertEqual(loaded, c)
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }
}
```

- [ ] **Step 3: Run to verify it fails** — Run: `swift test --filter HealthBridgeConfigTests`. Expected: FAIL — types undefined.

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

public enum ConfigError: Error, Equatable { case duplicateKey(String) }

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
    public mutating func addSubject(_ entry: SubjectEntry) throws {
        if subjects.contains(where: { $0.key == entry.key }) { throw ConfigError.duplicateKey(entry.key) }
        subjects.append(entry)
    }
    enum CodingKeys: String, CodingKey {
        case subjects
        case dataRoot = "data_root"
        case defaultSubject = "default_subject"
        case logLevel = "log_level"
    }
}
```
`Sources/HealthBridgeConfig/TOMLCodec.swift`:
```swift
import Foundation
import TOMLKit

/// The single point of contact with TOMLKit, so any API drift is contained to one file.
public enum TOMLCodec {
    public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try TOMLDecoder().decode(type, from: text)
    }
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        try TOMLEncoder().encode(value)
    }
}
```
`Sources/HealthBridgeConfig/Settings.swift`:
```swift
import Foundation

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
        return try TOMLCodec.decode(Config.self, from: text)
    }
}

public enum ConfigWriter {
    public static func write(_ config: Config, path: String) throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let toml = try TOMLCodec.encode(config)
        try toml.write(to: url, atomically: true, encoding: .utf8)
    }
}

public enum SettingsResolver {
    private static let defaultDataRoot = "~/Documents/apple-health-data-bridge"

    public static func resolve(config: Config?, overrides: Overrides) -> Settings {
        let rawRoot = overrides.dataRoot ?? config?.dataRoot ?? defaultDataRoot
        let dataRoot = URL(fileURLWithPath: (rawRoot as NSString).expandingTildeInPath)
        let level = overrides.logLevel ?? config?.logLevel.flatMap(LogLevel.init(rawValue:)) ?? .normal
        let subjects = config?.subjects ?? []
        let selectedKey = overrides.subject ?? config?.defaultSubject
        let selected = selectedKey.flatMap { key in subjects.first { $0.key == key } }
        return Settings(dataRoot: dataRoot, logLevel: level, subjects: subjects, selectedSubject: selected)
    }
}
```
Delete `Sources/HealthBridgeConfig/Placeholder.swift`.

- [ ] **Step 5: Run to verify pass** — Run: `swift test --filter HealthBridgeConfigTests`. Expected: all PASS.

- [ ] **Step 6: Commit**
```
git add Package.swift Sources/HealthBridgeConfig Tests/HealthBridgeConfigTests
git rm Sources/HealthBridgeConfig/Placeholder.swift
github-agent-commit "feat(config): TOML config, layered settings, ConfigWriter"
```

---

## Task 3: Bridge Document schema + subject binding + deterministic JSON

**Files:**
- Create: `Sources/BridgeKit/BridgeDocument.swift`, `Sources/BridgeKit/Observation.swift`, `Sources/BridgeKit/HealthKitMapping.swift`, `Sources/BridgeKit/BridgeJSON.swift`
- Delete: `Sources/BridgeKit/BridgeKit.swift`
- Test: `Tests/BridgeKitTests/BridgeDocumentCodingTests.swift`

**Interfaces:**
- `struct SubjectRef: Codable, Equatable, Sendable { var id; var label; var hash; var name: String?; var dob: String? }`.
- `BridgeDocument { schemaVersion: Int; source: Source; subject: SubjectRef; observations: [Observation] }`; `Source { kind; fileName; sha256; extractedAt: Date; extractor }`; `SourceKind { fhir, ccda, pdf }`; `Extractor { engine, version }`.
- `Observation { id; code: CodeableRef?; name; value: ObservationValue; unit: String?; effectiveDate: Date; category; mapping: HealthKitMapping?; confidence: Double; sourceLocator: SourceLocator? }`.
- `enum ObservationValue { case quantity(Double); case string(String) }` (tagged Codable); `ObservationCategory { vital, lab, other }`; `CodeableRef { system, code, display }`; `SourceLocator { page: Int?; snippet: String? }`; `HealthKitMapping { quantityType, canonicalUnit, convertedValue }`; `enum BridgeJSON { static let encoder; decoder }`.

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
        let decoded = try BridgeJSON.decoder.decode(BridgeDocument.self, from: BridgeJSON.encoder.encode(original))
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

## Task 4: Content-based observation ID + subject hash

**Files:**
- Create: `Sources/BridgeKit/ObservationID.swift`, `Sources/BridgeKit/SubjectHash.swift`
- Test: `Tests/BridgeKitTests/ObservationIDTests.swift`, `Tests/BridgeKitTests/SubjectHashTests.swift`

**Interfaces:**
- `enum ObservationID { static func derive(subjectId: String, system: String?, code: String?, effectiveDate: Date, rawValue: String, unit: String?) -> String }` — lowercase hex SHA-256 of `subjectId + system + code + effectiveDate(rounded sec) + rawValue + unit`. **Content-based, no `documentKey`**: the same clinical observation gets the same id across files (stable iOS sync identifier); a different subject yields a different id.
- `enum SubjectHash { static func make(name: String, dob: String) -> String }` — `sha256` of canonicalized `name.lowercased().trimmed|dob.trimmed`.

- [ ] **Step 1: Write failing tests** — `Tests/BridgeKitTests/ObservationIDTests.swift`:
```swift
import XCTest
@testable import BridgeKit

final class ObservationIDTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    func testDeterministic() {
        let a = ObservationID.derive(subjectId: "s", system: "http://loinc.org", code: "29463-7",
                                     effectiveDate: date, rawValue: "72.5", unit: "kg")
        let b = ObservationID.derive(subjectId: "s", system: "http://loinc.org", code: "29463-7",
                                     effectiveDate: date, rawValue: "72.5", unit: "kg")
        XCTAssertEqual(a, b); XCTAssertEqual(a.count, 64)
    }
    func testValueChangesID() {
        let a = ObservationID.derive(subjectId: "s", system: nil, code: nil, effectiveDate: date, rawValue: "72.5", unit: "kg")
        let b = ObservationID.derive(subjectId: "s", system: nil, code: nil, effectiveDate: date, rawValue: "73.0", unit: "kg")
        XCTAssertNotEqual(a, b)
    }
    func testSubjectChangesID() {
        let a = ObservationID.derive(subjectId: "s1", system: nil, code: nil, effectiveDate: date, rawValue: "x", unit: nil)
        let b = ObservationID.derive(subjectId: "s2", system: nil, code: nil, effectiveDate: date, rawValue: "x", unit: nil)
        XCTAssertNotEqual(a, b)
    }
    func testSameContentSameSubjectSameID() {
        // Cross-file: identical clinical content for the same subject -> identical id (no documentKey).
        let a = ObservationID.derive(subjectId: "s", system: "http://loinc.org", code: "29463-7",
                                     effectiveDate: date, rawValue: "72.5", unit: "kg")
        let b = ObservationID.derive(subjectId: "s", system: "http://loinc.org", code: "29463-7",
                                     effectiveDate: date, rawValue: "72.5", unit: "kg")
        XCTAssertEqual(a, b)
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
    public static func derive(subjectId: String, system: String?, code: String?,
                              effectiveDate: Date, rawValue: String, unit: String?) -> String {
        let parts = [subjectId, system ?? "", code ?? "",
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
github-agent-commit "feat(bridgekit): content-based observation id and subject hash"
```

---

## Task 5: LOINC→HealthKit mapping table + unit conversion

**Files:**
- Create: `Sources/BridgeKit/MappingTable.swift`
- Test: `Tests/BridgeKitTests/MappingTableTests.swift`

**Interfaces:**
- `enum MappingTable { static func resolve(loinc: String?, value: ObservationValue, unit: String?) -> HealthKitMapping? }` — `nil` when LOINC unknown, value not `.quantity`, or unit unconvertible. Seed **lean 10**; converters accept common UCUM spelling variants.

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
    func testBMIUnitVariants() {
        XCTAssertNotNil(MappingTable.resolve(loinc: "39156-5", value: .quantity(22), unit: "kg/m2"))
        XCTAssertNotNil(MappingTable.resolve(loinc: "39156-5", value: .quantity(22), unit: "kg/m^2"))
    }
    func testOxygenPercentVariants() {
        XCTAssertNotNil(MappingTable.resolve(loinc: "2708-6", value: .quantity(98), unit: "%"))
        XCTAssertNotNil(MappingTable.resolve(loinc: "2708-6", value: .quantity(98), unit: "{percent}"))
    }
    func testGlucoseUnits() {
        XCTAssertEqual(MappingTable.resolve(loinc: "2339-0", value: .quantity(5), unit: "mmol/L")?.convertedValue ?? 0, 90.09, accuracy: 0.5)
        XCTAssertNotNil(MappingTable.resolve(loinc: "2339-0", value: .quantity(90), unit: "mg/dl"))
    }
    func testTemperatureCelVariant() {
        XCTAssertEqual(MappingTable.resolve(loinc: "8310-5", value: .quantity(37), unit: "Cel")?.convertedValue ?? 0, 37, accuracy: 0.01)
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
    private static let glucose: (Double, String?) -> Double? = { v, u in
        switch u { case "mg/dL", "mg/dl", nil: return v; case "mmol/L", "mmol/l": return v*18.0182; default: return nil } }

    private static let table: [String: MappingEntry] = {
        let e: [MappingEntry] = [
            MappingEntry(loinc: "29463-7", quantityType: "HKQuantityTypeIdentifierBodyMass", canonicalUnit: "kg", convert: mass),
            MappingEntry(loinc: "8302-2",  quantityType: "HKQuantityTypeIdentifierHeight", canonicalUnit: "cm", convert: length),
            MappingEntry(loinc: "8310-5",  quantityType: "HKQuantityTypeIdentifierBodyTemperature", canonicalUnit: "degC", convert: temperature),
            MappingEntry(loinc: "39156-5", quantityType: "HKQuantityTypeIdentifierBodyMassIndex", canonicalUnit: "kg/m2", convert: passthrough(["kg/m2", "kg/m^2"])),
            MappingEntry(loinc: "8867-4",  quantityType: "HKQuantityTypeIdentifierHeartRate", canonicalUnit: "count/min", convert: passthrough(["/min","count/min","{beats}/min"])),
            MappingEntry(loinc: "9279-1",  quantityType: "HKQuantityTypeIdentifierRespiratoryRate", canonicalUnit: "count/min", convert: passthrough(["/min","count/min","{breaths}/min"])),
            MappingEntry(loinc: "2708-6",  quantityType: "HKQuantityTypeIdentifierOxygenSaturation", canonicalUnit: "%", convert: passthrough(["%","{percent}"])),
            MappingEntry(loinc: "8480-6",  quantityType: "HKQuantityTypeIdentifierBloodPressureSystolic", canonicalUnit: "mmHg", convert: passthrough(["mm[Hg]","mmHg"])),
            MappingEntry(loinc: "8462-4",  quantityType: "HKQuantityTypeIdentifierBloodPressureDiastolic", canonicalUnit: "mmHg", convert: passthrough(["mm[Hg]","mmHg"])),
            MappingEntry(loinc: "2339-0",  quantityType: "HKQuantityTypeIdentifierBloodGlucose", canonicalUnit: "mg/dL", convert: glucose),
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
- `struct ValidationIssue { enum Severity { case error, warning }; let severity; let message }`, `func validate(_:) -> [ValidationIssue]`. Errors: wrong `schemaVersion`; `source.sha256` not 64 hex chars; empty `subject.id`; `subject.id` not a valid UUID; empty `subject.hash`; duplicate observation ids (backstop — builder dedupes first); empty observation id or name; `confidence` outside `0...1`; non-finite quantity value; `mapping != nil` on a `.string` value; non-finite `mapping.convertedValue`; empty `mapping.quantityType`/`canonicalUnit`. Warning: zero observations.

- [ ] **Step 1: Write failing test** — `Tests/BridgeKitTests/ValidationTests.swift`:
```swift
import XCTest
@testable import BridgeKit

final class ValidationTests: XCTestCase {
    private let goodSha = String(repeating: "a", count: 64)
    private let goodUUID = "11111111-1111-1111-1111-111111111111"

    private func doc(_ obs: [Observation], schemaVersion: Int = 1, sha: String? = nil,
                     subjectId: String? = nil, hash: String = "h") -> BridgeDocument {
        BridgeDocument(schemaVersion: schemaVersion,
            source: Source(kind: .fhir, fileName: "f.json", sha256: sha ?? goodSha,
                           extractedAt: Date(timeIntervalSince1970: 0), extractor: Extractor(engine: "x", version: "1")),
            subject: SubjectRef(id: subjectId ?? goodUUID, label: "L", hash: hash), observations: obs)
    }
    private func obs(_ id: String = "a", name: String = "x", value: ObservationValue = .quantity(1),
                     mapping: HealthKitMapping? = nil, confidence: Double = 1.0) -> Observation {
        Observation(id: id, code: nil, name: name, value: value, unit: "kg",
                    effectiveDate: Date(timeIntervalSince1970: 0), category: .vital,
                    mapping: mapping, confidence: confidence, sourceLocator: nil)
    }
    private func errors(_ d: BridgeDocument) -> Bool { validate(d).contains { $0.severity == .error } }

    func testValid() { XCTAssertFalse(errors(doc([obs()]))) }
    func testWrongSchema() { XCTAssertTrue(errors(doc([obs()], schemaVersion: 99))) }
    func testBadShaLength() { XCTAssertTrue(errors(doc([obs()], sha: "abc"))) }
    func testEmptySubjectId() { XCTAssertTrue(errors(doc([obs()], subjectId: ""))) }
    func testInvalidSubjectUUID() { XCTAssertTrue(errors(doc([obs()], subjectId: "not-a-uuid"))) }
    func testEmptySubjectHash() { XCTAssertTrue(errors(doc([obs()], hash: ""))) }
    func testDuplicateIDs() { XCTAssertTrue(validate(doc([obs("a"), obs("a")])).contains { $0.message.contains("duplicate") }) }
    func testEmptyObservationName() { XCTAssertTrue(errors(doc([obs(name: "")]))) }
    func testNonFiniteValue() { XCTAssertTrue(errors(doc([obs(value: .quantity(.nan))]))) }
    func testMappingOnString() {
        XCTAssertTrue(errors(doc([obs(value: .string("p"), mapping: HealthKitMapping(quantityType: "X", canonicalUnit: "kg", convertedValue: 1))])))
    }
    func testNonFiniteConverted() {
        XCTAssertTrue(errors(doc([obs(mapping: HealthKitMapping(quantityType: "X", canonicalUnit: "kg", convertedValue: .infinity))])))
    }
    func testEmptyMappingField() {
        XCTAssertTrue(errors(doc([obs(mapping: HealthKitMapping(quantityType: "", canonicalUnit: "kg", convertedValue: 1))])))
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
```

- [ ] **Step 4: Run to verify pass** — Run: `swift test --filter ValidationTests`. Then `swift test --filter BridgeKitTests`. Expected: all PASS.

- [ ] **Step 5: Commit**
```
git add Sources/BridgeKit/Validation.swift Tests/BridgeKitTests/ValidationTests.swift
github-agent-commit "feat(bridgekit): hardened Bridge Document validation"
```

---

## Task 7: DocumentParser protocol + ParseResult

**Files:**
- Modify: `Package.swift` (add `HealthBridgeParsingTests` target — no resources yet)
- Create: `Sources/HealthBridgeParsing/DocumentParser.swift`
- Delete: `Sources/HealthBridgeParsing/Placeholder.swift`
- Test: `Tests/HealthBridgeParsingTests/DocumentParserTests.swift`

**Interfaces:**
- `protocol DocumentParser { static func canParse(_ data: Data) -> Bool; func parse(_ data: Data, subjectId: String) throws -> ParseResult }` — `subjectId` is threaded in so the parser derives content+subject-based ids.
- `struct ParseResult { let observations: [Observation]; let skipped: [Skip] }`.
- `struct Skip { enum Reason { case noCode, noDate, unrepresentableValue }; let reason; let label: String }`.
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
    func parse(_ data: Data, subjectId: String) throws -> ParseResult {
        guard !data.isEmpty else { throw ParseError.malformed("empty") }
        return ParseResult(observations: [], skipped: [Skip(reason: .noCode, label: "x")])
    }
}

final class DocumentParserTests: XCTestCase {
    func testCanParse() { XCTAssertTrue(StubParser.canParse(Data([0x7b]))); XCTAssertFalse(StubParser.canParse(Data())) }
    func testParseThrowsOnEmpty() {
        XCTAssertThrowsError(try StubParser().parse(Data(), subjectId: "s")) { XCTAssertEqual($0 as? ParseError, .malformed("empty")) }
    }
    func testParseResultCarriesSkips() throws {
        XCTAssertEqual(try StubParser().parse(Data([0x7b]), subjectId: "s").skipped.first?.reason, .noCode)
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
    func parse(_ data: Data, subjectId: String) throws -> ParseResult
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

## Task 8: FHIR R4 parser (components, UTC dates, drop-and-log)

**Files:**
- Modify: `Package.swift` (add `resources: [.copy("Fixtures")]` to `HealthBridgeParsingTests`)
- Create: `Sources/HealthBridgeParsing/FHIRDate.swift`, `Sources/HealthBridgeParsing/FHIRParser.swift`
- Create fixtures: `observation-bodyweight.json`, `bundle-vitals-and-labs.json`, `observation-nocode.json`, `bp-panel.json`, `observation-dateonly.json`, `observation-loinc-not-first.json`, `observation-string.json`, `observation-novalue.json`
- Test: `Tests/HealthBridgeParsingTests/FHIRParserTests.swift`

**Interfaces:**
- `struct FHIRParser: DocumentParser` — FHIR R4 JSON (`Observation` or `Bundle`) → `ParseResult`. Each observation `confidence = 1.0`, `mapping = nil`. Drops no-code (`.noCode`), no-date (`.noDate`), no/unrepresentable value (`.unrepresentableValue`), each recorded in `skipped`. **Panel handling:** an Observation with no top-level value but a `component` array yields one Observation per component (blood pressure). **UTC dates:** offset-less/date-only FHIR dates resolve in UTC via `FHIRDate`.

> Verified against FHIRModels 0.9.3: `Observation.code` is non-optional `CodeableConcept`; `value`/`effective` are optional enums (`Observation.ValueX?`/`EffectiveX?`); `Observation.component` is `[ObservationComponent]?` and each `ObservationComponent` has non-optional `code: CodeableConcept` and `value: ObservationComponent.ValueX?`; `Decimal` has no `.doubleValue` (wrap in `NSDecimalNumber`); `DateTime` exposes `.date` (year/month/day), `.time` (hour/minute/second), `.timeZone`.

- [ ] **Step 1: Wire fixtures into the manifest, then create them** — update `HealthBridgeParsingTests` in `Package.swift`:
```swift
        .testTarget(
            name: "HealthBridgeParsingTests",
            dependencies: ["HealthBridgeParsing", "BridgeKit"],
            resources: [.copy("Fixtures")]
        ),
```
`Fixtures/observation-bodyweight.json`:
```json
{ "resourceType": "Observation", "id": "bw1", "status": "final",
  "category": [ { "coding": [ { "system": "http://terminology.hl7.org/CodeSystem/observation-category", "code": "vital-signs" } ] } ],
  "code": { "coding": [ { "system": "http://loinc.org", "code": "29463-7", "display": "Body weight" } ], "text": "Body weight" },
  "effectiveDateTime": "2025-03-19T09:30:00-04:00",
  "valueQuantity": { "value": 72.5, "unit": "kg", "system": "http://unitsofmeasure.org", "code": "kg" } }
```
`Fixtures/bundle-vitals-and-labs.json`:
```json
{ "resourceType": "Bundle", "type": "collection", "entry": [
  { "resource": { "resourceType": "Observation", "id": "bw1", "status": "final",
    "category": [ { "coding": [ { "system": "http://terminology.hl7.org/CodeSystem/observation-category", "code": "vital-signs" } ] } ],
    "code": { "coding": [ { "system": "http://loinc.org", "code": "29463-7", "display": "Body weight" } ] },
    "effectiveDateTime": "2025-03-19T09:30:00-04:00",
    "valueQuantity": { "value": 72.5, "unit": "kg", "system": "http://unitsofmeasure.org", "code": "kg" } } },
  { "resource": { "resourceType": "Observation", "id": "alt1", "status": "final",
    "category": [ { "coding": [ { "system": "http://terminology.hl7.org/CodeSystem/observation-category", "code": "laboratory" } ] } ],
    "code": { "coding": [ { "system": "http://loinc.org", "code": "1742-6", "display": "ALT" } ] },
    "effectiveDateTime": "2025-03-19T09:30:00-04:00",
    "valueQuantity": { "value": 22, "unit": "U/L", "system": "http://unitsofmeasure.org", "code": "U/L" } } }
]}
```
`Fixtures/observation-nocode.json`:
```json
{ "resourceType": "Observation", "id": "nc1", "status": "final",
  "code": { "text": "Free text only" },
  "effectiveDateTime": "2025-03-19T09:30:00-04:00",
  "valueQuantity": { "value": 1, "unit": "kg", "system": "http://unitsofmeasure.org", "code": "kg" } }
```
`Fixtures/bp-panel.json` (panel with components, no top-level value):
```json
{ "resourceType": "Observation", "id": "bp1", "status": "final",
  "category": [ { "coding": [ { "system": "http://terminology.hl7.org/CodeSystem/observation-category", "code": "vital-signs" } ] } ],
  "code": { "coding": [ { "system": "http://loinc.org", "code": "85354-9", "display": "Blood pressure panel" } ] },
  "effectiveDateTime": "2025-03-19T09:30:00-04:00",
  "component": [
    { "code": { "coding": [ { "system": "http://loinc.org", "code": "8480-6", "display": "Systolic" } ] },
      "valueQuantity": { "value": 120, "unit": "mmHg", "system": "http://unitsofmeasure.org", "code": "mm[Hg]" } },
    { "code": { "coding": [ { "system": "http://loinc.org", "code": "8462-4", "display": "Diastolic" } ] },
      "valueQuantity": { "value": 80, "unit": "mmHg", "system": "http://unitsofmeasure.org", "code": "mm[Hg]" } }
  ] }
```
`Fixtures/observation-dateonly.json` (date-only → UTC midnight):
```json
{ "resourceType": "Observation", "id": "do1", "status": "final",
  "code": { "coding": [ { "system": "http://loinc.org", "code": "29463-7", "display": "Body weight" } ] },
  "effectiveDateTime": "2025-03-19",
  "valueQuantity": { "value": 70, "unit": "kg", "system": "http://unitsofmeasure.org", "code": "kg" } }
```
`Fixtures/observation-loinc-not-first.json` (LOINC is the second coding):
```json
{ "resourceType": "Observation", "id": "lf1", "status": "final",
  "code": { "coding": [
    { "system": "http://example.org/local", "code": "WT", "display": "Weight (local)" },
    { "system": "http://loinc.org", "code": "29463-7", "display": "Body weight" } ] },
  "effectiveDateTime": "2025-03-19T09:30:00-04:00",
  "valueQuantity": { "value": 72.5, "unit": "kg", "system": "http://unitsofmeasure.org", "code": "kg" } }
```
`Fixtures/observation-string.json` (valueString):
```json
{ "resourceType": "Observation", "id": "s1", "status": "final",
  "code": { "coding": [ { "system": "http://loinc.org", "code": "12345-6", "display": "Note" } ] },
  "effectiveDateTime": "2025-03-19T09:30:00-04:00",
  "valueString": "positive" }
```
`Fixtures/observation-novalue.json` (no value, no components → unrepresentable):
```json
{ "resourceType": "Observation", "id": "nv1", "status": "final",
  "code": { "coding": [ { "system": "http://loinc.org", "code": "29463-7", "display": "Body weight" } ] },
  "effectiveDateTime": "2025-03-19T09:30:00-04:00" }
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
    private func parse(_ n: String) throws -> ParseResult { try FHIRParser().parse(try fixture(n), subjectId: "s") }

    func testCanParseDetectsFHIR() throws {
        XCTAssertTrue(FHIRParser.canParse(try fixture("observation-bodyweight")))
        XCTAssertFalse(FHIRParser.canParse(Data("<ClinicalDocument/>".utf8)))
    }
    func testParsesSingleObservation() throws {
        let o = try XCTUnwrap(parse("observation-bodyweight").observations.first)
        XCTAssertEqual(o.code?.code, "29463-7"); XCTAssertEqual(o.code?.system, "http://loinc.org")
        XCTAssertEqual(o.name, "Body weight"); XCTAssertEqual(o.value, .quantity(72.5)); XCTAssertEqual(o.unit, "kg")
        XCTAssertEqual(o.category, .vital); XCTAssertEqual(o.confidence, 1.0); XCTAssertNil(o.mapping)
        XCTAssertEqual(o.effectiveDate.timeIntervalSince1970, 1_742_391_000, accuracy: 1)
    }
    func testParsesBundle() throws {
        let r = try parse("bundle-vitals-and-labs")
        XCTAssertEqual(r.observations.count, 2)
        XCTAssertEqual(r.observations.first?.category, .vital); XCTAssertEqual(r.observations.last?.category, .lab)
    }
    func testBloodPressurePanelYieldsTwoMappableComponents() throws {
        let r = try parse("bp-panel")
        XCTAssertEqual(r.observations.count, 2)
        let codes = Set(r.observations.compactMap { $0.code?.code })
        XCTAssertEqual(codes, ["8480-6", "8462-4"])
        for o in r.observations {
            XCTAssertNotNil(MappingTable.resolve(loinc: o.code?.code, value: o.value, unit: o.unit))
        }
    }
    func testDateOnlyResolvesUTCMidnight() throws {
        // "2025-03-19" -> 2025-03-19T00:00:00Z = 1_742_342_400, regardless of machine TZ.
        let o = try XCTUnwrap(parse("observation-dateonly").observations.first)
        XCTAssertEqual(o.effectiveDate.timeIntervalSince1970, 1_742_342_400, accuracy: 1)
    }
    func testLOINCNotFirstCodingIsChosen() throws {
        XCTAssertEqual(try parse("observation-loinc-not-first").observations.first?.code?.code, "29463-7")
    }
    func testValueStringObservation() throws {
        let o = try XCTUnwrap(parse("observation-string").observations.first)
        XCTAssertEqual(o.value, .string("positive")); XCTAssertNil(o.unit)
    }
    func testNoValueIsSkipped() throws {
        let r = try parse("observation-novalue")
        XCTAssertEqual(r.observations.count, 0)
        XCTAssertEqual(r.skipped.first?.reason, .unrepresentableValue)
    }
    func testDropsAndRecordsCodeless() throws {
        let r = try parse("observation-nocode")
        XCTAssertEqual(r.observations.count, 0)
        XCTAssertEqual(r.skipped.first?.reason, .noCode); XCTAssertEqual(r.skipped.first?.label, "Free text only")
    }
    func testMalformedThrows() { XCTAssertThrowsError(try FHIRParser().parse(Data("{ not".utf8), subjectId: "s")) }
}
```

- [ ] **Step 3: Run to verify it fails** — Run: `swift test --filter FHIRParserTests`. Expected: FAIL.

- [ ] **Step 4: Implement** — `Sources/HealthBridgeParsing/FHIRDate.swift`:
```swift
import Foundation
import ModelsR4

/// Converts FHIR temporal values to a Foundation Date, resolving timezone-less / date-only
/// values in UTC so the same input yields the same Date on any machine.
enum FHIRDate {
    private static func utcCalendar(_ tz: TimeZone?) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz ?? TimeZone(identifier: "UTC")!
        return cal
    }

    static func date(from dt: DateTime) -> Date? {
        var c = DateComponents()
        c.year = dt.date.year
        c.month = dt.date.month.map(Int.init)
        c.day = dt.date.day.map(Int.init)
        if let t = dt.time {
            c.hour = Int(t.hour); c.minute = Int(t.minute)
            c.second = Int(NSDecimalNumber(decimal: t.second).doubleValue.rounded())
        } else {
            c.hour = 0; c.minute = 0; c.second = 0   // date-only -> UTC midnight
        }
        return utcCalendar(dt.timeZone).date(from: c)
    }

    static func date(from inst: Instant) -> Date? {
        var c = DateComponents()
        c.year = inst.date.year
        c.month = inst.date.month.map(Int.init)
        c.day = inst.date.day.map(Int.init)
        c.hour = Int(inst.time.hour); c.minute = Int(inst.time.minute)
        c.second = Int(NSDecimalNumber(decimal: inst.time.second).doubleValue.rounded())
        return utcCalendar(inst.timeZone).date(from: c)
    }
}
```
`Sources/HealthBridgeParsing/FHIRParser.swift`:
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

    public func parse(_ data: Data, subjectId: String) throws -> ParseResult {
        let fhir = try decodeObservations(data)
        var observations: [Observation] = []
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

    private enum ConvertResult { case success(Observation); case failure(Skip) }

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
        return .success(Observation(id: id, code: ref, name: display, value: val, unit: unit,
                                    effectiveDate: effective, category: category, mapping: nil,
                                    confidence: 1.0, sourceLocator: nil))
    }

    private func loincCoding(_ code: CodeableConcept) -> Coding? {
        let codings = code.coding ?? []
        return codings.first { $0.system?.value?.url.absoluteString == "http://loinc.org" } ?? codings.first
    }

    private func observationValue(_ value: Observation.ValueX?) -> (ObservationValue, String?, String)? {
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

    private func effectiveDate(_ effective: Observation.EffectiveX?) -> Date? {
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

    /// Lossless number rendering for id stability (no %g rounding); integral values drop the .0.
    private func stableNumberString(_ d: Double) -> String {
        d.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(d)) : String(d)
    }
}
```

- [ ] **Step 5: Run to verify pass** — Run: `swift test --filter FHIRParserTests`. Expected: all PASS.

- [ ] **Step 6: Commit**
```
git add Package.swift Sources/HealthBridgeParsing Tests/HealthBridgeParsingTests
github-agent-commit "feat(parsing): FHIR R4 parser — components, UTC dates, lossless ids, drop-and-log"
```

---

## Task 9: healthbridge CLI (parse + subject subcommands)

**Files:**
- Modify: `Package.swift` (add `healthbridgeTests` target with `resources: [.copy("Fixtures")]`)
- Create: `Sources/healthbridge/HealthBridge.swift`
- Delete: `Sources/healthbridge/main.swift`
- Create fixtures: `bundle-vitals-and-labs.json`, `patient-bundle.json`, `patient-bundle-mismatch.json`, `bundle-duplicate.json`, `empty-bundle.json`
- Test: `Tests/healthbridgeTests/BridgeBuilderTests.swift`, `Tests/healthbridgeTests/CLIRunTests.swift`

**Interfaces:**
- `BridgeBuilder.build(data:fileName:subject:now:) throws -> BuildResult` where `struct BuildResult { let document: BridgeDocument; let skipped: [Skip] }` — sha256 → `FHIRParser().parse(_, subjectId: subject.id)` (ONE parse) → resolve mapping → dedupe by id → assemble with `extractedAt = now`. `now: Date = Date()` so tests fix the clock.
- `enum PatientMatchResult { case match, mismatch, noPatient, incomplete }`; `enum PatientMatch { static func check(data:subject:) -> PatientMatchResult; static func extracted(data:) -> (name: String, dob: String)? }`. Flexible match: case-insensitive first+last name tokens + dob equality. Handles a `Bundle` or a bare `Patient`.
- CLI: `parse <input> [--config][--subject][--data-root][--verbose|--quiet][--force][--allow-unverified-subject]`; `subject add --label --name --dob [--key][--config]`; `subject list [--config]`.
- Output: `<dataRoot>/subjects/<subject.id>/<sourceSha>.bridge.json`. Exit code `2` when a document is written with zero observations.

- [ ] **Step 1: Declare the CLI test target + fixtures** — add to `Package.swift`:
```swift
        .testTarget(
            name: "healthbridgeTests",
            dependencies: ["healthbridge", "BridgeKit", "HealthBridgeConfig"],
            resources: [.copy("Fixtures")]
        ),
```
Create fixtures:
```
mkdir -p Tests/healthbridgeTests/Fixtures
cp Tests/HealthBridgeParsingTests/Fixtures/bundle-vitals-and-labs.json Tests/healthbridgeTests/Fixtures/bundle-vitals-and-labs.json
```
`Fixtures/patient-bundle.json` (Patient matches subject "Caleb Feather" / 2015-04-12):
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
`Fixtures/patient-bundle-mismatch.json` — same as `patient-bundle.json` but Patient name `Stephen Feather`, birthDate `1975-01-01`.
`Fixtures/bundle-duplicate.json` — the body-weight observation twice (FHIR ids `bw1`/`bw1-dup`, identical content), no Patient.
`Fixtures/empty-bundle.json`:
```json
{ "resourceType": "Bundle", "type": "collection", "entry": [] }
```

- [ ] **Step 2: Write the failing tests** — `Tests/healthbridgeTests/BridgeBuilderTests.swift`:
```swift
import XCTest
import BridgeKit
import HealthBridgeConfig
@testable import healthbridge

final class BridgeBuilderTests: XCTestCase {
    private func fixture(_ n: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(n)", withExtension: "json")))
    }
    private let subject = SubjectRef(id: "11111111-1111-1111-1111-111111111111", label: "Caleb",
                                     hash: "h", name: "Caleb Feather", dob: "2015-04-12")
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    private func entry(_ name: String, _ dob: String, key: String = "caleb") -> SubjectEntry {
        SubjectEntry(key: key, subjectId: "uuid", label: "L", name: name, dob: dob)
    }

    func testBuildsValidSubjectBoundDocument() throws {
        let r = try BridgeBuilder.build(data: try fixture("bundle-vitals-and-labs"), fileName: "f.json", subject: subject, now: fixedNow)
        XCTAssertEqual(r.document.subject.id, subject.id)
        XCTAssertEqual(r.document.observations.count, 2)
        XCTAssertEqual(try XCTUnwrap(r.document.observations.first { $0.code?.code == "29463-7" }).mapping?.quantityType,
                       "HKQuantityTypeIdentifierBodyMass")
        XCTAssertNil(try XCTUnwrap(r.document.observations.first { $0.code?.code == "1742-6" }).mapping)
        XCTAssertFalse(validate(r.document).contains { $0.severity == .error })
    }
    func testDedupes() throws {
        XCTAssertEqual(try BridgeBuilder.build(data: try fixture("bundle-duplicate"), fileName: "d.json", subject: subject, now: fixedNow).document.observations.count, 1)
    }
    func testDeterministicWithFixedClock() throws {
        let d = try fixture("bundle-vitals-and-labs")
        let a = try BridgeJSON.encoder.encode(BridgeBuilder.build(data: d, fileName: "f.json", subject: subject, now: fixedNow).document)
        let b = try BridgeJSON.encoder.encode(BridgeBuilder.build(data: d, fileName: "f.json", subject: subject, now: fixedNow).document)
        XCTAssertEqual(a, b)
    }
    func testCrossCheckMatch() throws {
        XCTAssertEqual(PatientMatch.check(data: try fixture("patient-bundle"), subject: entry("Caleb Feather", "2015-04-12")), .match)
    }
    func testCrossCheckMismatch() throws {
        XCTAssertEqual(PatientMatch.check(data: try fixture("patient-bundle-mismatch"), subject: entry("Caleb Feather", "2015-04-12")), .mismatch)
    }
    func testCrossCheckNoPatient() throws {
        XCTAssertEqual(PatientMatch.check(data: try fixture("bundle-duplicate"), subject: entry("Caleb Feather", "2015-04-12")), .noPatient)
    }
    func testCrossCheckFlexibleMiddleName() throws {
        // Roster "Caleb Feather" should still match a document Patient "Caleb John Feather" (first+last tokens).
        XCTAssertEqual(PatientMatch.check(data: try fixture("patient-bundle"), subject: entry("Caleb John Feather", "2015-04-12")), .match)
    }
}
```
`Tests/healthbridgeTests/CLIRunTests.swift` (runs the built executable):
```swift
import XCTest

final class CLIRunTests: XCTestCase {
    private var binary: URL {
        // The test bundle sits next to the built products in .build/<config>/.
        Bundle(for: CLIRunTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("healthbridge")
    }
    private func fixturePath(_ n: String) throws -> String {
        try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(n)", withExtension: "json")).path
    }
    @discardableResult
    private func run(_ args: [String]) throws -> (status: Int32, err: String) {
        let p = Process(); p.executableURL = binary; p.arguments = args
        let ep = Pipe(); p.standardError = ep; p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
        let err = String(decoding: ep.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (p.terminationStatus, err)
    }
    private func tmpConfig() throws -> String {
        let dir = NSTemporaryDirectory() + "hbcli-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/config.toml"
        let r = try run(["subject", "add", "--label", "Caleb", "--name", "Caleb Feather", "--dob", "2015-04-12", "--config", path])
        XCTAssertEqual(r.status, 0, r.err)
        return path
    }

    func testNoSubjectFails() throws {
        let cfg = NSTemporaryDirectory() + "empty-\(UUID().uuidString).toml"
        let r = try run(["parse", try fixturePath("bundle-vitals-and-labs"), "--config", cfg])
        XCTAssertNotEqual(r.status, 0)
    }
    func testUnknownSubjectFails() throws {
        let r = try run(["parse", try fixturePath("bundle-vitals-and-labs"), "--config", try tmpConfig(), "--subject", "nobody"])
        XCTAssertNotEqual(r.status, 0)
    }
    func testPatientMismatchRefuses() throws {
        let r = try run(["parse", try fixturePath("patient-bundle-mismatch"), "--config", try tmpConfig(), "--subject", "caleb"])
        XCTAssertNotEqual(r.status, 0)
    }
    func testWritesOutputAndSummary() throws {
        let cfg = try tmpConfig()
        let dataRoot = NSTemporaryDirectory() + "hbdata-\(UUID().uuidString)"
        let r = try run(["parse", try fixturePath("patient-bundle"), "--config", cfg, "--subject", "caleb", "--data-root", dataRoot])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(r.err.contains("observations"))
    }
    func testQuietSuppressesSummary() throws {
        let r = try run(["parse", try fixturePath("patient-bundle"), "--config", try tmpConfig(), "--subject", "caleb",
                         "--data-root", NSTemporaryDirectory() + "q-\(UUID().uuidString)", "--quiet"])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertFalse(r.err.contains("observations"))
    }
    func testVerboseAndQuietTogetherErrors() throws {
        let r = try run(["parse", try fixturePath("patient-bundle"), "--config", try tmpConfig(), "--subject", "caleb",
                         "--verbose", "--quiet"])
        XCTAssertNotEqual(r.status, 0)
    }
}
```

- [ ] **Step 3: Run to verify it fails** — Run: `swift test --filter "BridgeBuilderTests|CLIRunTests"`. Expected: FAIL (CLIRunTests also needs the binary built — Step 5 builds it).

- [ ] **Step 4: Implement** — `Sources/healthbridge/HealthBridge.swift`:
```swift
import Foundation
import CryptoKit
import ArgumentParser
import BridgeKit
import HealthBridgeConfig
import HealthBridgeParsing
import ModelsR4

public struct BuildResult { public let document: BridgeDocument; public let skipped: [Skip] }

public enum BridgeBuilder {
    public static func build(data: Data, fileName: String, subject: SubjectRef, now: Date = Date()) throws -> BuildResult {
        let sha = sha256Hex(data)
        guard FHIRParser.canParse(data) else { throw ParseError.unrecognizedFormat }
        let result = try FHIRParser().parse(data, subjectId: subject.id)
        let resolved = result.observations.map { o -> Observation in
            var o = o
            o.mapping = MappingTable.resolve(loinc: o.code?.code, value: o.value, unit: o.unit)
            return o
        }
        var seen = Set<String>()
        let deduped = resolved.filter { seen.insert($0.id).inserted }
        let doc = BridgeDocument(
            schemaVersion: BridgeDocument.currentSchemaVersion,
            source: Source(kind: .fhir, fileName: fileName, sha256: sha, extractedAt: now,
                           extractor: Extractor(engine: "fhir-parser", version: "0.1.0")),
            subject: subject, observations: deduped)
        return BuildResult(document: doc, skipped: result.skipped)
    }
    public static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

public enum PatientMatchResult { case match, mismatch, noPatient, incomplete }

public enum PatientMatch {
    public static func check(data: Data, subject: SubjectEntry) -> PatientMatchResult {
        guard let patient = firstPatient(data) else { return .noPatient }
        guard let (name, dob) = nameAndDOB(patient), !name.isEmpty, !dob.isEmpty else { return .incomplete }
        let docTokens = name.lowercased().split(separator: " ").map(String.init)
        let subjTokens = subject.name.lowercased().split(separator: " ").map(String.init)
        guard let df = docTokens.first, let dl = docTokens.last,
              let sf = subjTokens.first, let sl = subjTokens.last else { return .mismatch }
        return (df == sf && dl == sl && dob == subject.dob) ? .match : .mismatch
    }
    public static func extracted(data: Data) -> (name: String, dob: String)? {
        guard let p = firstPatient(data), let (n, d) = nameAndDOB(p) else { return nil }
        return (n, d)
    }
    private static func firstPatient(_ data: Data) -> ModelsR4.Patient? {
        let dec = JSONDecoder()
        if let bundle = try? dec.decode(ModelsR4.Bundle.self, from: data) {
            return bundle.entry?.compactMap { $0.resource?.get(if: ModelsR4.Patient.self) }.first
        }
        return try? dec.decode(ModelsR4.Patient.self, from: data)
    }
    private static func nameAndDOB(_ p: ModelsR4.Patient) -> (String, String)? {
        guard let hn = p.name?.first else { return nil }
        let given = (hn.given ?? []).compactMap { $0.value?.string }.joined(separator: " ")
        let family = hn.family?.value?.string ?? ""
        let dob = p.birthDate?.value?.description ?? ""
        return ("\(given) \(family)".trimmingCharacters(in: .whitespaces), dob)
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
    @Flag(name: .long, help: "Proceed despite a Patient mismatch.") var force = false
    @Flag(name: .long, help: "Proceed when the Patient is present but unverifiable.") var allowUnverifiedSubject = false

    func validate() throws {
        if verbose && quiet { throw ValidationError("--verbose and --quiet are mutually exclusive") }
    }

    func run() throws {
        let cfg = try ConfigLoader.load(path: config)
        let overrides = Overrides(dataRoot: dataRoot, subject: subject,
                                  logLevel: verbose ? .verbose : (quiet ? .quiet : nil))
        let settings = SettingsResolver.resolve(config: cfg, overrides: overrides)
        guard let entry = settings.selectedSubject else { throw Fail("no subject selected (set --subject or default_subject in config)") }

        let inputURL = URL(fileURLWithPath: input)
        let data = try Data(contentsOf: inputURL)

        switch PatientMatch.check(data: data, subject: entry) {
        case .match, .noPatient: break
        case .mismatch:
            if !force { throw Fail("Patient mismatch — refusing.\n\(mismatchDetail(data, entry))\nUse --force to override.") }
        case .incomplete:
            if !allowUnverifiedSubject { throw Fail("Patient present but unverifiable — refusing. Use --allow-unverified-subject to override.") }
        }

        let subjectRef = SubjectRef(id: entry.subjectId, label: entry.label,
                                    hash: SubjectHash.make(name: entry.name, dob: entry.dob),
                                    name: entry.name, dob: entry.dob)
        let result = try BridgeBuilder.build(data: data, fileName: inputURL.lastPathComponent, subject: subjectRef)
        let doc = result.document

        let issues = validate(doc)
        for i in issues { FileHandle.standardError.write(Data("[\(i.severity)] \(i.message)\n".utf8)) }
        if issues.contains(where: { $0.severity == .error }) { throw Fail("validation failed") }

        let dir = settings.dataRoot.appendingPathComponent("subjects/\(entry.subjectId)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("\(doc.source.sha256).bridge.json")
        try BridgeJSON.encoder.encode(doc).write(to: out)

        if settings.logLevel != .quiet {
            let mapped = doc.observations.filter { $0.mapping != nil }.count
            log("Wrote \(out.path): \(doc.observations.count) observations, \(mapped) mapped, \(doc.observations.count - mapped) unmapped, \(result.skipped.count) skipped.")
            for o in doc.observations where o.mapping == nil {
                log("  unmapped: \(o.code?.code ?? "—") \(o.name)")
            }
            for s in result.skipped { log("  skipped (\(s.reason)): \(s.label)") }
        }
        if doc.observations.isEmpty { throw ExitCode(2) }   // wrote an empty document
    }

    private func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    private func mismatchDetail(_ data: Data, _ entry: SubjectEntry) -> String {
        let ext = PatientMatch.extracted(data: data)
        return "  document: \(ext?.name ?? "?") / \(ext?.dob ?? "?")\n  roster:   \(entry.name) / \(entry.dob)"
    }
}

struct Subject: ParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [Add.self, List.self])

    struct Add: ParsableCommand {
        @Option(name: .long) var label: String
        @Option(name: .long) var name: String
        @Option(name: .long) var dob: String
        @Option(name: .long, help: "Explicit roster key (defaults from label).") var key: String?
        @Option(name: .long) var config: String = ConfigLoader.defaultPath
        func run() throws {
            var cfg = (try ConfigLoader.load(path: config)) ?? Config()
            let resolvedKey = key ?? label.lowercased().replacingOccurrences(of: " ", with: "-")
            let entry = SubjectEntry(key: resolvedKey, subjectId: UUID().uuidString, label: label, name: name, dob: dob)
            do { try cfg.addSubject(entry) }
            catch ConfigError.duplicateKey(let k) { throw Fail("Subject key '\(k)' already exists") }
            try ConfigWriter.write(cfg, path: config)
            print("Added subject '\(resolvedKey)' with subjectId \(entry.subjectId)")
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
Delete `Sources/healthbridge/main.swift`.

- [ ] **Step 5: Build then run to verify pass** — Run: `swift build` (produces the `healthbridge` binary the CLI tests exec), then `swift test --filter "BridgeBuilderTests|CLIRunTests"`. Expected: all PASS.

- [ ] **Step 6: Manual end-to-end**
```
swift run healthbridge subject add --label "Caleb" --name "Caleb Feather" --dob 2015-04-12 --config /tmp/hb.toml
swift run healthbridge parse Tests/healthbridgeTests/Fixtures/patient-bundle.json --subject caleb --config /tmp/hb.toml --data-root /tmp/hbdata
```
Expected: subject added (prints a UUID); parse writes `/tmp/hbdata/subjects/<uuid>/<sha>.bridge.json`, prints the summary incl. unmapped lines. Clean up `/tmp/hb.toml` and `/tmp/hbdata` after.

- [ ] **Step 7: Full suite** — Run: `swift test`. Expected: every test across all targets PASSES.

- [ ] **Step 8: Commit**
```
git add Package.swift Sources/healthbridge Tests/healthbridgeTests
git rm Sources/healthbridge/main.swift
github-agent-commit "feat(cli): parse + subject subcommands, cross-check, per-subject storage"
```

---

## Self-Review (plan author)

**Spec coverage:** preflight/worktree (Task 0) · config + layered precedence + ConfigWriter + TOMLCodec (Task 2) · subject binding + content-based id + subject hash (Tasks 3–4) · mapping incl. UCUM variants (5) · hardened validation (6) · parser protocol with skips (7) · FHIR parse with BP components, UTC dates, lossless ids, drop-and-log (8) · CLI with cross-check tri-state, `--force`/`--allow-unverified-subject`, mutually-exclusive flags, duplicate-key rejection, unmapped+skip logging, zero-obs exit code, per-subject storage, and executable integration tests (9). Cross-file dedup now occurs via the content-based id; iOS device-binding gate, C-CDA, PDF/LLM remain out of scope.

**Placeholder scan:** no TBD/"adjust if tests fail"/"similar to"; every code step has complete code. The lone real-API risk is `ModelsR4`'s `DateTime`/`FHIRTime` field shapes used in `FHIRDate` (e.g. `time.second` as `Decimal`, `date.month`/`day` as optional `UInt8`); the date-only and timestamp tests pin the behavior.

**Type consistency:** `DocumentParser.parse(_:subjectId:)` identical across Tasks 7–9. `ObservationID.derive(subjectId:…)` content-based, used by `FHIRParser.build` and asserted in Task 4. `BridgeBuilder.build(data:fileName:subject:now:) -> BuildResult` (clock injected) used by the CLI and Task 9 tests. `PatientMatchResult` enum drives the CLI's `--force`/`--allow-unverified-subject` policy. `SubjectRef` (document) vs `SubjectEntry` (roster) distinct by design; the roster entry resolves into the document's `SubjectRef`. `Config.addSubject`/`ConfigError.duplicateKey`, `ConfigWriter.write`, `TOMLCodec`, `MappingTable.resolve`, `SubjectHash.make`, `validate` referenced consistently.
```
