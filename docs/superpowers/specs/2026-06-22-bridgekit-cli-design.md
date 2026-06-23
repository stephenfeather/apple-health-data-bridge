# Design: BridgeKit + `healthbridge` CLI (Milestone 1)

**Date:** 2026-06-22
**Status:** Draft for review
**Scope:** First implementation cycle only — the shared schema package and the macOS CLI that parses standard medical-record XML into a validated Bridge Document. The iOS writer app is a later, separate spec.

---

## 1. Purpose

`apple-health-data-bridge` gets quantitative health data out of standard medical-record documents and into Apple Health. The full system is three Swift components:

1. **`BridgeKit`** — shared Swift package: the Bridge Document schema, the LOINC→HealthKit mapping table, and pure resolution/validation logic.
2. **`healthbridge`** — macOS CLI: parses a medical-record document into a validated `*.bridge.json`.
3. **iOS writer app** — imports a Bridge Document, lets the user review every value against its source, writes the HealthKit-mappable subset to Apple Health, and stores the rest locally.

**This spec covers components 1 and 2 only.** Component 3 is deferred to its own spec/plan.

### Why XML-first, FHIR-first

The document-parsing path was deliberately sequenced from lowest risk to highest:

- **XML (this milestone):** deterministic, no LLM, no PHI leaves the machine, official test corpora exist.
- **PDF + cloud LLM (later milestone):** highest extraction quality for messy reports but introduces confidence/hallucination risk and PHI egress. The review screen built into the iOS app is what makes that safe — so it lands after the deterministic path is proven.

FHIR is the primary parser for this milestone because standard medical-record exchange is converging on it and the official FHIR examples give an immediate, public test corpus. C-CDA (we have a real Privia `AmbulatorySummary` sample) is the next parser and is designed to drop in beside FHIR without schema changes.

---

## 2. The Bridge Document (schema)

A versioned JSON file. One document per source report. Defined in `BridgeKit` as `Codable` Swift types.

```
BridgeDocument
├─ schemaVersion: Int
├─ source:
│   ├─ kind: "fhir" | "ccda" | "pdf"
│   ├─ fileName: String
│   ├─ sha256: String                 // dedup + traceability
│   ├─ extractedAt: Date
│   └─ extractor: { engine: String, version: String }   // e.g. {"fhir-parser","0.1.0"}
├─ subject?: { name?: String, dob?: Date }   // optional, for user sanity-check only
└─ observations: [Observation]

Observation
├─ id: String                          // stable, derived (see §5)
├─ code?: { system: String, code: String, display: String }   // e.g. LOINC 29463-7
├─ name: String                        // human label as it appeared in the source
├─ value: ObservationValue            // .quantity(Double) | .string(String)
├─ unit?: String                       // as reported in the source
├─ effectiveDate: Date                 // when the measurement was TAKEN (not import time)
├─ category: "vital" | "lab" | "other"
├─ mapping: HealthKitMapping?          // resolved by BridgeKit; nil ⇒ not HealthKit-writable
│   ├─ quantityType: String            // e.g. "HKQuantityTypeIdentifierBodyMass"
│   ├─ canonicalUnit: String           // HealthKit's expected unit
│   └─ convertedValue: Double          // value converted to canonicalUnit
├─ confidence: Double                  // 1.0 for deterministic XML parsers
└─ sourceLocator?: { page?: Int, snippet?: String }   // mainly for the future PDF path
```

**Design notes**
- Raw fields **and** resolved `mapping` both present (approach C — agreed). A document remains interpretable even if produced by an older/newer component version.
- `effectiveDate` is the clinical date from the source. Critical: using import time would put every measurement on today's date in Health charts.
- `confidence` is `1.0` for deterministic XML parsing; the field exists now so the PDF/LLM path needs no schema change later.
- `ObservationValue` is an enum so qualitative results ("positive", "negative", "trace") survive even when not HealthKit-writable.

---

## 3. `BridgeKit` (shared package)

Pure logic, no I/O, no platform frameworks (so it compiles for macOS CLI **and** iOS app).

**Contents**
- The schema types (§2) with `Codable` conformance and a stable JSON encoding (sorted keys, ISO-8601 dates).
- **LOINC→HealthKit mapping table** as data (a static dictionary or bundled resource). Each entry:
  `{ loinc: String, hkQuantityType: String, canonicalUnit: String, unitConversions: [String: ClosedConversion] }`.
  Initial table ~30–40 entries covering the writable universe: vitals (height, weight, BMI, body temperature, heart rate, blood pressure systolic/diastolic, respiratory rate, oxygen saturation) and the small set of HealthKit-supported labs (e.g. blood glucose). Driven by what actually appears in real exports.
- Pure functions:
  - `resolveMapping(_ observation: Observation) -> HealthKitMapping?` — looks up the observation's LOINC code, converts the unit, returns `nil` when unsupported.
  - `deriveObservationID(...) -> String` — deterministic id (§5).
  - `validate(_ document: BridgeDocument) -> [ValidationIssue]` — structural + semantic checks.

