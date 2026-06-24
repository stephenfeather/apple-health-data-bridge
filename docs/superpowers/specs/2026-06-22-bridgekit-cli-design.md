# Design: BridgeKit + `healthbridge` CLI (Milestone 1)

**Date:** 2026-06-22 (updated 2026-06-23)
**Status:** Draft for review
**Scope:** First implementation cycle — an all-Swift package plus a macOS CLI that parses standard medical-record FHIR R4 JSON into a validated, **subject-bound** Bridge Document, driven by a layered TOML config and written to per-subject storage. The iOS writer app is a later, separate spec.

---

## 1. Purpose

`apple-health-data-bridge` gets quantitative health data out of standard medical-record documents and into Apple Health. The full system is three Swift components:

1. **`BridgeKit`** — platform-pure library: the Bridge Document schema, the LOINC→HealthKit mapping table, ID derivation, subject hashing, and validation.
2. **`healthbridge`** — macOS CLI: config-driven; parses a medical-record document into a validated `*.bridge.json`, bound to a configured subject, written to per-subject storage. Also manages the subject roster.
3. **iOS writer app** — imports a Bridge Document, enforces the device-to-subject binding gate, lets the user review every value against its source, writes the HealthKit-mappable subset to Apple Health, and stores the rest locally.

**This spec covers components 1 and 2.** Component 3 is deferred to its own spec/plan, but the schema fields and subject-binding contract it depends on are defined here.

### Milestone roadmap

The document-parsing path is sequenced lowest-risk first:

