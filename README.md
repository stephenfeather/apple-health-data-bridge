# apple-health-data-bridge

Get quantitative health data out of standard medical-record documents and into Apple Health.

An open-source, all-Swift toolchain in three parts:

1. **`BridgeKit`** — a shared Swift package defining the *Bridge Document* schema (a versioned, Codable interchange format), the LOINC → HealthKit mapping table, and pure resolution/validation logic.
2. **`healthbridge`** — a macOS CLI that parses a medical-record document (FHIR R4 JSON first; C-CDA next) into a validated `*.bridge.json`.
3. **iOS writer app** *(later)* — imports a Bridge Document, lets you review every value against its source, writes the HealthKit-mappable subset into Apple Health, and keeps the rest in a local store.

## Why a bridge format?

Apple Health's clinical records are read-only for third-party apps. Only a subset of measurements (vitals and a handful of labs) map to writable `HKQuantityType`s. The Bridge Document carries **everything** extracted — raw fields *and* a resolved HealthKit mapping — so a document stays meaningful even as the mapping table and the apps evolve independently.

## Status

Early development. See `docs/superpowers/specs/` for the design.

## License

TBD