**Boundaries:** `BridgeKit` knows the *names* of HealthKit quantity types (strings) but does **not** import HealthKit — that keeps it buildable on any platform and unit-testable without a device. The iOS app turns those strings into real `HKObjectType`s.

---

## 4. `healthbridge` CLI (macOS)

A Swift Package Manager executable. Usage:

```
healthbridge parse <input.xml> [--out <path.bridge.json>] [--format fhir|ccda|auto]
```

**Pipeline**
1. Read the input file; compute `sha256`.
2. Select a parser (`--format`, or sniff the root element: FHIR `Bundle`/`Observation` vs C-CDA `ClinicalDocument`).
3. Parser produces `[Observation]` (raw fields populated, `confidence = 1.0`).
4. For each observation, call `BridgeKit.resolveMapping` to populate `mapping`.
5. Assemble `BridgeDocument`, run `BridgeKit.validate`, write pretty-printed JSON.
6. Print a summary to stderr: N observations, M mapped to HealthKit, K unmapped (with names), any validation warnings.

**Parser abstraction**
```swift
protocol DocumentParser {
    static func canParse(_ data: Data) -> Bool
    func parse(_ data: Data, fileName: String) throws -> [Observation]
}
```
Milestone 1 ships `FHIRParser`. `CCDAParser` is the next implementation conforming to the same protocol; nothing downstream changes.

**FHIR parser (M1 primary)** — **FHIR R4, JSON serialization, via Apple's `FHIRModels` package** (resolved §7 #1–#3).
- Decode the input with `FHIRModels` (ModelsR4) — typed `Bundle` / `Observation` resources, no hand-rolled JSON or XML.
- Walk a `Bundle` (or a bare `Observation`), select `Observation` resources (and `Observation`s referenced by `DiagnosticReport`).
- Per observation: extract LOINC `code`, `valueQuantity` (value + UCUM unit) or `valueString`, `effectiveDateTime`/`effectivePeriod`, category.
- Map UCUM units to the schema's `unit` string; `BridgeKit` handles HealthKit unit conversion.

---

## 5. Idempotency / stable IDs

Re-parsing the same report (or two overlapping exports) must not create duplicate Health samples later. `deriveObservationID` is a deterministic hash of:
`(source.sha256 OR a stable patient+document key) + code.system + code.code + effectiveDate + raw value + unit`.

The iOS app (later milestone) writes each HKObject with `HKMetadataKeySyncIdentifier = Observation.id` and a `HKMetadataKeySyncVersion`, so HealthKit updates-in-place instead of duplicating. The id is defined here so the contract is fixed before the writer exists.

---

## 6. Testing

- **`BridgeKit` unit tests:** mapping resolution (mapped, unmapped, unit-conversion), id determinism (same input → same id; different value → different id), schema round-trip encode/decode, validation catches malformed documents.
- **`FHIRParser` tests:** run against a vendored subset of the official FHIR example resources (Observation + DiagnosticReport + Bundle). Assert extracted count, codes, values, units, and `effectiveDate`.
- **CLI integration test:** parse a sample file end-to-end, assert the emitted `*.bridge.json` validates and contains expected mapped/unmapped counts.
- **Golden file:** check in an expected `*.bridge.json` for one representative input and diff against it.

No network in tests. Test inputs are public FHIR examples (no PHI); the real Privia C-CDA sample is used when the C-CDA parser lands and is **not** committed.

---

## 7. Decisions

1. **FHIR version target — RESOLVED: R4.** What production EHRs emit; supported by Apple's `FHIRModels` (ModelsR4). Test corpus = the official R4 example resources.
2. **FHIR serialization — RESOLVED: JSON.** Consume FHIR JSON via `FHIRModels`. No `XMLParser` on the FHIR path. (C-CDA, when it lands, is XML-only and gets its own `XMLParser`-based parser conforming to `DocumentParser`.)
3. **`FHIRModels` dependency — RESOLVED: adopt it.** Use Apple's open-source `FHIRModels` package (ModelsR4) rather than a hand-rolled decoder.
4. **C-CDA in M1 or M2? — OPEN (recommend M2).** With FHIR now JSON-via-`FHIRModels` and C-CDA being XML-only, the two parsers share no decoding machinery, so folding C-CDA into M1 adds meaningful scope. Recommend shipping FHIR in M1 and C-CDA in M2; both conform to the same `DocumentParser` protocol so the deferral costs nothing architecturally.

---

## 8. Out of scope (this spec)

- iOS writer app, HealthKit writes, the review UI, local SwiftData store (separate spec).
- PDF extraction and any LLM integration (later milestone).
- Mac→iOS file transport (AirDrop/iCloud/Files).
- Multi-document merge/longitudinal dedup across many exports (the id contract enables it; the logic is later).