- **M1 (this spec):** FHIR R4 JSON → subject-bound `bridge.json`. Deterministic, no LLM, no PHI leaves the machine, public FHIR test corpus.
- **M2:** C-CDA (XML) parser as a sibling `DocumentParser` (we have a real Privia `AmbulatorySummary` sample). No schema change.
- **M3:** ✅ **Shipped 2026-06-24 (PR #6).** PDF + cloud LLM extraction (BYO key) producing the same `Observation` shape with confidence + source locators. The iOS review screen is what makes LLM output safe, so it follows the deterministic path.
- **iOS writer:** consumes the Bridge Document, enforces the binding gate, writes HealthKit.

---

## 2. The Bridge Document (schema)

A versioned JSON file, one per source report, defined in `BridgeKit` as `Codable` Swift types. Encoding is deterministic: sorted keys, pretty-printed, ISO-8601 dates normalized to **whole-second UTC**.

```
BridgeDocument
├─ schemaVersion: Int                  // current = 1
├─ source:
│   ├─ kind: "fhir" | "ccda" | "pdf"
│   ├─ fileName: String
│   ├─ sha256: String                  // source-file hash; the documentKey for ID derivation
│   ├─ extractedAt: Date
│   └─ extractor: { engine: String, version: String }
├─ subject:                            // REQUIRED — binds the document to a person
│   ├─ id: String                      // UUID, assigned at enrollment (roster)
│   ├─ label: String                   // human label, e.g. "Jane"
│   ├─ hash: String                    // sha256(canonical name|dob) — verification
│   ├─ name?: String
│   └─ dob?: String
└─ observations: [Observation]

Observation
├─ id: String                          // stable, derived (see §6)
├─ code?: { system: String, code: String, display: String }   // e.g. LOINC 29463-7
├─ name: String
├─ value: ObservationValue             // .quantity(Double) | .string(String), tagged in JSON
├─ unit?: String                       // as reported (UCUM)
├─ effectiveDate: Date                 // when the measurement was TAKEN (not import time)
├─ category: "vital" | "lab" | "other"
├─ mapping: HealthKitMapping?          // resolved via BridgeKit; nil ⇒ not HealthKit-writable
│   ├─ quantityType: String            // e.g. "HKQuantityTypeIdentifierBodyMass"
│   ├─ canonicalUnit: String
│   └─ convertedValue: Double
├─ confidence: Double                  // 1.0 for deterministic parsers
└─ sourceLocator?: { page?: Int, snippet?: String }   // mainly for the future PDF path
```

**Design notes**
- Raw fields **and** resolved `mapping` both present (approach C). A document stays interpretable across component-version skew.
- `subject` is **required**: a Bridge Document is meaningless — and dangerous — without knowing whose data it is. The `subject.id` (UUID) is the binding key the iOS writer matches against its configured owner; `subject.hash` is the verification value (`sha256(name|dob)`).
- `effectiveDate` is the clinical date; import time would mis-chart everything to today. Whole-second UTC is a deliberate, dedup-stable normalization.
- `ObservationValue` is a tagged enum so qualitative results ("positive") survive even when not HealthKit-writable, and never collide with numeric values.

---

## 3. `BridgeKit` (shared, platform-pure library)

Pure logic; imports only `Foundation` + `CryptoKit` (no `ModelsR4`, no HealthKit, no `ArgumentParser`, no `TOMLKit`), so it compiles for the macOS CLI **and** the future iOS app and is unit-testable without a device.

**Contents**
- The schema types (§2) with `Codable` and deterministic JSON (`BridgeJSON.encoder`/`decoder`).
- **LOINC→HealthKit mapping table** as data — seeded **lean (~10 entries)**: weight, height, BMI, body temperature, heart rate, respiratory rate, O₂ saturation, BP systolic, BP diastolic, blood glucose. Grown from evidence (the CLI reports unmapped observations by name). `MappingTable.resolve(loinc:value:unit:) -> HealthKitMapping?` returns `nil` for unknown LOINC, non-quantity values, or unconvertible units — conservatively leaving a value out rather than writing a wrong-unit number.
- `ObservationID.derive(subjectId:system:code:effectiveDate:rawValue:unit:) -> String` — SHA-256 hex over **content + subject** (no source-file key) → the same clinical observation gets the same id across files, so it dedupes once written (§6).
- `SubjectHash.make(name:dob:) -> String` — SHA-256 of canonicalized `name|dob`; used to stamp and cross-check subject identity.
- `validate(_:) -> [ValidationIssue]` — structural/semantic checks (§7).

**Boundary:** `BridgeKit` knows HealthKit quantity-type *names* (strings) but never imports HealthKit. The iOS app turns those strings into real `HKObjectType`s.

---

## 4. Configuration, subjects, and storage

The CLI is config-driven. A human-edited **TOML** config carries scalar settings plus the subject roster.

### 4.1 Layered settings — precedence is a hard rule

**CLI flag > TOML config > built-in default.** Every *scalar* setting has a matching `--flag`:

| TOML key | CLI override | Default |
|---|---|---|
| `data_root` | `--data-root <path>` | `~/Documents/apple-health-data-bridge` |
| `default_subject` | `--subject <key>` | (none — selection required) |
| `log_level` | `--verbose` / `--quiet` | `normal` |
| *(config file path)* | `--config <path>` | `~/.config/apple-health-data-bridge/config.toml` |

The **subject roster** is a *managed collection*, not a scalar setting — it is not overridden by a flag; it is managed with `healthbridge subject add/list`, and `--subject <key>` selects which roster entry a run uses. `--config` makes per-subject config files possible (one roster of one), as well as a shared multi-subject config.

### 4.2 Subjects and the roster

Multiple medical users may run under one macOS account (e.g. a parent processing records for several family members, each with their own iPhone/Health store). Each subject has:

- a **`subjectId`** — a **random UUID** generated once at enrollment (not a name hash — names collide and a name-hash is weak PII). Stored in the roster, stamped into every document.
- a **`subjectHash`** — `sha256(name|dob)` — a secondary, deterministic verification value (belt-and-suspenders alongside the UUID).
- `label`, `name`, `dob`.

Roster entries are CLI-managed so humans never hand-write UUIDs:
```
healthbridge subject add --label "Jane" --name "Jane Public" --dob 2000-01-01
  → generates UUID, computes name|dob hash, writes the roster entry, prints the subjectId
healthbridge subject list
```

### 4.3 Wrong-data-to-wrong-device safety (defense in depth)

The core risk is one subject's data reaching another's device. Two gates:

- **At processing (M1, Mac):** `parse` requires a selected subject and cross-checks it against the document's FHIR `Patient`. `PatientMatch` returns a four-state result — `match` / `mismatch` / `noPatient` / `incomplete` (Patient present but missing a usable name/dob). Name comparison is **token-based** (case-insensitive first+last name + dob), not a brittle full-string hash, so "Jane Q Public" vs "Jane Public" still matches. Policy: `match` and `noPatient` proceed; `mismatch` refuses unless `--force`; `incomplete` refuses unless `--allow-unverified-subject`. On refusal the CLI prints the document's extracted name/dob alongside the roster's, so the operator sees exactly what failed. Handles both `Bundle`-wrapped and bare `Patient` resources.
- **At write (later, iOS):** the device is configured once with its owner's `subject.id`; the writer **refuses any Bridge Document whose `subject.id` ≠ the device owner**, and the mandatory review screen shows the document's name/dob for human confirmation.

### 4.4 Storage layout

Processed documents live in the `~` tree (backed up), user-relocatable via `data_root`:
```
<data_root>/subjects/<subjectId>/<sourceSha>.bridge.json
```
The path key is the opaque `subjectId` (UUID) — **no PII in the path**. PHI never enters the repo: `*.bridge.json` is gitignored and never committed.

---

## 5. `healthbridge` CLI (macOS)

A SwiftPM executable (`ArgumentParser`). Targets: `HealthBridgeConfig` (TOML + settings), `HealthBridgeParsing` (`DocumentParser` + `FHIRParser`), `BridgeKit`.

```
healthbridge parse <input.json> [--config <p>] [--subject <key>] [--data-root <p>] [--verbose|--quiet]
healthbridge subject add --label <l> --name <n> --dob <d> [--config <p>]
healthbridge subject list [--config <p>]
```

**`parse` pipeline**
1. Load config (`--config` or default); resolve `Settings` (flag > config > default).
2. Resolve the selected subject; error if none.
3. Read input; `sha256`. **Cross-check** the FHIR `Patient` against the subject — refuse on mismatch.
4. `FHIRParser.parse` → `ParseResult { observations, skipped }`. Observations carry `confidence = 1.0`, `mapping = nil`.
5. Resolve each observation's `mapping` via `MappingTable`; **dedupe by id** (keep first).
6. Assemble the `BridgeDocument` with the subject's `SubjectRef`; `validate`; abort on any error.
7. Write to `<data_root>/subjects/<subjectId>/<sha>.bridge.json`.
8. Summary to stderr: N observations, M mapped, K unmapped, S skipped — and **log each skipped observation** (reason + label) **and each unmapped-but-written observation** (LOINC code + name), the latter being the evidence loop for growing the mapping table. `--quiet` suppresses; `--verbose` is the default-plus. A zero-observation document is still written but the CLI exits with a **distinct non-zero code** so automation can detect it.

**Parser abstraction**
```swift
protocol DocumentParser {
    static func canParse(_ data: Data) -> Bool
    func parse(_ data: Data, subjectId: String) throws -> ParseResult
}
struct ParseResult { let observations: [Observation]; let skipped: [Skip] }
struct Skip { enum Reason { case noCode, noDate, unrepresentableValue }; let reason: Reason; let label: String }
```
M1 ships `FHIRParser`. C-CDA (M2) and PDF (M3) conform to the same protocol. A multi-parser registry is deferred until the second format (M2) — with one parser, the CLI calls it directly.

**FHIR parser (M1)** — FHIR **R4, JSON**, via Apple's **`FHIRModels` (`ModelsR4`)**:
- Decode a `Bundle` (or bare `Observation`); select `Observation` resources.
- Per observation: LOINC `code`, `valueQuantity` (UCUM value+unit) or `valueString`, `effectiveDateTime`/`effectivePeriod`/`instant`, category.
- **Component panels:** an observation with a `component` array and no top-level value (e.g. blood pressure, LOINC `85354-9` with `8480-6` systolic + `8462-4` diastolic components) yields **one Observation per component** — otherwise standard BP would be dropped and never map.
- **UTC date normalization:** offset-less / date-only FHIR dates are resolved under a **fixed UTC calendar** (date-only anchored to UTC midnight), not `TimeZone.current`. Without this, the same file on machines in different timezones would derive different `Date`s → different `Observation.id` → broken determinism.
- **Drop-and-log**: observations with no coding (`.noCode`), no effective date (`.noDate`), or no representable value (`.unrepresentableValue`) are dropped and recorded in `skipped` for the CLI to log — never silently lost.
- Prefer `valueQuantity.code` (UCUM, e.g. `[lb_av]`) over `.unit` (display) so mapping matches reliably.

---

## 6. Idempotency / stable IDs

`ObservationID.derive` hashes **`subjectId + code.system + code.code + effectiveDate + raw value + unit`** — content + subject, *not* the source file. So the same clinical observation produces the **same id across different files** (an early portal export and a final summary), which means HealthKit dedupes it via the sync identifier instead of writing duplicates. The id is also **stable forever** — it never depends on which file delivered the observation, so there is no future migration that would invalidate already-written `HKMetadataKeySyncIdentifier`s. `subjectId` is in the hash so two people's identical readings never collide.

The CLI also dedupes identical observations *within* a file (same id → keep first). The iOS writer (later) writes each HKObject with `HKMetadataKeySyncIdentifier = Observation.id`, so re-writes — within or across files — update in place rather than duplicating.

---

## 7. Validation

`validate(_:) -> [ValidationIssue]` (severities `error`/`warning`). The CLI prints all issues and **aborts on any `error`**.

- wrong `schemaVersion` → error
- `source.sha256` empty or not 64 hex chars → error
- `subject.id` empty or not a valid UUID → error; empty `subject.hash` → error
- duplicate observation ids → error (**backstop** — the CLI dedupes before validating, so this should not fire; a survivor signals a bug)
- empty observation `id` or `name` → error
- `confidence` outside `0...1`, or non-finite quantity value, or non-finite `mapping.convertedValue` → error
- `mapping != nil` on a `.string` value, or a `mapping` with any empty field → error (internal invariant)
- zero observations → warning (document still written; CLI exits with a distinct code)

---

## 8. Testing

- **`BridgeKit`:** mapping (mapped/unmapped/unit-conversion), ID determinism + sensitivity, subject hash (canonical + distinct), schema round-trip, validation rules.
- **`HealthBridgeConfig`:** settings precedence (flag > config > default), tilde expansion, subject selection, TOML load + round-trip write.
- **`FHIRParser`:** single Observation, Bundle (vital + lab), drop-and-log code-less, malformed throws — against checked-in synthetic/public FHIR fixtures.
- **CLI (`BridgeBuilder`/`PatientMatch`):** subject-bound document, dedupe, deterministic output, Patient cross-check match + reject.

No network in tests. All fixtures are synthetic/public — **no PHI** in the repo. The real Privia C-CDA sample is used only when the C-CDA parser lands (M2) and is never committed.

---

## 9. Decisions (resolved)

1. **FHIR version — R4.** Production-EHR standard; supported by `FHIRModels` (ModelsR4). Verified resolved version **0.9.3**.
2. **FHIR serialization — JSON** via `FHIRModels`. No `XMLParser` on the FHIR path (C-CDA, M2, is XML-only and gets its own).
3. **Dependencies** — `FHIRModels` (0.9.3), `swift-argument-parser` (`.upToNextMinor(from: "1.8.2")`), `TOMLKit` (behind a one-file `TOMLCodec` adapter to isolate API uncertainty). `BridgeKit` stays dependency-free beyond Foundation/CryptoKit. **`Package.resolved` is committed** for reproducible pins.
4. **C-CDA — M2** (sibling `DocumentParser`, no schema change). **PDF/LLM — M3.**
5. **Subject identity — UUID `subject.id` + `sha256(name|dob)` cross-check.** Not a name hash as the primary id.
6. **Config — TOML**, default `~/.config/apple-health-data-bridge/config.toml`, `--config` overridable; **every scalar setting has a `--flag`** (precedence flag > config > default); roster is **CLI-managed** (`subject add` rejects duplicate keys; explicit `--key` available).
7. **Storage — `~/Documents/apple-health-data-bridge` default** (`~`-tree, backed up), user-definable via `data_root`; per-subject subdirs keyed by `subject.id`.
8. **Code-less / date-less / unrepresentable observations — drop and log** (recorded in `ParseResult.skipped`, surfaced by the CLI).
9. **Within-file duplicates — dedupe-and-proceed** (keep first); validator duplicate-id error is a backstop.
10. **Observation id — content + subject based** (`subjectId + code + date + value + unit`), *not* file-keyed. Stable forever; dedupes the same observation across files via the HealthKit sync identifier. (Reverses the earlier "per-file only" choice — the id is the durable sync key, so it must not depend on the delivering file.)
11. **Patient cross-check — four-state** (`match`/`mismatch`/`noPatient`/`incomplete`) with token-based name matching; `mismatch` needs `--force`, `incomplete` needs `--allow-unverified-subject`.
12. **Deterministic extraction — `extractedAt` is an injected clock** (`now:` param, fixed in tests); UTC date normalization for offset-less FHIR dates. Both protect byte-stable output.

---

## 10. Out of scope (this spec)

- iOS writer app, HealthKit writes, the review UI, the device-to-subject binding gate, local SwiftData store (separate spec — the `subjectId` contract here enables it).
- Longitudinal *reconciliation* across exports — conflicting/corrected values, supersedence, history merging. (Plain cross-file dedup of *identical* observations now happens for free via the content-based id; reconciling *different* values for the same code/time is later.)
- C-CDA (M2) and PDF + LLM extraction (M3).
- Mac→iOS file transport (AirDrop/iCloud/Files).
