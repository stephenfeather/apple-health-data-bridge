# apple-health-data-bridge

Get quantitative health data out of standard medical-record documents and into Apple Health.

An open-source, all-Swift toolchain in three parts:

1. **`BridgeKit`** — a shared Swift package defining the *Bridge Document* schema (a versioned, Codable interchange format), the LOINC → HealthKit mapping table, and pure resolution/validation logic.
2. **`healthbridge`** — a macOS CLI that parses a medical-record document (FHIR R4 JSON, C-CDA XML, or a PDF via an opt-in cloud LLM) into a validated `*.bridge.json`.
3. **iOS writer app** *(later)* — imports a Bridge Document, lets you review every value against its source, writes the HealthKit-mappable subset into Apple Health, and keeps the rest in a local store.

## Why a bridge format?

Apple Health's clinical records are read-only for third-party apps. Only a subset of measurements (vitals and a handful of labs) map to writable `HKQuantityType`s. The Bridge Document carries **everything** extracted — raw fields *and* a resolved HealthKit mapping — so a document stays meaningful even as the mapping table and the apps evolve independently.

## Privacy & disclaimer

This software runs entirely on **your own machine**. It processes your medical documents locally; the core pipeline (FHIR / C-CDA parsing → `*.bridge.json` → Apple Health) **never transmits your data anywhere**. The only data that leaves your system is what **you** choose to write to **your own Apple device** via Apple Health.

**No HIPAA, PHI, or compliance guarantees are made by the authors.** This is an open-source tool, provided as-is, with no warranty of any kind. Because all protected health information (PHI) is handled on your system, **you** are solely responsible for the security, handling, backup, and lawful use of your own data and anyone else's data you process with it. The authors are not a covered entity or business associate, do not receive your data, and accept no liability for how it is used or protected.

> **One exception, opt-in and off by default:** the PDF-extraction feature (see below) can optionally use a **bring-your-own-key** cloud AI provider. If — and only if — you choose a PDF input and supply your own key, the text of that document is sent to **the provider you choose**, under your own account and that provider's terms. Nothing is sent to the authors, ever. If you only use the FHIR/C-CDA paths, no document data leaves your machine.

## PDF extraction (cloud LLM, opt-in)

Beyond the deterministic FHIR/C-CDA parsers, `healthbridge` can extract observations from a **PDF** using a cloud LLM. This path is **non-deterministic** and is meant to be **gated by human review** (the iOS app's review screen, a separate spec) before any value is trusted.

```sh
# Default provider is Anthropic (Claude):
healthbridge parse report.pdf --subject jane

# Or OpenAI:
healthbridge parse report.pdf --subject jane --provider openai

# Override the model id:
healthbridge parse report.pdf --provider openai --model <model-id>
```

- **Providers & default models:** `--provider anthropic` (default) uses `claude-opus-4-8`; `--provider openai` uses `gpt-5.5`. Override either with `--model <id>`.
- **Bring-your-own key:** supply it via the provider env var (`ANTHROPIC_API_KEY` / `OPENAI_API_KEY`) or `--api-key`. The key is held **in memory only** for the request — it is **never written** to the config, the `*.bridge.json`, or logs (not even with `--verbose`).
- **macOS-only, text-layer only:** PDF text extraction uses PDFKit and runs on macOS. Image-only / scanned PDFs (no text layer) are refused — there is **no OCR**. PDFs over 30 pages are refused.
- **Untrusted output is validated:** the model's reply is forced to a strict JSON schema *and* re-validated by a decoder that drops/rejects anything it can't trust — a missing code/date/value, out-of-range confidence, a malformed or **implausible** date (before the subject's verified DOB, or in the future), and multi-patient responses. A model can still return a *plausible-but-wrong* value, which is exactly why the **iOS review screen is the safety gate**.

> **Synthetic fixtures only.** This is a public repository: every test fixture (PDFs and canned LLM responses) contains **synthetic identities and values only** (e.g. "Jane Public" / 2000-01-01). No real patient data is ever committed.

## Status

Early development. See `docs/superpowers/specs/` for the design.

## License

[MIT](LICENSE) © 2026 Stephen Feather. Provided "as is", without warranty of any kind (see the disclaimer above and the `LICENSE` file).
