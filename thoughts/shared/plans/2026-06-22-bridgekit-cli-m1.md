# BridgeKit + healthbridge CLI (Milestone 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an all-Swift package that parses a FHIR R4 JSON medical-record document into a validated `*.bridge.json` Bridge Document, with each observation pre-resolved against a LOINC→HealthKit mapping table.

**Architecture:** A single Swift Package Manager package with three targets. `BridgeKit` (platform-pure library: schema, mapping table, ID derivation, validation — no FHIR dependency). `HealthBridgeParsing` (library: `DocumentParser` protocol + `FHIRParser`, depends on `BridgeKit` + Apple's `FHIRModels`). `healthbridge` (executable: an `ArgumentParser` CLI that wires file I/O → parse → resolve → validate → write). Data flows one direction: FHIR JSON → `[Observation]` → resolve mapping → `BridgeDocument` → JSON file.

**Tech Stack:** Swift 5.9+, Swift Package Manager, Apple `FHIRModels` (`ModelsR4` product), `swift-argument-parser`, `CryptoKit` (SHA-256, built-in on Apple platforms).

## Global Constraints

- Swift tools version: **5.9**. Platforms: **`.macOS(.v13)`, `.iOS(.v16)`** (BridgeKit must compile for iOS for the future writer app; `CryptoKit` is available on both).
- Dependencies (exact products): `FHIRModels` → product **`ModelsR4`**; `swift-argument-parser` → product **`ArgumentParser`**. Pin to the latest resolved version during Task 1 and record it.
- `BridgeKit` MUST NOT import `ModelsR4`, `ArgumentParser`, or any non-Apple framework. Only `Foundation` + `CryptoKit`.
- Bridge Document JSON encoding is **deterministic**: `JSONEncoder` with `outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]` and `dateEncodingStrategy = .iso8601`; decoder uses `dateDecodingStrategy = .iso8601`.
- `schemaVersion` current value: **1**.
- FHIR-derived observations always carry `confidence = 1.0`.
- LOINC system URI is the string **`http://loinc.org`**.
- **No network in tests.** All FHIR fixtures are checked-in JSON files. **No PHI** in the repo — fixtures are synthetic or drawn from public FHIR examples.
- TDD throughout: failing test first, minimal implementation, green, commit. Commit after every task with `git`-style messages shown in steps. (Plan commits and code commits land per the repo's commit rules.)

---

## File Structure

```
Package.swift
Sources/
  BridgeKit/
    BridgeDocument.swift        # BridgeDocument, Source, SourceKind, Extractor, Subject
    Observation.swift           # Observation, ObservationValue (custom Codable), ObservationCategory, CodeableRef, SourceLocator
    HealthKitMapping.swift      # HealthKitMapping struct
    BridgeJSON.swift            # configured encoder/decoder (deterministic)
    ObservationID.swift         # deriveObservationID(...)
    MappingTable.swift          # MappingEntry, the table, resolveMapping(_:), unit conversion
    Validation.swift            # ValidationIssue, validate(_:)
  HealthBridgeParsing/
    DocumentParser.swift        # DocumentParser protocol, ParseError
    FHIRParser.swift            # FHIRParser: FHIR R4 JSON -> [Observation]
  healthbridge/
    HealthBridge.swift          # @main ParsableCommand root + `parse` subcommand
Tests/
  BridgeKitTests/
    BridgeDocumentCodingTests.swift
    ObservationIDTests.swift
    MappingTableTests.swift
    ValidationTests.swift
  HealthBridgeParsingTests/
    FHIRParserTests.swift
    Fixtures/
      observation-bodyweight.json
      bundle-vitals-and-labs.json
  healthbridgeTests/
    CLIIntegrationTests.swift
    Fixtures/
      bundle-vitals-and-labs.json   # copy used by CLI test
```

---

## Task 1: Package scaffold

**Files:**
- Create: `Package.swift`
- Create: `Sources/BridgeKit/BridgeKit.swift` (temporary placeholder)
- Test: `Tests/BridgeKitTests/SmokeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: a buildable package exposing the `BridgeKit` library target.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "apple-health-data-bridge",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "BridgeKit", targets: ["BridgeKit"]),
        .library(name: "HealthBridgeParsing", targets: ["HealthBridgeParsing"]),
        .executable(name: "healthbridge", targets: ["healthbridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/FHIRModels.git", from: "0.5.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(name: "BridgeKit"),
        .target(
            name: "HealthBridgeParsing",
            dependencies: [
                "BridgeKit",
                .product(name: "ModelsR4", package: "FHIRModels"),
            ]
        ),
        .executableTarget(
            name: "healthbridge",
            dependencies: [
                "HealthBridgeParsing",
                "BridgeKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "BridgeKitTests", dependencies: ["BridgeKit"]),
        .testTarget(
            name: "HealthBridgeParsingTests",
            dependencies: ["HealthBridgeParsing", "BridgeKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "healthbridgeTests",
            dependencies: ["healthbridge"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

> Note: `HealthBridgeParsing` and `healthbridge` targets are declared now but their source/test files arrive in later tasks. Create empty `Sources/HealthBridgeParsing/` and `Sources/healthbridge/` directories with a one-line placeholder so the package resolves. Add placeholders:
> - `Sources/HealthBridgeParsing/Placeholder.swift` → `// placeholder, replaced in Task 6`
> - `Sources/healthbridge/Placeholder.swift` → `// placeholder, replaced in Task 8`
> - `Tests/HealthBridgeParsingTests/Fixtures/.gitkeep` and `Tests/healthbridgeTests/Fixtures/.gitkeep` (empty) so `.copy("Fixtures")` resolves.

- [ ] **Step 2: Create placeholder source**

`Sources/BridgeKit/BridgeKit.swift`:
```swift
// BridgeKit — Bridge Document schema, mapping, and validation.
```

- [ ] **Step 3: Write the smoke test**

`Tests/BridgeKitTests/SmokeTests.swift`:
```swift
import XCTest
@testable import BridgeKit

final class SmokeTests: XCTestCase {
    func testPackageBuilds() {
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 4: Resolve and build**

Run: `swift package resolve && swift build`
Expected: resolves `FHIRModels` and `swift-argument-parser`, builds with no errors. If `from: "0.5.0"` fails to resolve, run `swift package resolve` after changing to the latest tag shown by the resolver error, and record the pinned version in `Package.resolved`.

- [ ] **Step 5: Run the smoke test**

Run: `swift test --filter BridgeKitTests.SmokeTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```
git add Package.swift Package.resolved Sources Tests
git commit -m "chore: scaffold SwiftPM package with BridgeKit, HealthBridgeParsing, healthbridge targets"
```

---

## Task 2: Bridge Document schema + deterministic JSON

**Files:**
- Create: `Sources/BridgeKit/BridgeDocument.swift`
- Create: `Sources/BridgeKit/Observation.swift`
- Create: `Sources/BridgeKit/HealthKitMapping.swift`
- Create: `Sources/BridgeKit/BridgeJSON.swift`
- Delete: `Sources/BridgeKit/BridgeKit.swift` (placeholder no longer needed)
- Test: `Tests/BridgeKitTests/BridgeDocumentCodingTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct BridgeDocument` with `schemaVersion: Int, source: Source, subject: Subject?, observations: [Observation]`.
  - `struct Source { var kind: SourceKind; var fileName: String; var sha256: String; var extractedAt: Date; var extractor: Extractor }`.
  - `enum SourceKind: String { case fhir, ccda, pdf }`.
  - `struct Extractor { var engine: String; var version: String }`.
  - `struct Subject { var name: String?; var dob: Date? }`.
  - `struct Observation { var id: String; var code: CodeableRef?; var name: String; var value: ObservationValue; var unit: String?; var effectiveDate: Date; var category: ObservationCategory; var mapping: HealthKitMapping?; var confidence: Double; var sourceLocator: SourceLocator? }`.
  - `enum ObservationValue: Equatable { case quantity(Double); case string(String) }` with custom `Codable` encoding `{ "type": "quantity"|"string", "value": ... }`.
  - `enum ObservationCategory: String { case vital, lab, other }`.
  - `struct CodeableRef { var system: String; var code: String; var display: String }`.
  - `struct SourceLocator { var page: Int?; var snippet: String? }`.
  - `struct HealthKitMapping { var quantityType: String; var canonicalUnit: String; var convertedValue: Double }`.
  - `enum BridgeJSON { static let encoder: JSONEncoder; static let decoder: JSONDecoder }`.

- [ ] **Step 1: Write failing coding test**

`Tests/BridgeKitTests/BridgeDocumentCodingTests.swift`:
```swift
import XCTest
@testable import BridgeKit

final class BridgeDocumentCodingTests: XCTestCase {
    private func sampleDocument() -> BridgeDocument {
        let obs = Observation(
            id: "abc123",
            code: CodeableRef(system: "http://loinc.org", code: "29463-7", display: "Body weight"),
            name: "Body weight",
            value: .quantity(72.5),
            unit: "kg",
            effectiveDate: Date(timeIntervalSince1970: 1_700_000_000),
            category: .vital,
            mapping: HealthKitMapping(quantityType: "HKQuantityTypeIdentifierBodyMass",
                                      canonicalUnit: "kg", convertedValue: 72.5),
            confidence: 1.0,
            sourceLocator: nil
        )
        return BridgeDocument(
            schemaVersion: 1,
            source: Source(kind: .fhir, fileName: "x.json", sha256: "deadbeef",
                           extractedAt: Date(timeIntervalSince1970: 1_700_000_000),
                           extractor: Extractor(engine: "fhir-parser", version: "0.1.0")),
            subject: nil,
            observations: [obs]
        )
    }

    func testRoundTrip() throws {
        let original = sampleDocument()
        let data = try BridgeJSON.encoder.encode(original)
        let decoded = try BridgeJSON.decoder.decode(BridgeDocument.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testObservationValueEncodesTagged() throws {
        let data = try BridgeJSON.encoder.encode(ObservationValue.quantity(72.5))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"type\" : \"quantity\""))
        XCTAssertTrue(json.contains("\"value\" : 72.5"))
    }

    func testDeterministicSortedKeys() throws {
        let data = try BridgeJSON.encoder.encode(sampleDocument())
        let json = String(decoding: data, as: UTF8.self)
        // sortedKeys: "category" must appear before "confidence" within an observation
        let cat = json.range(of: "\"category\"")!
        let conf = json.range(of: "\"confidence\"")!
        XCTAssertTrue(cat.lowerBound < conf.lowerBound)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter BridgeDocumentCodingTests`
Expected: FAIL — types `BridgeDocument`, `Observation`, `BridgeJSON`, etc. not defined.

- [ ] **Step 3: Implement the schema types**

`Sources/BridgeKit/HealthKitMapping.swift`:
```swift
import Foundation

public struct HealthKitMapping: Codable, Equatable, Sendable {
    public var quantityType: String
    public var canonicalUnit: String
    public var convertedValue: Double

    public init(quantityType: String, canonicalUnit: String, convertedValue: Double) {
        self.quantityType = quantityType
        self.canonicalUnit = canonicalUnit
        self.convertedValue = convertedValue
    }
}
```

`Sources/BridgeKit/Observation.swift`:
```swift
import Foundation

public struct CodeableRef: Codable, Equatable, Sendable {
    public var system: String
    public var code: String
    public var display: String
    public init(system: String, code: String, display: String) {
        self.system = system; self.code = code; self.display = display
    }
}

public enum ObservationCategory: String, Codable, Sendable {
    case vital, lab, other
}

public struct SourceLocator: Codable, Equatable, Sendable {
    public var page: Int?
    public var snippet: String?
    public init(page: Int? = nil, snippet: String? = nil) {
        self.page = page; self.snippet = snippet
    }
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
        case .quantity(let d):
            try c.encode(Kind.quantity, forKey: .type)
            try c.encode(d, forKey: .value)
        case .string(let s):
            try c.encode(Kind.string, forKey: .type)
            try c.encode(s, forKey: .value)
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

    public init(id: String, code: CodeableRef?, name: String, value: ObservationValue,
                unit: String?, effectiveDate: Date, category: ObservationCategory,
                mapping: HealthKitMapping?, confidence: Double, sourceLocator: SourceLocator?) {
        self.id = id; self.code = code; self.name = name; self.value = value
        self.unit = unit; self.effectiveDate = effectiveDate; self.category = category
        self.mapping = mapping; self.confidence = confidence; self.sourceLocator = sourceLocator
    }
}
```

`Sources/BridgeKit/BridgeDocument.swift`:
```swift
import Foundation

public enum SourceKind: String, Codable, Sendable { case fhir, ccda, pdf }

public struct Extractor: Codable, Equatable, Sendable {
    public var engine: String
    public var version: String
    public init(engine: String, version: String) { self.engine = engine; self.version = version }
}

public struct Source: Codable, Equatable, Sendable {
    public var kind: SourceKind
    public var fileName: String
    public var sha256: String
    public var extractedAt: Date
    public var extractor: Extractor
    public init(kind: SourceKind, fileName: String, sha256: String, extractedAt: Date, extractor: Extractor) {
        self.kind = kind; self.fileName = fileName; self.sha256 = sha256
        self.extractedAt = extractedAt; self.extractor = extractor
    }
}

public struct Subject: Codable, Equatable, Sendable {
    public var name: String?
    public var dob: Date?
    public init(name: String? = nil, dob: Date? = nil) { self.name = name; self.dob = dob }
}

public struct BridgeDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var source: Source
    public var subject: Subject?
    public var observations: [Observation]
    public init(schemaVersion: Int, source: Source, subject: Subject?, observations: [Observation]) {
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

Then delete the placeholder: `rm Sources/BridgeKit/BridgeKit.swift`.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter BridgeDocumentCodingTests`
Expected: all three tests PASS.

- [ ] **Step 5: Commit**

```
git add Sources/BridgeKit Tests/BridgeKitTests/BridgeDocumentCodingTests.swift
git commit -m "feat(bridgekit): Bridge Document schema with deterministic JSON encoding"
```

---

## Task 3: Stable observation ID derivation

**Files:**
- Create: `Sources/BridgeKit/ObservationID.swift`
- Test: `Tests/BridgeKitTests/ObservationIDTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum ObservationID { static func derive(documentKey: String, system: String?, code: String?, effectiveDate: Date, rawValue: String, unit: String?) -> String }` — returns a lowercase hex SHA-256 string. `documentKey` is the source `sha256` (or a stable patient+doc key). `rawValue` is the observation value rendered as a stable string (e.g. `"72.5"` or the qualitative string).

- [ ] **Step 1: Write failing test**

`Tests/BridgeKitTests/ObservationIDTests.swift`:
```swift
import XCTest
@testable import BridgeKit

final class ObservationIDTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    func testDeterministic() {
        let a = ObservationID.derive(documentKey: "doc1", system: "http://loinc.org",
                                     code: "29463-7", effectiveDate: date, rawValue: "72.5", unit: "kg")
        let b = ObservationID.derive(documentKey: "doc1", system: "http://loinc.org",
                                     code: "29463-7", effectiveDate: date, rawValue: "72.5", unit: "kg")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64) // SHA-256 hex
    }

    func testValueChangesID() {
        let a = ObservationID.derive(documentKey: "doc1", system: "http://loinc.org",
                                     code: "29463-7", effectiveDate: date, rawValue: "72.5", unit: "kg")
        let b = ObservationID.derive(documentKey: "doc1", system: "http://loinc.org",
                                     code: "29463-7", effectiveDate: date, rawValue: "73.0", unit: "kg")
        XCTAssertNotEqual(a, b)
    }

    func testDocumentKeyChangesID() {
        let a = ObservationID.derive(documentKey: "doc1", system: nil, code: nil,
                                     effectiveDate: date, rawValue: "positive", unit: nil)
        let b = ObservationID.derive(documentKey: "doc2", system: nil, code: nil,
                                     effectiveDate: date, rawValue: "positive", unit: nil)
        XCTAssertNotEqual(a, b)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ObservationIDTests`
Expected: FAIL — `ObservationID` not defined.

- [ ] **Step 3: Implement**

`Sources/BridgeKit/ObservationID.swift`:
```swift
import Foundation
import CryptoKit

public enum ObservationID {
    public static func derive(documentKey: String, system: String?, code: String?,
                              effectiveDate: Date, rawValue: String, unit: String?) -> String {
        // Stable, unambiguous field separator avoids collisions between adjacent fields.
        let parts = [
            documentKey,
            system ?? "",
            code ?? "",
            String(Int(effectiveDate.timeIntervalSince1970.rounded())),
            rawValue,
            unit ?? "",
        ]
        let joined = parts.joined(separator: "\u{1f}") // ASCII Unit Separator
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter ObservationIDTests`
Expected: all three PASS.

- [ ] **Step 5: Commit**

```
git add Sources/BridgeKit/ObservationID.swift Tests/BridgeKitTests/ObservationIDTests.swift
git commit -m "feat(bridgekit): deterministic SHA-256 observation ID derivation"
```

---

## Task 4: LOINC→HealthKit mapping table + unit conversion

**Files:**
- Create: `Sources/BridgeKit/MappingTable.swift`
- Test: `Tests/BridgeKitTests/MappingTableTests.swift`

**Interfaces:**
- Consumes: `Observation`, `HealthKitMapping`, `ObservationValue` from Task 2.
- Produces: `enum MappingTable { static func resolve(loinc: String?, value: ObservationValue, unit: String?) -> HealthKitMapping? }`. Returns `nil` when the LOINC code is unknown, the value is not a `.quantity`, or the unit cannot be converted to the entry's canonical unit.

- [ ] **Step 1: Write failing test**

`Tests/BridgeKitTests/MappingTableTests.swift`:
```swift
import XCTest
@testable import BridgeKit

final class MappingTableTests: XCTestCase {
    func testMapsBodyWeightKilograms() {
        let m = MappingTable.resolve(loinc: "29463-7", value: .quantity(72.5), unit: "kg")
        XCTAssertEqual(m?.quantityType, "HKQuantityTypeIdentifierBodyMass")
        XCTAssertEqual(m?.canonicalUnit, "kg")
        XCTAssertEqual(m?.convertedValue ?? 0, 72.5, accuracy: 0.0001)
    }

    func testConvertsPoundsToKilograms() {
        let m = MappingTable.resolve(loinc: "29463-7", value: .quantity(160), unit: "[lb_av]")
        XCTAssertEqual(m?.canonicalUnit, "kg")
        XCTAssertEqual(m?.convertedValue ?? 0, 72.5747, accuracy: 0.01)
    }

    func testConvertsFahrenheitToCelsius() {
        let m = MappingTable.resolve(loinc: "8310-5", value: .quantity(98.6), unit: "[degF]")
        XCTAssertEqual(m?.quantityType, "HKQuantityTypeIdentifierBodyTemperature")
        XCTAssertEqual(m?.canonicalUnit, "degC")
        XCTAssertEqual(m?.convertedValue ?? 0, 37.0, accuracy: 0.05)
    }

    func testUnknownLoincReturnsNil() {
        XCTAssertNil(MappingTable.resolve(loinc: "1234-5", value: .quantity(1), unit: "g"))
    }

    func testNonQuantityReturnsNil() {
        XCTAssertNil(MappingTable.resolve(loinc: "29463-7", value: .string("positive"), unit: nil))
    }

    func testUnconvertibleUnitReturnsNil() {
        XCTAssertNil(MappingTable.resolve(loinc: "29463-7", value: .quantity(1), unit: "banana"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter MappingTableTests`
Expected: FAIL — `MappingTable` not defined.

- [ ] **Step 3: Implement**

`Sources/BridgeKit/MappingTable.swift`:
```swift
import Foundation

/// One row of the LOINC -> HealthKit mapping. `convert` turns a source value in
/// `sourceUnit` into the canonical unit, returning nil when the unit is unsupported.
struct MappingEntry {
    let loinc: String
    let quantityType: String
    let canonicalUnit: String
    let convert: (Double, String?) -> Double?
}

public enum MappingTable {

    public static func resolve(loinc: String?, value: ObservationValue, unit: String?) -> HealthKitMapping? {
        guard let loinc, case .quantity(let raw) = value, let entry = table[loinc] else { return nil }
        guard let converted = entry.convert(raw, unit) else { return nil }
        return HealthKitMapping(quantityType: entry.quantityType,
                                canonicalUnit: entry.canonicalUnit,
                                convertedValue: converted)
    }

    // MARK: - Unit converters (UCUM source units -> canonical unit)

    /// Identity converter accepting a set of synonym units (all already canonical).
    private static func passthrough(_ accepted: Set<String>) -> (Double, String?) -> Double? {
        { v, u in (u == nil || accepted.contains(u!)) ? v : nil }
    }

    private static let mass: (Double, String?) -> Double? = { v, u in
        switch u {
        case "kg", nil: return v
        case "g":       return v / 1000.0
        case "[lb_av]", "lb": return v * 0.45359237
        default: return nil
        }
    }

    private static let length: (Double, String?) -> Double? = { v, u in
        switch u {
        case "cm", nil: return v
        case "m":       return v * 100.0
        case "[in_i]", "in": return v * 2.54
        default: return nil
        }
    }

    private static let temperature: (Double, String?) -> Double? = { v, u in
        switch u {
        case "Cel", "degC", nil: return v
        case "[degF]", "degF":   return (v - 32.0) * 5.0 / 9.0
        default: return nil
        }
    }

    // MARK: - The table

    private static let table: [String: MappingEntry] = {
        let entries: [MappingEntry] = [
            MappingEntry(loinc: "29463-7", quantityType: "HKQuantityTypeIdentifierBodyMass",
                         canonicalUnit: "kg", convert: mass),
            MappingEntry(loinc: "8302-2", quantityType: "HKQuantityTypeIdentifierHeight",
                         canonicalUnit: "cm", convert: length),
            MappingEntry(loinc: "8310-5", quantityType: "HKQuantityTypeIdentifierBodyTemperature",
                         canonicalUnit: "degC", convert: temperature),
            MappingEntry(loinc: "39156-5", quantityType: "HKQuantityTypeIdentifierBodyMassIndex",
                         canonicalUnit: "kg/m2", convert: passthrough(["kg/m2"])),
            MappingEntry(loinc: "8867-4", quantityType: "HKQuantityTypeIdentifierHeartRate",
                         canonicalUnit: "count/min", convert: passthrough(["/min", "count/min", "{beats}/min"])),
            MappingEntry(loinc: "9279-1", quantityType: "HKQuantityTypeIdentifierRespiratoryRate",
                         canonicalUnit: "count/min", convert: passthrough(["/min", "count/min", "{breaths}/min"])),
            MappingEntry(loinc: "2708-6", quantityType: "HKQuantityTypeIdentifierOxygenSaturation",
                         canonicalUnit: "%", convert: passthrough(["%"])),
            MappingEntry(loinc: "8480-6", quantityType: "HKQuantityTypeIdentifierBloodPressureSystolic",
                         canonicalUnit: "mmHg", convert: passthrough(["mm[Hg]", "mmHg"])),
            MappingEntry(loinc: "8462-4", quantityType: "HKQuantityTypeIdentifierBloodPressureDiastolic",
                         canonicalUnit: "mmHg", convert: passthrough(["mm[Hg]", "mmHg"])),
            MappingEntry(loinc: "2339-0", quantityType: "HKQuantityTypeIdentifierBloodGlucose",
                         canonicalUnit: "mg/dL", convert: { v, u in
                             switch u {
                             case "mg/dL", "mg/dl", nil: return v
                             case "mmol/L", "mmol/l":   return v * 18.0182
                             default: return nil
                             }
                         }),
        ]
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.loinc, $0) })
    }()
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter MappingTableTests`
Expected: all six PASS.

- [ ] **Step 5: Commit**

```
git add Sources/BridgeKit/MappingTable.swift Tests/BridgeKitTests/MappingTableTests.swift
git commit -m "feat(bridgekit): LOINC to HealthKit mapping table with unit conversion"
```

---

## Task 5: Bridge Document validation

**Files:**
- Create: `Sources/BridgeKit/Validation.swift`
- Test: `Tests/BridgeKitTests/ValidationTests.swift`

**Interfaces:**
- Consumes: `BridgeDocument`, `Observation` from Task 2.
- Produces: `struct ValidationIssue { let severity: Severity; let message: String }` with `enum Severity { case error, warning }`, and `func validate(_ document: BridgeDocument) -> [ValidationIssue]` (free function in `BridgeKit`). Rules: schemaVersion must equal current → error; empty `source.sha256` → error; duplicate observation ids → error; any observation with `confidence` outside `0...1` → error; an observation whose `mapping != nil` but `value` is `.string` → error; zero observations → warning.

- [ ] **Step 1: Write failing test**

`Tests/BridgeKitTests/ValidationTests.swift`:
```swift
import XCTest
@testable import BridgeKit

final class ValidationTests: XCTestCase {
    private func makeDoc(observations: [Observation], schemaVersion: Int = 1,
                         sha256: String = "abc") -> BridgeDocument {
        BridgeDocument(
            schemaVersion: schemaVersion,
            source: Source(kind: .fhir, fileName: "f.json", sha256: sha256,
                           extractedAt: Date(timeIntervalSince1970: 0),
                           extractor: Extractor(engine: "fhir-parser", version: "0.1.0")),
            subject: nil, observations: observations)
    }

    private func obs(id: String, value: ObservationValue = .quantity(1),
                     mapping: HealthKitMapping? = nil, confidence: Double = 1.0) -> Observation {
        Observation(id: id, code: nil, name: "x", value: value, unit: "kg",
                    effectiveDate: Date(timeIntervalSince1970: 0), category: .vital,
                    mapping: mapping, confidence: confidence, sourceLocator: nil)
    }

    func testValidDocumentHasNoErrors() {
        let issues = validate(makeDoc(observations: [obs(id: "a")]))
        XCTAssertFalse(issues.contains { $0.severity == .error })
    }

    func testWrongSchemaVersionIsError() {
        let issues = validate(makeDoc(observations: [obs(id: "a")], schemaVersion: 99))
        XCTAssertTrue(issues.contains { $0.severity == .error })
    }

    func testDuplicateIDsAreError() {
        let issues = validate(makeDoc(observations: [obs(id: "a"), obs(id: "a")]))
        XCTAssertTrue(issues.contains { $0.severity == .error && $0.message.contains("duplicate") })
    }

    func testMappingOnStringValueIsError() {
        let bad = obs(id: "a", value: .string("positive"),
                      mapping: HealthKitMapping(quantityType: "X", canonicalUnit: "kg", convertedValue: 1))
        let issues = validate(makeDoc(observations: [bad]))
        XCTAssertTrue(issues.contains { $0.severity == .error })
    }

    func testEmptyObservationsIsWarning() {
        let issues = validate(makeDoc(observations: []))
        XCTAssertTrue(issues.contains { $0.severity == .warning })
        XCTAssertFalse(issues.contains { $0.severity == .error })
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ValidationTests`
Expected: FAIL — `validate` / `ValidationIssue` not defined.

- [ ] **Step 3: Implement**

`Sources/BridgeKit/Validation.swift`:
```swift
import Foundation

public struct ValidationIssue: Equatable, Sendable {
    public enum Severity: Sendable { case error, warning }
    public let severity: Severity
    public let message: String
    public init(severity: Severity, message: String) {
        self.severity = severity; self.message = message
    }
}

public func validate(_ document: BridgeDocument) -> [ValidationIssue] {
    var issues: [ValidationIssue] = []

    if document.schemaVersion != BridgeDocument.currentSchemaVersion {
        issues.append(.init(severity: .error,
            message: "schemaVersion \(document.schemaVersion) != \(BridgeDocument.currentSchemaVersion)"))
    }
    if document.source.sha256.isEmpty {
        issues.append(.init(severity: .error, message: "source.sha256 is empty"))
    }
    if document.observations.isEmpty {
        issues.append(.init(severity: .warning, message: "document has zero observations"))
    }

    var seen = Set<String>()
    for o in document.observations {
        if !seen.insert(o.id).inserted {
            issues.append(.init(severity: .error, message: "duplicate observation id: \(o.id)"))
        }
        if !(0.0...1.0).contains(o.confidence) {
            issues.append(.init(severity: .error, message: "confidence out of range for \(o.id)"))
        }
        if o.mapping != nil, case .string = o.value {
            issues.append(.init(severity: .error, message: "string-valued observation \(o.id) cannot carry a HealthKit mapping"))
        }
    }
    return issues
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter ValidationTests`
Expected: all five PASS.

- [ ] **Step 5: Run the full BridgeKit suite**

Run: `swift test --filter BridgeKitTests`
Expected: every BridgeKit test PASSES.

- [ ] **Step 6: Commit**

```
git add Sources/BridgeKit/Validation.swift Tests/BridgeKitTests/ValidationTests.swift
git commit -m "feat(bridgekit): Bridge Document validation rules"
```

---

## Task 6: DocumentParser protocol

**Files:**
- Create: `Sources/HealthBridgeParsing/DocumentParser.swift`
- Delete: `Sources/HealthBridgeParsing/Placeholder.swift`
- Test: `Tests/HealthBridgeParsingTests/DocumentParserTests.swift`

**Interfaces:**
- Consumes: `Observation` from `BridgeKit`.
- Produces:
  - `protocol DocumentParser { static func canParse(_ data: Data) -> Bool; func parse(_ data: Data, documentKey: String) throws -> [Observation] }`.
  - `enum ParseError: Error, Equatable { case unrecognizedFormat; case malformed(String) }`.
  - `documentKey` is the source `sha256`, threaded in so `ObservationID.derive` produces stable ids.

- [ ] **Step 1: Write failing test**

`Tests/HealthBridgeParsingTests/DocumentParserTests.swift`:
```swift
import XCTest
import BridgeKit
@testable import HealthBridgeParsing

private struct StubParser: DocumentParser {
    static func canParse(_ data: Data) -> Bool { !data.isEmpty }
    func parse(_ data: Data, documentKey: String) throws -> [Observation] {
        guard !data.isEmpty else { throw ParseError.malformed("empty") }
        return []
    }
}

final class DocumentParserTests: XCTestCase {
    func testCanParseReflectsContent() {
        XCTAssertTrue(StubParser.canParse(Data([0x7b])))
        XCTAssertFalse(StubParser.canParse(Data()))
    }

    func testParseThrowsOnEmpty() {
        XCTAssertThrowsError(try StubParser().parse(Data(), documentKey: "k")) { error in
            XCTAssertEqual(error as? ParseError, .malformed("empty"))
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter DocumentParserTests`
Expected: FAIL — `DocumentParser` / `ParseError` not defined.

- [ ] **Step 3: Implement**

`Sources/HealthBridgeParsing/DocumentParser.swift`:
```swift
import Foundation
import BridgeKit

public enum ParseError: Error, Equatable {
    case unrecognizedFormat
    case malformed(String)
}

public protocol DocumentParser {
    static func canParse(_ data: Data) -> Bool
    func parse(_ data: Data, documentKey: String) throws -> [Observation]
}
```

Then delete the placeholder: `rm Sources/HealthBridgeParsing/Placeholder.swift`.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter DocumentParserTests`
Expected: both PASS.

- [ ] **Step 5: Commit**

```
git add Sources/HealthBridgeParsing/DocumentParser.swift Tests/HealthBridgeParsingTests/DocumentParserTests.swift
git rm Sources/HealthBridgeParsing/Placeholder.swift
git commit -m "feat(parsing): DocumentParser protocol and ParseError"
```

---

## Task 7: FHIR R4 parser

**Files:**
- Create: `Sources/HealthBridgeParsing/FHIRParser.swift`
- Create: `Tests/HealthBridgeParsingTests/Fixtures/observation-bodyweight.json`
- Create: `Tests/HealthBridgeParsingTests/Fixtures/bundle-vitals-and-labs.json`
- Test: `Tests/HealthBridgeParsingTests/FHIRParserTests.swift`

**Interfaces:**
- Consumes: `DocumentParser`, `ParseError` (Task 6); `Observation`, `CodeableRef`, `ObservationValue`, `ObservationCategory`, `ObservationID`, `MappingTable` (BridgeKit); `ModelsR4`.
- Produces: `struct FHIRParser: DocumentParser`. Accepts either a single `Observation` resource or a `Bundle` of them. Each parsed observation has `confidence = 1.0`, raw `code`/`value`/`unit`/`effectiveDate`/`category` populated, and `mapping` left `nil` (the CLI resolves mapping in Task 8 — keeps the parser's single responsibility "FHIR → raw observations").

- [ ] **Step 1: Create the test fixtures**

`Tests/HealthBridgeParsingTests/Fixtures/observation-bodyweight.json`:
```json
{
  "resourceType": "Observation",
  "id": "bw1",
  "status": "final",
  "category": [
    { "coding": [ { "system": "http://terminology.hl7.org/CodeSystem/observation-category", "code": "vital-signs" } ] }
  ],
  "code": {
    "coding": [ { "system": "http://loinc.org", "code": "29463-7", "display": "Body weight" } ],
    "text": "Body weight"
  },
  "effectiveDateTime": "2025-03-19T09:30:00-04:00",
  "valueQuantity": { "value": 72.5, "unit": "kg", "system": "http://unitsofmeasure.org", "code": "kg" }
}
```

`Tests/HealthBridgeParsingTests/Fixtures/bundle-vitals-and-labs.json`:
```json
{
  "resourceType": "Bundle",
  "type": "collection",
  "entry": [
    {
      "resource": {
        "resourceType": "Observation",
        "id": "bw1",
        "status": "final",
        "category": [ { "coding": [ { "system": "http://terminology.hl7.org/CodeSystem/observation-category", "code": "vital-signs" } ] } ],
        "code": { "coding": [ { "system": "http://loinc.org", "code": "29463-7", "display": "Body weight" } ] },
        "effectiveDateTime": "2025-03-19T09:30:00-04:00",
        "valueQuantity": { "value": 72.5, "unit": "kg", "system": "http://unitsofmeasure.org", "code": "kg" }
      }
    },
    {
      "resource": {
        "resourceType": "Observation",
        "id": "alt1",
        "status": "final",
        "category": [ { "coding": [ { "system": "http://terminology.hl7.org/CodeSystem/observation-category", "code": "laboratory" } ] } ],
        "code": { "coding": [ { "system": "http://loinc.org", "code": "1742-6", "display": "ALT SerPl-cCnc" } ] },
        "effectiveDateTime": "2025-03-19T09:30:00-04:00",
        "valueQuantity": { "value": 22, "unit": "U/L", "system": "http://unitsofmeasure.org", "code": "U/L" }
      }
    }
  ]
}
```

- [ ] **Step 2: Write the failing test**

`Tests/HealthBridgeParsingTests/FHIRParserTests.swift`:
```swift
import XCTest
import BridgeKit
@testable import HealthBridgeParsing

final class FHIRParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")
        return try Data(contentsOf: try XCTUnwrap(url))
    }

    func testCanParseDetectsFHIR() throws {
        XCTAssertTrue(FHIRParser.canParse(try fixture("observation-bodyweight")))
        XCTAssertFalse(FHIRParser.canParse(Data("<ClinicalDocument/>".utf8)))
    }

    func testParsesSingleObservation() throws {
        let obs = try FHIRParser().parse(try fixture("observation-bodyweight"), documentKey: "doc1")
        XCTAssertEqual(obs.count, 1)
        let o = try XCTUnwrap(obs.first)
        XCTAssertEqual(o.code?.code, "29463-7")
        XCTAssertEqual(o.code?.system, "http://loinc.org")
        XCTAssertEqual(o.name, "Body weight")
        XCTAssertEqual(o.value, .quantity(72.5))
        XCTAssertEqual(o.unit, "kg")
        XCTAssertEqual(o.category, .vital)
        XCTAssertEqual(o.confidence, 1.0)
        XCTAssertNil(o.mapping) // parser does not resolve mapping
        // 2025-03-19T09:30:00-04:00 == 1742391000 epoch
        XCTAssertEqual(o.effectiveDate.timeIntervalSince1970, 1_742_391_000, accuracy: 1)
    }

    func testParsesBundleWithVitalAndLab() throws {
        let obs = try FHIRParser().parse(try fixture("bundle-vitals-and-labs"), documentKey: "doc1")
        XCTAssertEqual(obs.count, 2)
        XCTAssertEqual(obs.first?.category, .vital)
        XCTAssertEqual(obs.last?.category, .lab)
        XCTAssertEqual(obs.last?.code?.code, "1742-6")
    }

    func testStableIDsAcrossRuns() throws {
        let a = try FHIRParser().parse(try fixture("observation-bodyweight"), documentKey: "doc1")
        let b = try FHIRParser().parse(try fixture("observation-bodyweight"), documentKey: "doc1")
        XCTAssertEqual(a.first?.id, b.first?.id)
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try FHIRParser().parse(Data("{ not json".utf8), documentKey: "k"))
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `swift test --filter FHIRParserTests`
Expected: FAIL — `FHIRParser` not defined.

- [ ] **Step 4: Implement**

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

    public func parse(_ data: Data, documentKey: String) throws -> [Observation] {
        let decoder = JSONDecoder()
        let fhirObservations = try decodeObservations(data, decoder: decoder)
        return fhirObservations.compactMap { convert($0, documentKey: documentKey) }
    }

    // MARK: - Decoding

    private func decodeObservations(_ data: Data, decoder: JSONDecoder) throws -> [ModelsR4.Observation] {
        // Try a Bundle first, then a bare Observation.
        if let bundle = try? decoder.decode(ModelsR4.Bundle.self, from: data) {
            return bundle.entry?.compactMap { $0.resource?.get(if: ModelsR4.Observation.self) } ?? []
        }
        do {
            let single = try decoder.decode(ModelsR4.Observation.self, from: data)
            return [single]
        } catch {
            throw ParseError.malformed("not a FHIR Bundle or Observation: \(error)")
        }
    }

    // MARK: - Conversion (returns nil for observations we cannot represent)

    private func convert(_ o: ModelsR4.Observation, documentKey: String) -> Observation? {
        guard let coding = loincCoding(o.code),
              let effective = effectiveDate(o.effective) else { return nil }

        let code = coding.code?.value?.string
        let system = coding.system?.value?.url.absoluteString
        let display = coding.display?.value?.string
            ?? o.code.text?.value?.string
            ?? code
            ?? "Unknown"

        guard let (value, unit, rawString) = observationValue(o.value) else { return nil }

        let id = ObservationID.derive(documentKey: documentKey, system: system, code: code,
                                      effectiveDate: effective, rawValue: rawString, unit: unit)

        return Observation(
            id: id,
            code: (system != nil && code != nil) ? CodeableRef(system: system!, code: code!, display: display) : nil,
            name: display,
            value: value,
            unit: unit,
            effectiveDate: effective,
            category: category(o.category),
            mapping: nil,
            confidence: 1.0,
            sourceLocator: nil
        )
    }

    private func loincCoding(_ code: CodeableConcept) -> Coding? {
        let codings = code.coding ?? []
        return codings.first { $0.system?.value?.url.absoluteString == "http://loinc.org" }
            ?? codings.first
    }

    private func observationValue(_ value: Observation.ValueX?) -> (ObservationValue, String?, String)? {
        switch value {
        case .quantity(let q):
            guard let decimal = q.value?.value?.decimal else { return nil }
            let d = NSDecimalNumber(decimal: decimal).doubleValue
            let unit = q.code?.value?.string ?? q.unit?.value?.string
            return (.quantity(d), unit, stableNumberString(d))
        case .string(let s):
            guard let str = s.value?.string else { return nil }
            return (.string(str), nil, str)
        default:
            return nil
        }
    }

    private func effectiveDate(_ effective: Observation.EffectiveX?) -> Date? {
        switch effective {
        case .dateTime(let dt):
            return try? dt.value?.asNSDate()
        case .instant(let inst):
            return try? inst.value?.asNSDate()
        case .period(let p):
            if let start = p.start?.value { return try? start.asNSDate() }
            return nil
        default:
            return nil
        }
    }

    private func category(_ categories: [CodeableConcept]?) -> ObservationCategory {
        let codes = (categories ?? []).flatMap { $0.coding ?? [] }
            .compactMap { $0.code?.value?.string }
        if codes.contains("vital-signs") { return .vital }
        if codes.contains("laboratory") { return .lab }
        return .other
    }

    /// Render a Double without locale or trailing-zero noise so ids stay stable.
    private func stableNumberString(_ d: Double) -> String {
        if d == d.rounded() { return String(Int(d)) }
        return String(format: "%g", d)
    }
}
```

> Implementation notes for the executor:
> - `Observation.ValueX` and `Observation.EffectiveX` are the `ModelsR4` `value[x]` / `effective[x]` enums. If the exact case names differ in the resolved `FHIRModels` version (e.g. `.dateTime` vs `.fhirDateTime`), let the failing test guide the fix — the cases are discoverable via Xcode autocomplete or `swift build` diagnostics.
> - `asNSDate()` is `FHIRModels`' documented `DateTime`/`Instant`/`DateOnly` → `Foundation.Date` conversion. If it is spelled differently in the pinned version, adjust `effectiveDate(_:)` accordingly; the `testParsesSingleObservation` epoch assertion verifies correctness.

- [ ] **Step 5: Run to verify pass**

Run: `swift test --filter FHIRParserTests`
Expected: all five PASS. If a `ModelsR4` enum case name or `asNSDate()` spelling differs, fix per the implementation notes and re-run until green.

- [ ] **Step 6: Commit**

```
git add Sources/HealthBridgeParsing/FHIRParser.swift Tests/HealthBridgeParsingTests
git commit -m "feat(parsing): FHIR R4 JSON parser for Observation and Bundle resources"
```

---

## Task 8: healthbridge CLI

**Files:**
- Create: `Sources/healthbridge/HealthBridge.swift`
- Delete: `Sources/healthbridge/Placeholder.swift`
- Create: `Tests/healthbridgeTests/Fixtures/bundle-vitals-and-labs.json` (copy of the Task 7 fixture)
- Test: `Tests/healthbridgeTests/CLIIntegrationTests.swift`

**Interfaces:**
- Consumes: `FHIRParser`, `DocumentParser`, `ParseError` (HealthBridgeParsing); `BridgeDocument`, `Source`, `SourceKind`, `Extractor`, `Observation`, `MappingTable`, `BridgeJSON`, `validate`, `ObservationValue` (BridgeKit); `ArgumentParser`; `CryptoKit`.
- Produces: a `healthbridge parse <input> [--out <path>] [--format auto|fhir]` command. Behaviour: read file → compute `sha256` → select parser → `[Observation]` → resolve each observation's `mapping` via `MappingTable` → assemble `BridgeDocument(schemaVersion: 1, …, extractor: Extractor("fhir-parser", "0.1.0"))` → `validate` (abort on any `.error`) → write deterministic JSON to `--out` (default: `<input-basename>.bridge.json`) → print a summary (`N observations, M mapped, K unmapped`) to stderr. Exposes a testable `BridgeBuilder.build(data:fileName:) throws -> BridgeDocument` so the integration test does not shell out.

- [ ] **Step 1: Copy the fixture for the CLI test**

```
cp Tests/HealthBridgeParsingTests/Fixtures/bundle-vitals-and-labs.json Tests/healthbridgeTests/Fixtures/bundle-vitals-and-labs.json
```

- [ ] **Step 2: Write the failing test**

`Tests/healthbridgeTests/CLIIntegrationTests.swift`:
```swift
import XCTest
import BridgeKit
@testable import healthbridge

