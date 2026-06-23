# apple-health-data-bridge

Get quantitative health data out of standard medical-record documents and into Apple Health.

An open-source, all-Swift toolchain in three parts:

1. **`BridgeKit`** — a shared Swift package defining the *Bridge Document* schema (a versioned, Codable interchange format), the LOINC → HealthKit mapping table, and pure resolution/validation logic.
2. **`healthbridge`** — a macOS CLI that parses a medical-record document (FHIR R4 JSON first; C-CDA next) into a validated `*.bridge.json`.
3. **iOS writer app** *(later)* — imports a Bridge Document, lets you review every value against its source, writes the HealthKit-mappable subset into Apple Health, and keeps the rest in a local store.

## Why a bridge format?

Apple Health's clinical records are read-only for third-party apps. Only a subset of measurements (vitals and a handful of labs) map to writable `HKQuantityType`s. The Bridge Document carries **everything** extracted — raw fields *and* a resolved HealthKit mapping — so a document stays meaningful even as the mapping table and the apps evolve independently.

## Privacy & disclaimer

This software runs entirely on **your own machine**. It processes your medical documents locally; the core pipeline (FHIR / C-CDA parsing → `*.bridge.json` → Apple Health) **never transmits your data anywhere**. The only data that leaves your system is what **you** choose to write to **your own Apple device** via Apple Health.

**No HIPAA, PHI, or compliance guarantees are made by the authors.** This is an open-source tool, provided as-is, with no warranty of any kind. Because all protected health information (PHI) is handled on your system, **you** are solely responsible for the security, handling, backup, and lawful use of your own data and anyone else's data you process with it. The authors are not a covered entity or business associate, do not receive your data, and accept no liability for how it is used or protected.

> **One exception, opt-in and off by default:** a *future* PDF-extraction feature (not part of the current local pipeline) can optionally use a **bring-your-own-key** cloud AI provider. If — and only if — you enable it and supply your own key, the text of the documents you extract is sent to **the provider you choose**, under your own account and that provider's terms. Nothing is sent to the authors, ever. If you never enable it, no document data leaves your machine.

## Status

Early development. See `docs/superpowers/specs/` for the design.

## License

TBD
