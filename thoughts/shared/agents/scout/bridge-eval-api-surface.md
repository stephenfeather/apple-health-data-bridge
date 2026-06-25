# Codebase Report: bridge-eval API Surface
Generated: 2026-06-25
Worktree: `.claude/worktrees/bridgekit-eval`

---

## 1. Package.swift (complete file)

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
        .testTarget(name: "HealthBridgeConfigTests", dependencies: ["HealthBridgeConfig"]),
        .testTarget(
            name: "HealthBridgeParsingTests",
            dependencies: ["HealthBridgeParsing", "BridgeKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "healthbridgeTests",
            dependencies: ["healthbridge", "BridgeKit", "HealthBridgeConfig"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

**Notes for bridge-eval placement:**
- Swift tools version: **5.9**
- Platforms: **macOS(.v13), iOS(.v16)**
- No Crypto dependency anywhere.
- The new `bridge-eval` executableTarget will need at minimum `HealthBridgeParsing`, `BridgeKit`, and `ArgumentParser`. If it needs raw-response logging it must import `healthbridge` sources directly or duplicate `RawResponseLog` — but `RawResponseLog` lives in the `healthbridge` target (not a library), so it cannot be imported by a peer executable. Options: move it to a shared library target, or copy/duplicate the logic.
- Pattern for a new executableTarget:
```swift
.executableTarget(
    name: "bridge-eval",
    dependencies: [
        "HealthBridgeParsing", "HealthBridgeConfig", "BridgeKit",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
    ]
),
```
Add a corresponding test target:
```swift
.testTarget(
    name: "BridgeEvalTests",
    dependencies: ["HealthBridgeParsing", "BridgeKit"],
    resources: [.copy("Fixtures")]
),
```

---

## 2. ExtractionPrompt — `Sources/HealthBridgeParsing/ExtractionPrompt.swift`

```swift
public enum ExtractionPrompt {
    public static func make(pages: [String]) -> String
}
```

**Full signature:** `public static func make(pages: [String]) -> String`

**MISMATCH FLAG — no prompt hash:**
The design expects a prompt hash to be produced/exposed. There is NO hash anywhere in `ExtractionPrompt`. The function returns a plain `String`. No SHA, no hash property, no secondary return value. The hash used by `RawResponseLog.encodeEntry` (`contentSHA256`) is computed separately at the CLI layer (in `healthbridge` sources) from the page data — it is NOT produced by `ExtractionPrompt.make`. The plan must not assume `ExtractionPrompt` yields a hash; that computation must be added at the eval harness layer.

---

## 3. PDFExtractor — `Sources/HealthBridgeParsing/PDFExtractor.swift`

```swift
public struct PDFExtractor {
    private let extractor: any LLMExtractor
    private let model: String

    public init(extractor: any LLMExtractor, model: String)

    /// Cheap `%PDF` magic-byte detection, available on all platforms.
    public static func canParse(_ data: Data) -> Bool

    #if canImport(PDFKit) && os(macOS)
    public func extractDocument(_ data: Data, subjectId: String,
                                subjectDOB: Date? = nil, now: Date = Date()) async throws -> PDFExtraction
    #endif
}

public struct PDFExtraction {
    public let result: ParseResult
    public let extractedPatient: (name: String, dob: String)?
    public let meta: LLMResponseMeta?
    public let rawResponse: String
    public init(result: ParseResult, extractedPatient: (name: String, dob: String)?,
                meta: LLMResponseMeta? = nil, rawResponse: String = "")
}
```

**Internal flow of `extractDocument` (the production tee-off points):**
```swift
let pages = try PDFText.pages(data)                        // → [String]  (throws ParseError)
let prompt = ExtractionPrompt.make(pages: pages)           // → String
let request = LLMRequest(pages: pages, instructions: prompt, model: model)
let raw = try await extractor.extract(request)             // → LLMRawResponse  (throws LLMError)
// multi-patient refusal:
guard try LLMResponseContract.distinctPatientCount(raw.jsonText) <= 1 else { ... }
let patient = try LLMResponseContract.extractedPatient(raw.jsonText)
let result = try LLMResponseContract.decode(raw.jsonText, subjectId: subjectId,
                                            subjectDOB: subjectDOB, now: now)   // → ParseResult
return PDFExtraction(result: result, extractedPatient: patient, meta: raw.meta,
                     rawResponse: raw.jsonText)
```

**MISMATCH FLAG — `#if canImport(PDFKit) && os(macOS)` guard:**
`extractDocument` is only compiled on macOS. A `bridge-eval` executableTarget that runs on macOS is fine, but the plan must note this guard. Any test target for bridge-eval on Linux will not see this method.

---

## 4. LLMExtractor protocol and types — `Sources/HealthBridgeParsing/LLMExtractor.swift`

```swift
public protocol LLMExtractor: Sendable {
    func extract(_ request: LLMRequest) async throws -> LLMRawResponse
}

public struct LLMRequest: Sendable, Equatable {
    public let pages: [String]
    public let instructions: String
    public let model: String
    public init(pages: [String], instructions: String, model: String)
}

public struct LLMResponseMeta: Sendable, Equatable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let stopReason: String?
    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, stopReason: String? = nil)
}

public struct LLMRawResponse: Sendable, Equatable {
    public let jsonText: String
    public let meta: LLMResponseMeta?
    public init(jsonText: String, meta: LLMResponseMeta? = nil)
}

public enum LLMError: Error, Equatable {
    case missingAPIKey
    case transport(String)
    case http(status: Int)
    case malformedResponse(String)
}
```

---

## 5. Extractor initializers — `AnthropicExtractor.swift` and `OpenAIExtractor.swift`

```swift
// AnthropicExtractor
public struct AnthropicExtractor: LLMExtractor {
    public static let anthropicVersion = "2023-06-01"   // public, for eval log stamping

    public init(session: URLSession = .shared, apiKey: String)
}

// OpenAIExtractor
public struct OpenAIExtractor: LLMExtractor {
    public init(session: URLSession = .shared, apiKey: String)
}
```

Both take `apiKey: String` as the only required parameter; `session` defaults to `.shared`.

---

## 6. Document types — `Sources/BridgeKit/Observation.swift` + `Sources/HealthBridgeParsing/DocumentParser.swift`

### From `DocumentParser.swift`

```swift
public enum ParseError: Error, Equatable {
    case unrecognizedFormat
    case malformed(String)
}

public struct Skip: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case noCode, noDate, unrepresentableValue, negated, implausibleDate
    }
    public enum Detail: Equatable, Sendable {
        case bothValueAndText
        case noUsableValue
        case nonFiniteValue
        case confidenceOutOfRange(got: String)
        case dateMalformed
        case dateBeforeDOB
        case dateAfterNow
        case missingCode
    }
    public let reason: Reason
    public let label: String
    public let detail: Detail?
    public init(reason: Reason, label: String, detail: Detail? = nil)
}

public struct ParseResult: Sendable {
    public let observations: [Observation]
    public let skipped: [Skip]
    public init(observations: [Observation], skipped: [Skip])
}

public protocol DocumentParser {
    static func canParse(_ data: Data) -> Bool
    func parse(_ data: Data, subjectId: String) throws -> ParseResult
}
```

### From `Sources/BridgeKit/Observation.swift`

```swift
public struct CodeableRef: Codable, Equatable, Sendable {
    public var system: String
    public var code: String
    public var display: String
    public init(system: String, code: String, display: String)
}

public enum ObservationCategory: String, Codable, Sendable {
    case vital, lab, other
}

public struct SourceLocator: Codable, Equatable, Sendable {
    public var page: Int?
    public var snippet: String?
    public init(page: Int? = nil, snippet: String? = nil)
}

public enum ObservationValue: Equatable, Sendable {
    case quantity(Double)
    case string(String)
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
                confidence: Double, sourceLocator: SourceLocator?)
}
```

### From `Sources/BridgeKit/HealthKitMapping.swift`

```swift
public struct HealthKitMapping: Codable, Equatable, Sendable {
    public var quantityType: String
    public var canonicalUnit: String
    public var convertedValue: Double
    public init(quantityType: String, canonicalUnit: String, convertedValue: Double)
}
```

---

## 7. RawResponseLog — `Sources/healthbridge/RawResponseLog.swift`

**JSONL entry key set** (from `encodeEntry`, always present):
- `timestamp` (String)
- `contentSHA256` (String)
- `provider` (String)
- `model` (String)
- `rawResponse` (String)

Optional keys (omitted when nil/absent):
- `apiVersion` (String)
- `inputTokens` (Int)
- `outputTokens` (Int)
- `stopReason` (String)

Keys are sorted (`.sortedKeys` option) for stable, diff-friendly lines.

**`encodeEntry` signature:**
```swift
static func encodeEntry(timestamp: String, contentSHA256: String, provider: String,
                        model: String, apiVersion: String?, meta: LLMResponseMeta?,
                        rawResponse: String) -> String
```

**`append` signature:**
```swift
static func append(entry: String, to url: URL) throws
```

**ARCHITECTURE FLAG — `RawResponseLog` is in target `healthbridge` (the executable), not a library:**
`bridge-eval` cannot import it directly. The plan must decide: (a) move `RawResponseLog` to a shared internal library target, (b) re-implement equivalent JSONL logging in `bridge-eval`, or (c) depend on the `healthbridge` target (not recommended — executableTargets cannot generally be imported as modules by other targets in SPM without restructuring).

---

## 8. PDFText.pages — `Sources/HealthBridgeParsing/PDFText.swift`

```swift
public enum PDFText {
    public static let maxPages = 30

    public static func isPDF(_ data: Data) -> Bool

    #if canImport(PDFKit) && os(macOS)
    public static func pages(_ data: Data) throws -> [String]
    #endif
}
```

**Full signature:** `public static func pages(_ data: Data) throws -> [String]`
- Throws `ParseError.malformed` for: not a readable PDF, exceeds 30-page limit, no extractable text layer.
- `#if canImport(PDFKit) && os(macOS)` guarded — macOS only.
- `isPDF` is platform-free (pure byte check, always compiled).

---

## 9. Test layout and style reference

### Test target names and directory structure

```
Tests/
├── BridgeKitTests/                  # .testTarget(name: "BridgeKitTests", dependencies: ["BridgeKit"])
│   ├── BridgeDocumentCodingTests.swift
│   ├── MappingTableTests.swift
│   ├── ObservationIDTests.swift
│   ├── SmokeTests.swift
│   ├── SubjectHashTests.swift
│   └── ValidationTests.swift
├── HealthBridgeConfigTests/         # .testTarget(name: "HealthBridgeConfigTests", ...)
│   ├── ConfigWriterTests.swift
│   └── SettingsTests.swift
├── HealthBridgeParsingTests/        # .testTarget(name: "HealthBridgeParsingTests", ..., resources: [.copy("Fixtures")])
│   ├── AnthropicExtractorTests.swift
│   ├── CCDAParserTests.swift
│   ├── ... (many test files)
│   ├── Fixtures/                    # binary/text fixtures; referenced via Bundle.module
│   └── PDFTextTests.swift
└── healthbridgeTests/               # .testTarget(name: "healthbridgeTests", ..., resources: [.copy("Fixtures")])
    ├── BridgeBuilderTests.swift
    ├── CLIRunTests.swift
    ├── Fixtures/
    ├── PDFCLITests.swift
    └── RawResponseLogTests.swift
```

### Style reference — `Tests/HealthBridgeParsingTests/PDFTextTests.swift`

```swift
import XCTest
@testable import HealthBridgeParsing

#if canImport(PDFKit) && os(macOS)
final class PDFTextTests: XCTestCase {
    private func fixture(_ n: String, _ ext: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(n)", withExtension: ext)))
    }

    func testIsPDFMagicBytes() throws {
        XCTAssertTrue(PDFText.isPDF(try fixture("pdf-minimal", "pdf")))
        XCTAssertFalse(PDFText.isPDF(try fixture("not-a-pdf", "bin")))
    }

    func testNonPDFThrows() throws {   // error handler first
        XCTAssertThrowsError(try PDFText.pages(try fixture("not-a-pdf", "bin"))) {
            guard case ParseError.malformed = $0 else { return XCTFail("expected .malformed") }
        }
    }

    func testOverPageLimitThrows() throws {   // D3 — refusal before happy path
        XCTAssertThrowsError(try PDFText.pages(try fixture("pdf-over-limit", "pdf"))) {
            guard case ParseError.malformed(let m) = $0 else { return XCTFail("expected .malformed") }
            XCTAssertTrue(m.lowercased().contains("page") || m.contains("\(PDFText.maxPages)"), m)
        }
    }

    func testExtractsPageText() throws {
        let pages = try PDFText.pages(try fixture("pdf-minimal", "pdf"))
        XCTAssertEqual(pages.count, 1)
        XCTAssertTrue(pages[0].contains("72.5"))
    }
}
#endif
```

**Conventions:**
- `import XCTest` + `@testable import <target>` — no `@testable` when testing only public API.
- `final class FooTests: XCTestCase`
- Fixtures loaded via `Bundle.module.url(forResource:withExtension:)` wrapped in `XCTUnwrap`.
- `#if canImport(PDFKit) && os(macOS)` wraps macOS-only test classes.
- Error handlers tested before happy path.
- Descriptive test names, no underscores.
- Fixtures directory declared as `.copy("Fixtures")` resource in Package.swift; referenced as `"Fixtures/<name>"` in the forResource path.

---

## 10. Swift tools version and minimum platforms

- **Swift tools version:** `5.9` (first line of Package.swift)
- **Minimum platforms:** `.macOS(.v13)`, `.iOS(.v16)`

---

## Mismatch / Design Assumption Flags (summary)

These are items the plan's design assumes that do NOT exist or differ from the actual code:

| # | Design Assumption | Reality | Impact |
|---|-------------------|---------|--------|
| 1 | `ExtractionPrompt.make(pages:)` produces a prompt hash | NO hash is produced. `make` returns a plain `String`. The `contentSHA256` in the JSONL log is computed separately at the CLI layer from page data, not from the prompt. | The eval harness must compute its own SHA-256 from `Data` (pages or PDF bytes) before calling `make`. |
| 2 | Public tee-off points inside `extractDocument` | `extractDocument` is `private`-internals-only; it is NOT decomposed into separately-callable public steps. The public steps are individually callable (`PDFText.pages`, `ExtractionPrompt.make`, `LLMRequest.init`, `extractor.extract`, `LLMResponseContract.decode`) but the harness must call them directly rather than hooking into `PDFExtractor`. | bridge-eval should call the public functions in the same sequence directly, not call `extractDocument`. This is actually BETTER for tee-off instrumentation. |
| 3 | `RawResponseLog` is importable by bridge-eval | `RawResponseLog` lives in the `healthbridge` executableTarget, not a library. SPM does not allow one executable to import another's module. | Either restructure (extract to a library), re-implement JSONL logging in bridge-eval, or accept no log reuse. |
| 4 | `extractDocument` always available | It is `#if canImport(PDFKit) && os(macOS)` guarded. | bridge-eval is macOS-only in practice, so not a blocker, but the target and its tests need the same guard. |
| 5 | `PDFText.pages` is a standalone static on `PDFText` | VERIFIED CORRECT. `public static func pages(_ data: Data) throws -> [String]` — matches design exactly. |  |
| 6 | `LLMResponseContract.decode` is the right entry point | VERIFIED CORRECT. `public static func decode(_ jsonText: String, subjectId: String, subjectDOB: Date? = nil, now: Date = Date()) throws -> ParseResult` |  |