final class CLIIntegrationTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")
        return try Data(contentsOf: try XCTUnwrap(url))
    }

    func testBuildsValidBridgeDocument() throws {
        let data = try fixture("bundle-vitals-and-labs")
        let doc = try BridgeBuilder.build(data: data, fileName: "bundle-vitals-and-labs.json")

        XCTAssertEqual(doc.schemaVersion, 1)
        XCTAssertEqual(doc.source.kind, .fhir)
        XCTAssertFalse(doc.source.sha256.isEmpty)
        XCTAssertEqual(doc.observations.count, 2)

        // Body weight is mapped; ALT lab is not.
        let weight = try XCTUnwrap(doc.observations.first { $0.code?.code == "29463-7" })
        XCTAssertEqual(weight.mapping?.quantityType, "HKQuantityTypeIdentifierBodyMass")
        let alt = try XCTUnwrap(doc.observations.first { $0.code?.code == "1742-6" })
        XCTAssertNil(alt.mapping)

        // Validation passes (no errors).
        XCTAssertFalse(validate(doc).contains { $0.severity == .error })
    }

    func testBuildIsDeterministic() throws {
        let data = try fixture("bundle-vitals-and-labs")
        let a = try BridgeJSON.encoder.encode(BridgeBuilder.build(data: data, fileName: "f.json"))
        let b = try BridgeJSON.encoder.encode(BridgeBuilder.build(data: data, fileName: "f.json"))
        XCTAssertEqual(a, b)
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `swift test --filter CLIIntegrationTests`
Expected: FAIL — `BridgeBuilder` not defined.

- [ ] **Step 4: Implement the CLI**

`Sources/healthbridge/HealthBridge.swift`:
```swift
import Foundation
import CryptoKit
import ArgumentParser
import BridgeKit
import HealthBridgeParsing

/// Pure-ish assembly step, separated from I/O so it is unit-testable.
public enum BridgeBuilder {
    public static func build(data: Data, fileName: String) throws -> BridgeDocument {
        let sha = sha256Hex(data)

        guard FHIRParser.canParse(data) else { throw ParseError.unrecognizedFormat }
        let raw = try FHIRParser().parse(data, documentKey: sha)

        let resolved = raw.map { o -> Observation in
            var o = o
            o.mapping = MappingTable.resolve(loinc: o.code?.code, value: o.value, unit: o.unit)
            return o
        }

        let doc = BridgeDocument(
            schemaVersion: BridgeDocument.currentSchemaVersion,
            source: Source(kind: .fhir, fileName: fileName, sha256: sha,
                           extractedAt: Date(),
                           extractor: Extractor(engine: "fhir-parser", version: "0.1.0")),
            subject: nil,
            observations: resolved
        )
        return doc
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@main
struct HealthBridge: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "healthbridge",
        abstract: "Parse a medical-record document into a validated Bridge Document.",
        subcommands: [Parse.self]
    )
}

struct Parse: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Parse a FHIR R4 JSON file into *.bridge.json.")

    @Argument(help: "Path to the input FHIR JSON file.")
    var input: String

    @Option(name: .long, help: "Output path (default: <input>.bridge.json).")
    var out: String?

    @Option(name: .long, help: "Input format: auto or fhir.")
    var format: String = "auto"

    func run() throws {
        let inputURL = URL(fileURLWithPath: input)
        let data = try Data(contentsOf: inputURL)

        let doc = try BridgeBuilder.build(data: data, fileName: inputURL.lastPathComponent)

        let issues = validate(doc)
        for issue in issues {
            FileHandle.standardError.write(Data("[\(issue.severity)] \(issue.message)\n".utf8))
        }
        if issues.contains(where: { $0.severity == .error }) {
            throw ValidationFailed()
        }

        let outURL = out.map { URL(fileURLWithPath: $0) }
            ?? inputURL.deletingPathExtension().appendingPathExtension("bridge.json")
        try BridgeJSON.encoder.encode(doc).write(to: outURL)

        let mapped = doc.observations.filter { $0.mapping != nil }.count
        let unmapped = doc.observations.count - mapped
        FileHandle.standardError.write(Data(
            "Wrote \(outURL.lastPathComponent): \(doc.observations.count) observations, \(mapped) mapped, \(unmapped) unmapped.\n".utf8))
    }
}

struct ValidationFailed: Error, CustomStringConvertible {
    var description: String { "Bridge Document failed validation (see errors above)." }
}
```

Then delete the placeholder: `rm Sources/healthbridge/Placeholder.swift`.

- [ ] **Step 5: Run to verify pass**

Run: `swift test --filter CLIIntegrationTests`
Expected: both PASS.

- [ ] **Step 6: Manual end-to-end smoke**

Run:
```
swift run healthbridge parse Tests/healthbridgeTests/Fixtures/bundle-vitals-and-labs.json --out /tmp/out.bridge.json
```
Expected: stderr prints `2 observations, 1 mapped, 1 unmapped`; `/tmp/out.bridge.json` exists and is valid JSON (verify with `swift run healthbridge parse … ` then inspect the file). Clean up `/tmp/out.bridge.json` after.

- [ ] **Step 7: Run the entire suite**

Run: `swift test`
Expected: every test in `BridgeKitTests`, `HealthBridgeParsingTests`, and `healthbridgeTests` PASSES.

- [ ] **Step 8: Commit**

```
git add Sources/healthbridge/HealthBridge.swift Tests/healthbridgeTests
git rm Sources/healthbridge/Placeholder.swift
git commit -m "feat(cli): healthbridge parse command producing validated Bridge Documents"
```

---

## Self-Review (completed by plan author)

**Spec coverage:**
- §2 schema → Task 2 (all types incl. `ObservationValue` enum, deterministic JSON). ✓
- §3 BridgeKit (mapping table, `resolveMapping`, `deriveObservationID`, `validate`, platform-pure no-HealthKit-import) → Tasks 2–5; mapping table strings only, no HealthKit import. ✓
- §4 CLI (`healthbridge parse`, parser abstraction, FHIR R4 JSON via `FHIRModels`, pre-resolve, validate, write, summary) → Tasks 6–8. ✓
- §5 idempotency / stable ids → Task 3 + Task 7 (ids derived during parse). ✓
- §6 testing (BridgeKit units, FHIRParser vs example resources, CLI integration, deterministic output) → Tasks 2–8; no network, no PHI. ✓
- §7 resolved decisions (R4, JSON, FHIRModels, C-CDA→M2) → reflected; no C-CDA parser in this plan. ✓
- §8 out of scope (iOS, HealthKit writes, PDF/LLM, transport, longitudinal merge) → none included. ✓

**Placeholder scan:** No "TBD"/"add error handling"/"similar to" left; every code step shows complete code. The two `FHIRModels` implementation notes point at *real* fallbacks driven by failing tests, not unfinished work.

**Type consistency:** `DocumentParser.parse(_:documentKey:)` signature is identical in Tasks 6, 7, 8. `MappingTable.resolve(loinc:value:unit:)`, `ObservationID.derive(...)`, `BridgeJSON.encoder/decoder`, `validate(_:)`, `BridgeDocument.currentSchemaVersion` are referenced consistently across tasks. `FHIRParser` leaves `mapping = nil`; the CLI (`BridgeBuilder`) is the sole place mapping is resolved — matches the single-responsibility split asserted in Task 7's test (`XCTAssertNil(o.mapping)`).
