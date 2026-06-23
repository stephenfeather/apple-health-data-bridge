# BridgeKit + healthbridge CLI (Milestone 3 — PDF + cloud LLM extraction) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. This plan is built for a visible pane-team (impl + reviewer); each task is one reviewer-gated, independently-committable commit.

**Goal:** Add a third document path — a **non-deterministic** PDF → cloud-LLM extractor — that produces the **same** subject-bound Bridge Document the FHIR (M1) and C-CDA (M2) parsers produce, **plus** per-observation `confidence` scores and `sourceLocator` (page/snippet) references back into the PDF. The extractor is **provider-agnostic**: a single `LLMExtractor` protocol with **two** concrete adapters from day one — **Anthropic Messages API (the default)** and **OpenAI** — so a third provider is a new conformance, not a refactor. The API key is **bring-your-own**, read from an environment variable with an optional `--api-key` flag override; it is **never persisted to disk and never logged**. LLM output is untrusted: each adapter forces JSON natively AND the extractor validates a strict JSON response contract, drops/flags anything it cannot trust, and the downstream **iOS review screen** (separate spec) is what makes the path safe.

**Architecture:** No package change to `BridgeKit` (the schema already supports everything M3 needs — see "No schema change", below). New work lives in `HealthBridgeParsing` (PDF text extraction, the `LLMExtractor` protocol, the two provider adapters, the response-contract decoder, and a `PDFExtractor` that conforms to the existing `DocumentParser` shape via an injected extractor) and a small CLI surface change in `HealthBridge.swift` (route `.pdf` input to the LLM path, require a key only then, stamp `source.kind = .pdf`). Data flow: PDF bytes → `PDFText.pages(_:)` (PDFKit, macOS-only) → `LLMRequest` (prompt + page text) → injected `LLMExtractor.extract(_:)` → **validated** `[LLMObservation]` (untrusted JSON) → mapped into `[Observation]` (`confidence` from the model, `sourceLocator` = page/snippet, `mapping = nil`) → existing resolve-mapping → dedupe → subject-bound `BridgeDocument` with `source.kind = .pdf` → JSON file under the subject's storage dir. Everything downstream of `ParseResult` is M1/M2 code, unchanged. The network call is isolated behind `LLMExtractor`, so **all extraction logic is unit-tested with a mock extractor and zero network / zero API key**.

**Tech Stack:** Swift 5.9+, SwiftPM, **PDFKit** (macOS/iOS framework; used macOS-only here, guarded), **URLSession async/await** for the network edge, `Foundation` `JSONEncoder`/`JSONDecoder` for the request/response contract, plus the existing M1/M2 stack. **No new SwiftPM dependency** — PDFKit and URLSession are platform frameworks; `Package.resolved` does not change.

---

## Locked decisions (resolved with the user — D1–D6)

These six decisions are **locked** and are propagated into the relevant tasks below. They replace what were previously open questions.

| # | Decision | Where it lands |
|---|---|---|
| **D1** | **Default provider = Claude (Anthropic).** Both adapters build. When neither `--provider` nor key context disambiguates, the CLI defaults to **Anthropic**. OpenAI is selected via `--provider openai`. | Provider table; Task 9 routing + `resolveProvider` |
| **D2** | **JSON enforcement = native JSON modes AND the validating decoder (BOTH), per-provider.** OpenAI uses `response_format` (json_schema). **Anthropic uses ASSISTANT PREFILL** (seed the assistant turn with `{`) — NOT tool-use. Anthropic's Messages API has **no `response_format`** (that is OpenAI-only), and prefill keeps the reply in `content[0].text` (tool-use would move it into a `tool_use` block's `.input` and break `parseEnvelope`). Each adapter's `makeRequest` encodes its native JSON-forcing. The shared `LLMResponseContract` decoder STILL treats every reply as untrusted. | Provider table; Tasks 4, 7, 8 |
| **D3** | **Large-PDF policy = refuse over ~30 pages** with a clear error; chunking deferred. Test-first (refusal path before happy path). | Task 2 page-count guard (`maxPages = 30`) |
| **D4** | **Multi-patient contract = explicit top-level `patients[]`** in the LLM response contract; refuse when count > 1 (M2-parity). | Task 6 (as already specified) |
| **D5** | **Retry = bounded 2× on 429/5xx/timeout**, real backoff tuning deferred. | Tasks 7, 8; Known-limitations |
| **D6** | **Model ids pinned from current provider docs at Task 7/8** (do NOT hardcode ids now; the implementer resolves current ids via Context7/provider docs at implementation time and records them in the task). | Provider table; Tasks 7, 8 |

---

## Ground-truth confirmations (read before trusting any signature below)

These were verified by reading the real sources on `origin/main` (commit `f371aa1`, M1) — **not guessed**. The implementer must re-confirm against the freshly-fetched origin/main worktree (which will also contain M2 / PR #2 `71d4d979`):

- ✓ VERIFIED — `Sources/BridgeKit/Observation.swift`: `Observation` **already has** `confidence: Double` and `sourceLocator: SourceLocator?`. `SourceLocator` is a real type: `public struct SourceLocator: Codable, Equatable, Sendable { public var page: Int?; public var snippet: String? }`. **Confidence + source locators require NO schema change** — they exist for exactly this milestone. The init is `Observation(id:code:name:value:unit:effectiveDate:category:mapping:confidence:sourceLocator:)`; `code` is `CodeableRef?`; `value` is `ObservationValue` (`.quantity(Double)` | `.string(String)`).
- ✓ VERIFIED — `Sources/BridgeKit/BridgeDocument.swift`: `SourceKind` already declares `.pdf`. `Source` already carries `extractor: Extractor(engine: String, version: String)`. **No schema change for `kind` or `extractor`.**
- ✓ VERIFIED — `Sources/HealthBridgeParsing/DocumentParser.swift`: the contract is `protocol DocumentParser { static func canParse(_ data: Data) -> Bool; func parse(_ data: Data, subjectId: String) throws -> ParseResult }`. `ParseResult { observations: [Observation]; skipped: [Skip] }`. `Skip.Reason` is `{ noCode, noDate, unrepresentableValue }`. `ParseError` is `{ unrecognizedFormat, malformed(String) }`. **M3 reuses all of these as-is; it does NOT add Skip reasons or ParseError cases (see "Failure modes" for how each failure maps onto the existing cases).**
- ✓ VERIFIED — `Sources/BridgeKit/ObservationID.swift`: `ObservationID.derive(subjectId:system:code:effectiveDate:rawValue:unit:) -> String`. `code`/`system`/`unit` are optional; `rawValue` is the stable string form of the value. The same content yields the same id across paths.
- ✓ VERIFIED — `Sources/HealthBridgeParsing/FHIRParser.swift`: emits `confidence: 1.0, sourceLocator: nil`, and uses an **overflow-safe** `stableNumberString` (the M1 PR-#1 fix: guards `Int.min..<Int.max` before `String(Int(d))`). M3's quantity → `rawValue` MUST use the same helper for id-parity. PREFERRED: extract a shared internal helper; FALLBACK: replicate the guarded version verbatim.
- ✓ VERIFIED — `Sources/healthbridge/HealthBridge.swift`: `BridgeBuilder.build(data:fileName:subject:now:)` currently **hardcodes** `FHIRParser` + `kind: .fhir` + `Extractor(engine: "fhir-parser", version: "0.1.0")`. The `Parse` command reads the input file, computes `PatientMatch.patientCount(data:)` (FHIR-decode-based) and refuses `> 1`, runs the four-state `PatientMatch.check`, then writes `<dataRoot>/subjects/<subjectId>/<sha>.bridge.json`, logs unmapped + skipped, and `throw ExitCode(2)` for an empty document. **M3 must add a parallel PDF route here** — `patientCount` is FHIR-only and does not apply to PDFs (PDF multi-patient detection comes from the LLM response, see Task 6).
- ✓ VERIFIED — `Package.swift`: platforms `.macOS(.v13), .iOS(.v16)`; the `healthbridge` executable is macOS-only in practice; `HealthBridgeParsingTests` already declares `resources: [.copy("Fixtures")]`. **No `Package.swift` dependency change in M3** (PDFKit/URLSession are frameworks); a `linkedFramework`/`#if canImport(PDFKit)` guard is the mechanism, not a SwiftPM dep.
- ? INFERRED (from the M2 plan, NOT yet in the local `origin/main` ref) — M2 added `ParserRegistry.swift` and switched `BridgeBuilder` to select a parser via the registry + stamp `Source.kind` from the chosen parser, plus a C-CDA-aware `PatientMatch`. **The implementer MUST read the actual M2 code in the fresh worktree** (`ParserRegistry.swift`, the registry-based `BridgeBuilder`, `Source.kind` stamping) before Task 7/9, because M3's CLI route attaches to whatever M2 actually shipped, not to M1's hardcoded `FHIRParser`. If `BridgeBuilder` already routes via a registry, M3 extends that routing; if it still hardcodes FHIR, M3 adds the branch. Task 0 Step 5 pins this.

---

## Global Constraints

- Swift tools version **5.9**. Platforms unchanged: **`.macOS(.v13), .iOS(.v16)`**.
- **No new SwiftPM dependency.** PDF text uses **PDFKit** (Apple framework); the network uses **URLSession**. `Package.resolved` does not change. If PDFKit must be explicitly linked for the parsing target, use `linkerSettings: [.linkedFramework("PDFKit")]` in `Package.swift` (a build-setting change, not a dependency pin) — confirm empirically whether it is needed; on macOS PDFKit is usually importable without an explicit link.
- **PDF parsing is macOS-only — guarded, exactly like M2's XML path.** PDFKit exists on iOS too, but the **iOS app consumes Bridge Documents, it never parses** (M1 spec §1, §3 boundary). The whole PDF/LLM path lives behind `#if canImport(PDFKit) && os(macOS)` (or `#if canImport(PDFKit)` plus an `os(macOS)` guard if the team prefers to keep the protocol cross-platform — see Task 1). The CLI is macOS-only, so this is invisible at the CLI. Justification: keeping extraction macOS-only preserves the M1/M2 discipline that **no PHI-bearing parse logic ships in the iOS app** and that the network/LLM edge never compiles into the on-device writer.
- **The test suite MUST run on a macOS runner (T3 — false-green guard).** Because the entire M3 (and M2 XML) suite is `#if canImport(PDFKit) && os(macOS)`-guarded, on a **Linux** runner every M3 test simply **compiles out** and `swift test` is trivially green while testing NOTHING — a false green for Success Criterion 2. Therefore: M3 (and M2) tests MUST execute on **macOS**. If this repo has GitHub Actions CI, it MUST use a `macos-latest` runner for the test job; a Linux-only CI would silently skip M3/M2 and is not acceptable as the green gate. **If there is NO CI and tests run locally**, state that explicitly in the PR (the green gate is the local macOS `swift test`), and note that any future Linux CI would skip M3/M2. As a tripwire, add **one un-guarded sentinel test** (Task 1) that fails loudly if the PDF path compiled out on macOS — see `testPDFPathIsCompiledInOnMacOS` below.
- **NO Bridge Document schema change.** PDF/LLM data maps into the existing `BridgeDocument`, `Observation` (incl. its already-present `confidence` and `sourceLocator`), `ObservationValue`, `CodeableRef`, `SourceLocator`, `Source` (`kind = .pdf`, `extractor = Extractor(engine: "<provider>-llm", version: ...)`). **Task 1 pins this as a verified, test-first fact** before any extraction code is written. The only "additive" thing M3 introduces is *populating* fields that M1/M2 always left at `confidence: 1.0` / `sourceLocator: nil` — that is data, not schema, and is non-breaking for M1/M2 (their output is byte-identical; the new fields already encode/decode).
- **Same `DocumentParser`-shaped contract.** The PDF path produces a `ParseResult` (`[Observation]` + `[Skip]`) exactly like the other parsers, so everything downstream (mapping resolve, dedupe, validate, write, log) is reused unchanged. Because `DocumentParser.parse` is **synchronous and non-throwing-of-network** by contract, the *async network* lives in the injected `LLMExtractor`; `PDFExtractor` bridges (see Task 5 for the sync/async boundary decision).
- **BYO API key — env var + optional `--api-key` flag. NEVER persisted, NEVER logged.** Key resolution order: `--api-key <value>` flag (highest) > provider env var (`ANTHROPIC_API_KEY` / `OPENAI_API_KEY`) > **fail with a clear, key-value-free error**. The key is held in memory only, passed to the adapter, and used solely as an `Authorization`/`x-api-key` header. It is **never** written to the config TOML, never to the `*.bridge.json`, never to logs (not even at `--verbose`), and never to error messages. Tasks 7/9 pin "no key in logs/errors" with explicit tests.
- **No network in tests. No real API key in CI.** Every extraction test injects a **mock `LLMExtractor`** returning canned JSON. The two real adapters (Anthropic/OpenAI) are unit-tested at the **request-construction and response-decoding** seams (pure functions: build the request body from `LLMRequest`; decode a canned provider response payload) — the actual `URLSession.data(for:)` call is the only un-unit-tested line and is covered by a manual/integration smoke step, never in CI. **No test ever performs a real HTTP request or reads a real key.**
- **Untrusted LLM output — validate, don't trust (D2 = belt-and-suspenders).** The adapters force JSON **natively** (OpenAI `response_format` json_schema; **Anthropic assistant prefill** — NOT tool-use, see Task 7 T1 note), AND the shared `LLMResponseContract` decoder STILL validates every reply as untrusted: it **rejects** malformed JSON, **drops** entries missing a usable code/date/value (recording a `Skip` with the existing reasons), **validates** `confidence` to `0...1` (out-of-range → entry rejected, not silently clamped), and never lets a hallucinated field reach the document un-validated. The downstream `BridgeKit.validate` is the final backstop (it already errors on `confidence` outside `0...1`, non-finite quantities, and `mapping` on a `.string`).
- **Synthetic fixtures ONLY (public repo).** All PDF fixtures are **hand-authored synthetic** PDFs containing synthetic identities only ("Jane Public" / "John Sample", DOB `2000-01-01` / `1980-06-15`) and synthetic clinical values. **No real patient PDF is EVER committed, referenced by path, or pasted into any tracked file.** Generate fixture PDFs deterministically (see Task 2 "Fixture generation"). All canned LLM-response JSON fixtures are likewise synthetic. Re-run the Task 0 content denylist scan before every fixture commit.
- **Deterministic *assembly*, non-deterministic *extraction*.** The LLM step is inherently non-deterministic — that is the whole reason M3 follows the deterministic parsers and is gated by human review. But everything the test suite asserts is deterministic: mock-extractor in, fixed `now:` clock, stable ids from `ObservationID.derive`, `BridgeJSON.encoder`. Tests never assert on real-model output.
- **Commit protocol — NEVER run `git commit` or `git push`.** All implementation runs in a **git worktree on a feature branch** (never `main`; created in Task 0 off **freshly-fetched** `origin/main`). Each "Commit" step: `git add <files>` (and `git rm` for deletions) to stage — the only raw git permitted, because `github-agent-commit` reads `git diff --cached` — then **`github-agent-commit "<message>"`** (signed; refuses `main`; auto-creates the remote branch; resets local to `origin/<branch>` after, so stage everything first). Do NOT run `git commit`/`push`/`fetch`/`reset`/`checkout`/`update-ref`; read-only `git status`/`git diff` is fine. All GitHub API / PRs use **`agent-gh`**, never raw `gh`. The milestone lands as **one PR** to `main` via `agent-gh pr create … --body-file <file>`. **Per-shell env (multi-agent):** the `GITHUB_APP_*` vars load via direnv from the repo-root `.envrc`, which may NOT auto-load inside a worktree subdir or a teammate's fresh shell. Every executor must run the Task 0 env check **in the exact shell it will commit from**, before its first `github-agent-commit`; if empty there, `direnv allow` at the worktree path or export the three vars — never fall back to `git commit`.
- **Verify external APIs empirically.** PDFKit page-text extraction (`PDFDocument(data:)`, `PDFPage.string`), the URLSession async API, and each provider's request/response JSON shape (incl. the native JSON-forcing fields and current model ids — D6) MUST be confirmed against real builds/docs before trusting them. Use Context7 / provider docs for the **current** Anthropic Messages and OpenAI request schemas — model names and field names drift. TDD catches drift on the pure seams; the network line is the only place a doc-mismatch can hide, so the manual smoke step (Task 9) is mandatory before the PR.
- TDD throughout: failing test first, minimal implementation, green, commit. **Error handlers tested before happy path** (missing key, malformed PDF, over-page-limit PDF, malformed LLM JSON, low/invalid confidence, multi-patient — all before the success path).

---

## Milestone overview

**M3 delivers:**
- `PDFText` — macOS-only PDFKit helper that extracts per-page text from PDF bytes (`canParse` via `%PDF` magic bytes; `pages(_:) -> [String]`; refuses over `maxPages = 30` — D3).
- `LLMExtractor` — a provider-agnostic protocol (one async method) plus request/response value types, designed so a third provider is a new conformance.
- `AnthropicExtractor` (default — D1) and `OpenAIExtractor` — two concrete adapters (request construction incl. native JSON-forcing per D2 + response decoding pure-tested; the URLSession call isolated; bounded 2× retry per D5).
- A strict, untrusted-output **response contract** (`LLMObservation` JSON + top-level `patients[]` — D4) and its validating decoder → `[Observation]` with model `confidence` + `sourceLocator` (page/snippet), `mapping = nil`.
- `PDFExtractor` — bridges PDF text + an injected `LLMExtractor` into a `ParseResult`, reusing the M1/M2 mapping/dedupe/validate pipeline. Enforces **multi-patient refusal** (double-protection, mirroring M2).
- CLI integration: `.pdf` input routes to the LLM path, defaults to Anthropic (D1), requires a key **only then** (env var or `--api-key`), stamps `source.kind = .pdf`, and reuses the existing write/log/exit-code surface.
- Key handling: env var + `--api-key`, never persisted, never logged.

**Scope boundaries — explicitly deferred:**
- **OCR of image-only / scanned PDFs.** M3 extracts the **text layer** only (PDFKit `PDFPage.string`). A PDF with no extractable text → refuse with the existing `ParseError`/`Skip` discipline (Task 2/8). Vision-model image upload and OCR are a later milestone.
- **Multi-modal / image-region locators.** `sourceLocator` carries `page` + `snippet` (the schema's existing fields). Pixel-rectangle regions on the page are out of scope.
- **Streaming, function-calling/tool-use, or batch provider APIs.** M3 uses a single non-streaming Messages/Chat-Completions request per document and parses the full response. **No tool-use at all** — Anthropic JSON-forcing is assistant **prefill** (D2/T1), not tool-use.
- **Token-budget chunking for very large PDFs (D3).** M3 sends per-page text up to `maxPages = 30`; documents exceeding the cap are **refused** with a clear error rather than silently chunk-merged. Sliding-window chunk reconciliation is later.
- **Provider retry/circuit-breaker tuning beyond a bounded 2× retry (D5).** A bounded retry on transient (429/5xx/timeout) is in scope; full backoff policy tuning is later.
- **A third provider** (the protocol is built for it, but only Anthropic + OpenAI ship in M3).
- HealthKit writes, the iOS writer, the iOS review screen — still out of scope per the roadmap (M3 *produces* the confidence/locator data the review screen will consume).

---

## No schema change (decision + justification)

**Decision: M3 introduces ZERO `BridgeKit` schema change.** Justification, verified against source:

| Field M3 needs | Already in schema? | Evidence |
|---|---|---|
| `source.kind = .pdf` | ✓ yes | `SourceKind` declares `case fhir, ccda, pdf` |
| `extractor { engine, version }` | ✓ yes | `Source.extractor: Extractor` |
| per-observation `confidence: Double` | ✓ yes | `Observation.confidence` (M1/M2 set `1.0`) |
| `sourceLocator { page?, snippet? }` | ✓ yes | `Observation.sourceLocator: SourceLocator?` (M1/M2 set `nil`) |

The schema was **designed** for the PDF path (spec §2 design note: "`sourceLocator?` … mainly for the future PDF path"; "`confidence: Double` — 1.0 for deterministic parsers"). M3 *populates* these fields for the first time. This is **non-breaking for M1/M2**: their emitted documents are byte-identical (they still set `confidence: 1.0`, `sourceLocator: nil`), and the encoder already round-trips both fields. Task 1 pins this with a test that constructs a PDF-shaped `Observation` (model confidence `< 1.0`, a populated `SourceLocator`) and round-trips it through `BridgeJSON`. **If any of the four rows above is false in the fresh worktree, STOP** — the schema drifted and the "no schema change" premise must be re-evaluated with the user before proceeding.

---

## Provider protocol design (decision + justification)

**Decision: one async protocol, value-typed request/response, two adapters, pure seams.**

```swift
// I/O at the edge — the ONLY async, network-touching surface in M3.
public protocol LLMExtractor: Sendable {
    /// Send the page text + extraction instructions; return the model's raw structured reply.
    /// Throws LLMError on transport/auth/decoding failure. NEVER logs or returns the API key.
    func extract(_ request: LLMRequest) async throws -> LLMRawResponse
}

public struct LLMRequest: Sendable, Equatable {
    public let pages: [String]        // per-page extracted text
    public let instructions: String   // the extraction prompt (the JSON contract)
    public let model: String          // provider model id (resolved at impl time — D6)
}

public struct LLMRawResponse: Sendable, Equatable {
    public let jsonText: String       // the model's reply, expected to be the contract JSON
}

public enum LLMError: Error, Equatable {
    case missingAPIKey
    case transport(String)            // network/timeout — message MUST NOT contain the key
    case http(status: Int)            // 401/403/429/5xx
    case malformedResponse(String)    // provider envelope unpar-seable
}
```

Why this shape:

| Decision | Rationale |
|---|---|
| **Protocol = one async method** | The only thing that varies per provider is "send this request, get back the model's text." Everything else (prompt building, response-contract decoding, observation mapping) is provider-independent and lives in pure functions tested without network. |
| **`LLMRawResponse.jsonText` (not decoded contract)** | Each provider wraps the model's reply in a *different envelope* (Anthropic `content[0].text` — prefill, T1; OpenAI `choices[].message.content`). The adapter's job ends at "extract the assistant JSON text"; the **shared** `LLMResponseContract` decoder (Task 4) parses + validates the contract JSON. This keeps the untrusted-output validation in ONE place, not duplicated per provider (and is the validating half of D2). |
| **Adapters split into pure + impure** | `AnthropicExtractor`/`OpenAIExtractor` each expose internal pure functions `makeRequest(_:) -> URLRequest` (encoding the provider's native JSON-forcing — D2) and `parseEnvelope(_ data: Data) throws -> LLMRawResponse`, unit-tested directly. Only `extract(_:)` calls `URLSession.shared.data(for:)`, wrapping the two pure halves + the bounded 2× retry (D5). The session is injectable (`init(session: URLSession = .shared)`) so a future test could stub it, but CI relies on the pure-seam tests + a mock `LLMExtractor` at the `PDFExtractor` level. |
| **Key passed in, never stored** | The adapter takes the key at construction (resolved by the CLI), uses it only to set the auth header, and never logs it or writes it anywhere. |
| **Third provider = new conformance** | Adding e.g. a local model = implement `LLMExtractor` + its two pure halves. No change to `PDFExtractor`, the contract decoder, or the CLI routing. |

**Auth + native JSON-forcing + env vars per provider (D1/D2/D6 — verify current spelling/model ids against provider docs via Context7 at Task 7/8):**

| Provider | Header | Env var | Native JSON-forcing (D2) | Notes |
|---|---|---|---|---|
| Anthropic Messages — **DEFAULT (D1)** | `x-api-key: <key>` + `anthropic-version: <date>` | `ANTHROPIC_API_KEY` | **assistant PREFILL** — seed the assistant turn with `{` so the model continues valid JSON (Anthropic has NO `response_format`; this is the chosen mechanism, NOT tool-use) | Body: `{ model, max_tokens, messages: [user, {role:"assistant", content:"{"}] }`. Reply JSON at `content[0].text` (prepend the `{` seed if the API omits it). **Model id + version header resolved at impl time (D6)** — do NOT hardcode here; record the resolved id in Task 7. |
| OpenAI Chat Completions — `--provider openai` | `Authorization: Bearer <key>` | `OPENAI_API_KEY` | `response_format: { type: "json_schema", json_schema: <the contract schema> }` — `makeRequest` encodes it | Body: `{ model, messages, response_format }`. Reply JSON at `choices[0].message.content`. **Model id + endpoint resolved at impl time (D6)** — record the resolved id in Task 8. |

Both adapters force JSON natively (OpenAI `response_format` json_schema; **Anthropic assistant prefill** — see the T1 note in Task 7) **and** the shared `LLMResponseContract` decoder still treats every reply as untrusted (D2). **D1:** when neither `--provider` nor key context disambiguates, the CLI defaults to **Anthropic**.

---

## File Structure (additions/changes only)

```
Sources/
  HealthBridgeParsing/
    PDFText.swift              # NEW — PDFKit page-text extraction + %PDF magic-byte sniff + maxPages=30 guard (macOS-guarded)
    LLMExtractor.swift         # NEW — protocol + LLMRequest/LLMRawResponse/LLMError value types
    LLMResponseContract.swift  # NEW — the strict JSON contract (+ top-level patients[]) + validating decoder -> [Observation]+[Skip]
    AnthropicExtractor.swift   # NEW — Anthropic Messages adapter (assistant-PREFILL JSON-forcing, T1; pure request/envelope + URLSession edge + 2x retry)
    OpenAIExtractor.swift      # NEW — OpenAI Chat Completions adapter (response_format json_schema; same split)
    PDFExtractor.swift         # NEW — PDF text + injected LLMExtractor -> ParseResult; multi-patient refusal
    ExtractionPrompt.swift     # NEW — builds the instruction string embedding the JSON contract
  healthbridge/
    HealthBridge.swift         # MODIFIED — route .pdf to the LLM path; default provider=Anthropic; resolve key (env/--api-key); stamp .pdf
Tests/
  HealthBridgeParsingTests/
    PDFTextTests.swift             # NEW
    LLMResponseContractTests.swift # NEW (the untrusted-output validation suite)
    AnthropicExtractorTests.swift  # NEW (pure request/envelope seams only — no network)
    OpenAIExtractorTests.swift     # NEW (pure request/envelope seams only — no network)
    PDFExtractorTests.swift        # NEW (mock LLMExtractor; multi-patient refusal; happy path)
    Fixtures/
      pdf-minimal.pdf                  # NEW — synthetic 1-page PDF, one vital + one lab, "Jane Public"
      pdf-two-page.pdf                 # NEW — synthetic 2-page PDF (page locator assertions)
      pdf-no-text.pdf                  # NEW — synthetic image-only/empty-text PDF -> refuse
      pdf-over-limit.pdf               # NEW — synthetic 31-page PDF -> refuse (D3)
      not-a-pdf.bin                    # NEW — bytes without %PDF magic -> canParse == false
      llm-response-valid.json          # NEW — canned valid contract reply (vital+lab, confidences, single patient)
      llm-response-malformed.json      # NEW — not valid JSON -> malformedResponse
      llm-response-missing-fields.json # NEW — entries missing code/date/value -> Skips
      llm-response-bad-confidence.json # NEW — confidence > 1 / < 0 -> entry rejected
      llm-response-multi-patient.json  # NEW — top-level patients[] with two patients -> refuse (D4)
      anthropic-envelope.json          # NEW — a sample Anthropic API envelope (content[0].text — the PREFILL shape, T1)
      openai-envelope.json             # NEW — a sample OpenAI API envelope (choices[].message.content)
  healthbridgeTests/
    Fixtures/
      pdf-patient.pdf                  # NEW — synthetic PDF, "Jane Public"/2000-01-01 (cross-check context)
```

All PDF and JSON fixtures are **hand-authored synthetic** (see Global Constraints). Keep them minimal: only what each test asserts on.

**Fixture generation (synthetic PDFs):** generate the PDF fixtures deterministically from text so no real document is ever involved — e.g. a tiny one-shot Swift/Quartz (`CGContext`/`PDFKit`) snippet or a checked-in generator the test target can run, OR author them via a headless tool that lays synthetic strings onto pages. The generator script itself contains only synthetic identities. Do NOT hand-binary-edit a real PDF. The `pdf-no-text.pdf` fixture is a PDF whose page has no text layer (e.g. a single drawn rectangle), to exercise the "no extractable text" refusal; `pdf-over-limit.pdf` has 31 trivial pages to exercise the D3 page-cap refusal.

---

## PDF/LLM → Bridge Document mapping

`PDFExtractor` walks the validated contract entries and maps each to one `Observation`:

| Contract entry field | Bridge `Observation` field | Rule |
|---|---|---|
| `loinc` (string) + `display` | `code = CodeableRef(system: "http://loinc.org", code: loinc, display: display)` | LOINC-coded (so the **existing** `MappingTable` applies). No LOINC → `Skip(.noCode)`. |
| `value` (number) **or** `valueText` (string) | `value = .quantity(Double)` or `.string(String)` | Exactly one present. Quantity → `rawValue` via the shared overflow-safe `stableNumberString`. Non-finite/neither → `Skip(.unrepresentableValue)`. |
| `unit` (string?) | `unit` | Verbatim (UCUM) for quantities; `nil` for qualitative. |
| `effectiveDate` (ISO-8601 / yyyy-mm-dd) | `effectiveDate` | Parsed UTC (date-only → UTC midnight), reusing the M1 UTC discipline. Unparseable/absent → `Skip(.noDate)`. |
| `category` ("vital"/"lab"/"other") | `category` | Mapped to `ObservationCategory`; unknown → `.other`. |
| `confidence` (0…1) | `confidence` | **From the model.** Out of `0...1` → entry **rejected** (treated as malformed, NOT silently clamped). |
| `page` (int?), `snippet` (string?) | `sourceLocator = SourceLocator(page:snippet:)` | The locator back into the PDF. `nil` allowed (then `sourceLocator = nil`). |
| top-level `patients[]` (D4) | — (binding cross-check) | Not an observation. `> 1` distinct patient → refuse (Task 6). |
| `mapping` | always `nil` | The CLI resolves `mapping` via `MappingTable` afterward, exactly as for FHIR/C-CDA. |

`id = ObservationID.derive(subjectId:system:code:effectiveDate:rawValue:unit:)` — **identical** derivation to the other paths, so a body weight extracted from a PDF dedupes against the same weight from FHIR/C-CDA (same subject+code+date+value+unit → same id). The id does **not** depend on `confidence` or `sourceLocator` (those are not in `derive`), which is correct: two extractions of the same clinical fact at different confidences are the same observation.

---

## Task 0: Repository preflight (no commit)

**Purpose:** establish the worktree and verify the environment BEFORE any code is written. No commit. (Same gate as M1/M2 Task 0; re-run it — M3 is a fresh worktree.)

- [ ] **Step 1: Verify the local `origin/main` ref is FRESH — the lead must `git fetch` first (the agent cannot).**

**CRITICAL — stale-origin-ref trap:** at plan-authoring time the local `origin/main` ref pointed at `f371aa1` (M1 / PR #1 only) and did **NOT** contain M2 (PR #2, `71d4d979`) — `ParserRegistry.swift`/`CCDAParser.swift` were absent from the local ref. The agent-helper rule **blocks the agent from `git fetch`**. So **the human lead runs `git fetch origin` before the worktree is created.** Confirm freshness:
```
git log --oneline -3 origin/main      # MUST show the M2 merge (PR #2) at the top, not stop at f371aa1
git ls-tree -r --name-only origin/main | rg -i 'CCDAParser|ParserRegistry'   # MUST list both (proves M2 is present)
```
If the M2 commit / files are absent, STOP and ask the lead to `git fetch origin` — do NOT branch off a stale ref (you would build M3 on top of M1 and clobber/miss M2).

- [ ] **Step 2: Create the feature worktree — BRANCHED OFF freshly-fetched `origin/main`**
```
git worktree add -b bridgekit-m3 ../bridgekit-m3 origin/main
cd ../bridgekit-m3
git branch --show-current        # must print "bridgekit-m3", NOT "main"
ls Sources/HealthBridgeParsing   # MUST list FHIRParser.swift, CCDAParser.swift, ParserRegistry.swift, DocumentParser.swift
```
Expected: branch `bridgekit-m3`; `Sources/HealthBridgeParsing` contains BOTH the M1 FHIR parser AND the M2 C-CDA parser + registry. If C-CDA/registry are missing, STOP — the ref was stale (redo Step 1). (Do NOT `git fetch`/`pull`/`reset` from the agent.)

- [ ] **Step 3: Verify the GitHub App commit env (in THIS shell)**
```
for v in GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY; do
  printf '%s: %s\n' "$v" "$(printenv "$v" >/dev/null 2>&1 && echo SET || echo empty)"
done
```
Expected: all three `SET`. If any is `empty`, `direnv allow` at the worktree path or export them — STOP before any `github-agent-commit`; never fall back to `git commit`.

- [ ] **Step 4: PHI / secrets guardrail — no private data, no real identities, no keys tracked**

(a) No processed output, private PDFs, or real-document filenames tracked:
```
git ls-files | rg -i 'bridge\.json$|samples/private/|AmbulatorySummary|\.pdf$' | rg -iv 'Tests/.*Fixtures/.*\.pdf$' && echo "REVIEW — non-fixture PDF or PHI tracked, STOP" || echo "clean"
```
(Only synthetic `Tests/**/Fixtures/*.pdf` are allowed; any other tracked `.pdf` is a stop.)

(b) **No real patient identity in any tracked file** (fixtures are synthetic only):
```
git ls-files -z 'Tests/**' 'Sources/**' | xargs -0 rg -l -i 'Feather|Caleb|Stephen|2015-04-12|1975-01-01' 2>/dev/null && echo "REAL IDENTITY — STOP" || echo "clean"
```

(c) **No API key committed** (BYO key is env/flag only, never tracked):
```
git ls-files -z 'Sources/**' 'Tests/**' | xargs -0 rg -l -iE 'sk-[A-Za-z0-9]|sk-ant-|ANTHROPIC_API_KEY=|OPENAI_API_KEY=' 2>/dev/null && echo "KEY LEAK — STOP" || echo "clean"
```
Expected: `clean` for all three. **Re-run (a)+(c) before every commit that adds a fixture or touches an adapter.**

- [ ] **Step 5: Read what M2 actually shipped (routing seam) + toolchain + green baseline**

Read the real files before designing the CLI route (do NOT assume the M2-plan text matches the merged code):
```
# Read these, do not just grep:
#   Sources/HealthBridgeParsing/ParserRegistry.swift   (how detection/routing works)
#   Sources/healthbridge/HealthBridge.swift            (does BridgeBuilder route via registry now? how is Source.kind stamped? how is patientCount handled?)
swift --version            # expect Swift 5.9+
swift build && swift test  # M1+M2 must be green on this worktree before adding M3
```
**Record these explicitly (Tasks 7–9 depend on them — T2):**
  - (a) Does `ParserRegistry.detect`/`select` return a **`DocumentParser` instance** (so a parser is dispatched generically) or does it merely **route by `canParse`** (the CLI picks the parser)? This decides how the PDF special-case attaches — see the Task 9 T2 decision.
  - (b) Is the `healthbridge` command (and `@main`) a **sync `ParsableCommand`** or an **`AsyncParsableCommand`**? `PDFExtractor.extractDocument` is async; if the command is sync, Task 9 must convert it (a rippling change — see Risks).
  - (c) The exact `BridgeBuilder.build` signature, how `Source.kind`/`Extractor` are stamped, and how the `Parse` command does multi-patient refusal.

Expected: all existing tests pass. If red, STOP — do not layer M3 on a red baseline.

---

## Task 1: Pin "no schema change" — confidence + locator round-trip (test-first)

**Purpose:** make "M3 adds no schema change; confidence + sourceLocator already exist and round-trip" a verified, test-pinned fact before any extraction code.

**Files:**
- Test: `Tests/HealthBridgeParsingTests/PDFSchemaTargetTests.swift`

- [ ] **Step 1: Write the pinning test:**
```swift
import XCTest
import BridgeKit
@testable import HealthBridgeParsing

/// Pins that M3 maps INTO the existing schema with no changes: SourceKind.pdf exists,
/// and an Observation carries a model confidence (<1) and a populated SourceLocator that round-trip.
final class PDFSchemaTargetTests: XCTestCase {
    func testPDFSourceKindExists() {
        XCTAssertEqual(SourceKind.pdf.rawValue, "pdf")
    }
    func testObservationCarriesConfidenceAndLocator() throws {
        let o = Observation(
            id: "x", code: CodeableRef(system: "http://loinc.org", code: "29463-7", display: "Body weight"),
            name: "Body weight", value: .quantity(72.5), unit: "kg",
            effectiveDate: Date(timeIntervalSince1970: 0), category: .vital,
            mapping: nil, confidence: 0.82, sourceLocator: SourceLocator(page: 2, snippet: "Weight 72.5 kg"))
        let data = try BridgeJSON.encoder.encode(o)
        let back = try BridgeJSON.decoder.decode(Observation.self, from: data)
        XCTAssertEqual(back.confidence, 0.82, accuracy: 1e-9)
        XCTAssertEqual(back.sourceLocator?.page, 2)
        XCTAssertEqual(back.sourceLocator?.snippet, "Weight 72.5 kg")
    }

    /// T3 sentinel — UN-guarded (no `#if os(macOS)` around the test): fails loudly if the PDF path
    /// was compiled OUT on the platform that is supposed to run it. On macOS the guarded path MUST
    /// be present; on Linux it is legitimately absent (and the test records that M3 was NOT exercised),
    /// so a Linux run can never masquerade as a passing M3 run. Tighten the macOS assertion once
    /// `PDFText` exists (Task 2): replace the `true` with `PDFText.isPDF(Data("%PDF".utf8))`.
    func testPDFPathIsCompiledInOnMacOS() {
        #if os(macOS)
        XCTAssertTrue(true, "M3 PDF path compiled in on macOS")   // Task 2: -> XCTAssertTrue(PDFText.isPDF(Data("%PDF".utf8)))
        #else
        // Not macOS: M3 PDF path is intentionally compiled out. This run did NOT exercise M3 —
        // the macOS green gate (T3) is the authoritative one. Marked, not silently green.
        print("NOTE: M3 PDF path compiled out (non-macOS) — M3 NOT exercised on this runner (T3).")
        #endif
    }
}
```
> If `BridgeJSON.decoder`/`.encoder` spelling differs in the worktree, adjust to the real symbol read in Task 0. If `SourceLocator` or `confidence` does not exist, STOP — the "no schema change" premise is invalid; escalate to the user.
>
> **T3 sentinel:** `testPDFPathIsCompiledInOnMacOS` is intentionally UN-guarded so a Linux runner cannot pass off a compiled-out M3 as green (it prints a NOTE instead). In Task 2, once `PDFText` exists, tighten the macOS branch to `XCTAssertTrue(PDFText.isPDF(Data("%PDF".utf8)))` so the sentinel actually touches the guarded path.

- [ ] **Step 2: Run to verify it passes immediately** — `swift test --filter PDFSchemaTargetTests`. Expected: PASS (these types already exist; the test guards against accidental schema edits and documents the M3 target).

- [ ] **Step 3: Commit**
```
git add Tests/HealthBridgeParsingTests/PDFSchemaTargetTests.swift
github-agent-commit "test(parsing): pin PDF/LLM maps into existing schema (confidence + locator round-trip)"
```

---

## Task 2: `PDFText` — PDFKit page-text extraction + %PDF sniff + maxPages guard (macOS-guarded)

**Files:**
- Create: `Sources/HealthBridgeParsing/PDFText.swift`
- Create fixtures: `pdf-minimal.pdf`, `pdf-two-page.pdf`, `pdf-no-text.pdf`, `pdf-over-limit.pdf`, `not-a-pdf.bin`
- Test: `Tests/HealthBridgeParsingTests/PDFTextTests.swift`

**Interfaces** (`#if canImport(PDFKit) && os(macOS)`-guarded):
- `enum PDFText`:
  - `static let maxPages = 30` — the D3 large-PDF cap.
  - `static func isPDF(_ data: Data) -> Bool` — cheap `%PDF` magic-byte prefix check (no full parse), for `canParse`.
  - `static func pages(_ data: Data) throws -> [String]` — `PDFDocument(data:)`; throws `ParseError.malformed` if the document won't open; **throws `ParseError.malformed("PDF exceeds \(maxPages)-page limit; refusing")` if `pageCount > maxPages` (D3)**; per-page `PDFPage.string`; throws `ParseError.malformed("no extractable text")` if every page's text is empty/whitespace.

> **Verify against a real build:** `PDFDocument(data:)` returns optional; `PDFDocument.pageCount`; `PDFPage.string` returns `String?`. Confirm against `pdf-minimal.pdf` before relying on them. The magic-byte check is pure byte work (`data.starts(with: Data("%PDF".utf8))`) and needs no framework. **Page-cap check happens BEFORE text extraction** so an oversized PDF is rejected cheaply.

- [ ] **Step 1: Generate the five fixtures** (synthetic; see "Fixture generation"). `pdf-minimal.pdf`: one page incl. "Jane Public", "Body weight 72.5 kg", "ALT 22 U/L". `pdf-two-page.pdf`: page 1 a vital, page 2 a lab. `pdf-no-text.pdf`: a page with no text layer. `pdf-over-limit.pdf`: 31 trivial pages (D3). `not-a-pdf.bin`: arbitrary non-`%PDF` bytes.

- [ ] **Step 2: Write the failing test** — error handlers (non-PDF, over-limit, no-text) BEFORE the happy path:
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
    func testNoTextPDFThrows() throws {
        XCTAssertThrowsError(try PDFText.pages(try fixture("pdf-no-text", "pdf"))) {
            guard case ParseError.malformed(let m) = $0 else { return XCTFail("expected .malformed") }
            XCTAssertTrue(m.lowercased().contains("text"), m)
        }
    }
    func testExtractsPageText() throws {
        let pages = try PDFText.pages(try fixture("pdf-minimal", "pdf"))
        XCTAssertEqual(pages.count, 1)
        XCTAssertTrue(pages[0].contains("72.5"))
    }
    func testTwoPagesPreserveOrder() throws {
        let pages = try PDFText.pages(try fixture("pdf-two-page", "pdf"))
        XCTAssertEqual(pages.count, 2)
    }
}
#endif
```

- [ ] **Step 3: Run to verify it fails** — `swift test --filter PDFTextTests`. Expected: FAIL — `PDFText` undefined. (This is also the empirical PDFKit verification gate: if `testExtractsPageText` won't go green, the `PDFPage.string` access is wrong for the toolchain — adjust until the page text contains the expected synthetic string.)

- [ ] **Step 4: Implement** `Sources/HealthBridgeParsing/PDFText.swift` (magic-byte sniff is unguarded; the PDFKit-using functions are guarded). Open `PDFDocument(data:)`; **check `pageCount > maxPages` first (D3)**; then map each page's `.string`; throw `ParseError.malformed` on open-failure, over-limit, and all-empty text.

- [ ] **Step 5: Run to verify pass** — `swift test --filter PDFTextTests`. Expected: all PASS.

- [ ] **Step 6: Commit** (re-run Task 0 Step 4(a) fixture/PHI scan first)
```
git add Sources/HealthBridgeParsing/PDFText.swift Tests/HealthBridgeParsingTests/PDFTextTests.swift Tests/HealthBridgeParsingTests/Fixtures/pdf-minimal.pdf Tests/HealthBridgeParsingTests/Fixtures/pdf-two-page.pdf Tests/HealthBridgeParsingTests/Fixtures/pdf-no-text.pdf Tests/HealthBridgeParsingTests/Fixtures/pdf-over-limit.pdf Tests/HealthBridgeParsingTests/Fixtures/not-a-pdf.bin
github-agent-commit "feat(parsing): PDFText — PDFKit page-text extraction, %PDF sniff, 30-page cap (macOS-guarded)"
```

---

## Task 3: `LLMExtractor` protocol + request/response value types + `ExtractionPrompt`

**Purpose:** define the provider-agnostic surface and the prompt builder — pure value types, no network, no adapter yet. This is the seam every later task plugs into.

**Files:**
- Create: `Sources/HealthBridgeParsing/LLMExtractor.swift` (protocol + `LLMRequest`/`LLMRawResponse`/`LLMError`)
- Create: `Sources/HealthBridgeParsing/ExtractionPrompt.swift` (`ExtractionPrompt.make(pages:) -> String` embedding the JSON contract)
- Test: `Tests/HealthBridgeParsingTests/LLMResponseContractTests.swift` (start it here with prompt + type tests; grows in Task 4)

- [ ] **Step 1: Write the failing tests** — assert: `LLMRequest` is `Equatable`/`Sendable` and holds pages/instructions/model; `LLMError` cases exist; `ExtractionPrompt.make(pages:)` produces a non-empty instruction string that (a) names the exact JSON contract keys (`loinc`, `value`/`valueText`, `unit`, `effectiveDate`, `category`, `confidence`, `page`, `snippet`, and the top-level `patients`) and (b) instructs the model to **return ONLY JSON** and to **set confidence honestly / omit uncertain entries**. (Assert on substrings of the prompt — these are the load-bearing instructions the contract decoder depends on.)
```swift
func testPromptNamesContractKeys() {
    let p = ExtractionPrompt.make(pages: ["Body weight 72.5 kg"])
    for key in ["loinc", "effectiveDate", "confidence", "snippet", "patients"] { XCTAssertTrue(p.contains(key), key) }
    XCTAssertTrue(p.lowercased().contains("json"))
}
```

- [ ] **Step 2: Run to verify it fails** — `swift test --filter LLMResponseContractTests`. Expected: FAIL — types/prompt undefined.

- [ ] **Step 3: Implement** the protocol + value types + `ExtractionPrompt.make`. The prompt embeds the contract (a JSON schema description + a one-line example, incl. the top-level `patients[]`) and the safety instructions. Keep it a pure function of `pages`. (The OpenAI adapter mirrors this same contract schema in its `response_format.json_schema` (D2); the Anthropic adapter does not need a schema object — it forces JSON via assistant prefill (T1) and relies on the prompt's embedded contract. Keep one canonical schema description that both reference.)

- [ ] **Step 4: Run to verify pass** — `swift test --filter LLMResponseContractTests`. Expected: PASS.

- [ ] **Step 5: Commit**
```
git add Sources/HealthBridgeParsing/LLMExtractor.swift Sources/HealthBridgeParsing/ExtractionPrompt.swift Tests/HealthBridgeParsingTests/LLMResponseContractTests.swift
github-agent-commit "feat(parsing): LLMExtractor protocol + request/response types + extraction prompt"
```

---

## Task 4: `LLMResponseContract` — the untrusted-output validating decoder (error handlers first)

**Purpose:** parse the model's JSON into `[Observation]` + `[Skip]`, **rejecting/dropping** anything that doesn't meet the contract. This is the security-critical heart of M3 and the **validating half of D2** (native JSON-forcing does NOT remove the need to validate — the decoder still treats output as untrusted). Error paths are written and made green BEFORE the happy path.

**Files:**
- Modify: `Sources/HealthBridgeParsing/LLMResponseContract.swift` (new)
- Create fixtures: `llm-response-valid.json`, `llm-response-malformed.json`, `llm-response-missing-fields.json`, `llm-response-bad-confidence.json`
- Test: extend `LLMResponseContractTests`

**Interface:**
- `enum LLMResponseContract`:
  - `static func decode(_ jsonText: String, subjectId: String) throws -> ParseResult` — parses the contract JSON; throws `ParseError.malformed` on non-JSON / wrong top-level shape; per-entry: missing LOINC → `Skip(.noCode)`; unparseable/absent date → `Skip(.noDate)`; neither numeric `value` nor `valueText`, or non-finite → `Skip(.unrepresentableValue)`; `confidence` outside `0...1` → entry **rejected** (record a `Skip(.unrepresentableValue)` with a label noting bad-confidence, do NOT clamp); otherwise → `Observation` with model `confidence`, `sourceLocator` from `page`/`snippet`, `mapping = nil`, id via `ObservationID.derive`. (The top-level `patients[]` is parsed but enforced in Task 6 at the `PDFExtractor` level, so the decoder can also expose the parsed patients to its caller — decide a small `DecodedResponse` wrapper, OR keep `decode` returning `ParseResult` and add a sibling `patients(_:)` accessor. Pick one in Task 6.)

- [ ] **Step 1: Create fixtures.** `llm-response-valid.json` — a top-level `{ "patients": [{"name":"Jane Public","dob":"2000-01-01"}], "observations": [ {loinc, value, unit, effectiveDate, category, confidence, page, snippet}, {…valueText qualitative…} ] }` with one vital (conf 0.9) + one lab (conf 0.7). `llm-response-malformed.json` — `not json{`. `llm-response-missing-fields.json` — entries variously missing `loinc` / `effectiveDate` / value. `llm-response-bad-confidence.json` — one entry `confidence: 1.4`, one `confidence: -0.1`.

- [ ] **Step 2: Write failing tests — error handlers first:**
```swift
func testMalformedJSONThrows() throws {
    XCTAssertThrowsError(try LLMResponseContract.decode("not json{", subjectId: "s")) {
        guard case ParseError.malformed = $0 else { return XCTFail("expected .malformed") }
    }
}
func testMissingFieldsBecomeSkips() throws {
    let r = try LLMResponseContract.decode(loadFixtureText("llm-response-missing-fields"), subjectId: "s")
    XCTAssertEqual(r.observations.count, 0)
    XCTAssertTrue(r.skipped.contains { $0.reason == .noCode })
    XCTAssertTrue(r.skipped.contains { $0.reason == .noDate })
    XCTAssertTrue(r.skipped.contains { $0.reason == .unrepresentableValue })
}
func testOutOfRangeConfidenceRejectedNotClamped() throws {
    let r = try LLMResponseContract.decode(loadFixtureText("llm-response-bad-confidence"), subjectId: "s")
    XCTAssertEqual(r.observations.count, 0)              // both rejected
    XCTAssertEqual(r.skipped.count, 2)
}
func testValidResponseProducesObservations() throws {
    let r = try LLMResponseContract.decode(loadFixtureText("llm-response-valid"), subjectId: "s")
    let vital = try XCTUnwrap(r.observations.first { $0.category == .vital })
    XCTAssertEqual(vital.code?.system, "http://loinc.org")
    XCTAssertEqual(vital.confidence, 0.9, accuracy: 1e-9)
    XCTAssertNil(vital.mapping)
    XCTAssertNotNil(vital.sourceLocator?.page)
}
func testIdMatchesDerivationForSameContent() throws {
    let r = try LLMResponseContract.decode(loadFixtureText("llm-response-valid"), subjectId: "s")
    let o = try XCTUnwrap(r.observations.first { $0.category == .vital })
    // id must equal ObservationID.derive(... rawValue: stableNumberString(value) ...) — pin id-parity.
    XCTAssertFalse(o.id.isEmpty)
}
```

- [ ] **Step 3: Run to verify it fails** — `swift test --filter LLMResponseContractTests`. Expected: FAIL — `LLMResponseContract` undefined.

- [ ] **Step 4: Implement** the decoder. Use a `Codable` `LLMObservation` DTO for the entry (+ a top-level DTO with `patients` and `observations`), `JSONDecoder` over the top-level object. **Use the shared overflow-safe `stableNumberString`** for the quantity `rawValue` (extract M1/M2's helper into a shared internal func, or replicate the guarded version — single source of truth preferred). Date parsing reuses the UTC discipline (ISO-8601 with date-only → UTC midnight). Confidence validated, never clamped. Validate even though the adapters force JSON natively (D2 belt-and-suspenders).

- [ ] **Step 5: Run to verify pass** — `swift test --filter LLMResponseContractTests`. Expected: all PASS.

- [ ] **Step 6: Commit**
```
git add Sources/HealthBridgeParsing/LLMResponseContract.swift Tests/HealthBridgeParsingTests/LLMResponseContractTests.swift Tests/HealthBridgeParsingTests/Fixtures/llm-response-valid.json Tests/HealthBridgeParsingTests/Fixtures/llm-response-malformed.json Tests/HealthBridgeParsingTests/Fixtures/llm-response-missing-fields.json Tests/HealthBridgeParsingTests/Fixtures/llm-response-bad-confidence.json
github-agent-commit "feat(parsing): LLMResponseContract — validating decoder for untrusted LLM JSON"
```

---

## Task 5: `PDFExtractor` — PDF text + injected `LLMExtractor` → `ParseResult` (mock extractor)

**Purpose:** wire PDF text → prompt → injected extractor → contract decode → `ParseResult`, with **zero network** (a mock `LLMExtractor` in tests). Resolve the **sync/async boundary** here.

**Sync/async boundary decision:** `DocumentParser.parse` is **synchronous**. `LLMExtractor.extract` is **async**. Rather than retrofit `DocumentParser` to be async (which would touch the FHIR/C-CDA paths — out of scope, and they have no async work), **`PDFExtractor` exposes its own async method** `func extractDocument(_ data: Data, subjectId: String) async throws -> ParseResult` and does NOT conform to `DocumentParser`. The CLI calls it directly on the PDF branch. `canParse` stays a static `PDFText.isPDF`. (Rationale: the registry's `DocumentParser` detection can still *route* via `PDFExtractor.canParse`, but the *execution* is the async method — keeping the deterministic protocol sync-pure. Confirm in Task 0/9 how M2's registry exposes routing; if it routes by `canParse` only, this composes cleanly.)

**Files:**
- Create: `Sources/HealthBridgeParsing/PDFExtractor.swift`
- Test: `Tests/HealthBridgeParsingTests/PDFExtractorTests.swift` (with an in-file `MockLLMExtractor`)

- [ ] **Step 1: Write failing tests** with a mock extractor returning canned JSON (load `llm-response-valid.json` text):
```swift
struct MockLLMExtractor: LLMExtractor {
    let reply: String
    func extract(_ request: LLMRequest) async throws -> LLMRawResponse { .init(jsonText: reply) }
}
struct ThrowingLLMExtractor: LLMExtractor {
    let error: LLMError
    func extract(_ request: LLMRequest) async throws -> LLMRawResponse { throw error }
}

func testCanParseDetectsPDF() throws {
    XCTAssertTrue(PDFExtractor.canParse(try fixture("pdf-minimal", "pdf")))
    XCTAssertFalse(PDFExtractor.canParse(Data("not a pdf".utf8)))
}
func testExtractorErrorPropagates() async throws {   // error handler first
    let ex = PDFExtractor(extractor: ThrowingLLMExtractor(error: .http(status: 401)), model: "m")
    do { _ = try await ex.extractDocument(try fixture("pdf-minimal","pdf"), subjectId: "s"); XCTFail() }
    catch let e as LLMError { XCTAssertEqual(e, .http(status: 401)) }
}
func testNoTextPDFRefuses() async throws {
    let ex = PDFExtractor(extractor: MockLLMExtractor(reply: "{}"), model: "m")
    do { _ = try await ex.extractDocument(try fixture("pdf-no-text","pdf"), subjectId: "s"); XCTFail() }
    catch let e as ParseError { guard case .malformed = e else { return XCTFail() } }
}
func testHappyPathProducesObservations() async throws {
    let ex = PDFExtractor(extractor: MockLLMExtractor(reply: try fixtureText("llm-response-valid")), model: "m")
    let r = try await ex.extractDocument(try fixture("pdf-minimal","pdf"), subjectId: "s")
    XCTAssertFalse(r.observations.isEmpty)
    XCTAssertEqual(r.observations.first?.confidence, 0.9, accuracy: 1e-9)   // model confidence flows through
}
```

- [ ] **Step 2: Run to verify it fails** — `swift test --filter PDFExtractorTests`. Expected: FAIL.

- [ ] **Step 3: Implement** `PDFExtractor`: `static func canParse = PDFText.isPDF`; `extractDocument` = `PDFText.pages` (incl. the D3 page-cap) → `ExtractionPrompt.make` → `LLMRequest` → `extractor.extract` → `LLMResponseContract.decode`. PDF/text errors throw `ParseError`; extractor errors propagate as `LLMError`.

- [ ] **Step 4: Run to verify pass** — `swift test --filter PDFExtractorTests`. Expected: PASS.

- [ ] **Step 5: Commit**
```
git add Sources/HealthBridgeParsing/PDFExtractor.swift Tests/HealthBridgeParsingTests/PDFExtractorTests.swift
github-agent-commit "feat(parsing): PDFExtractor — PDF text + injected LLMExtractor (mock-tested, no network)"
```

---

## Task 6: Multi-patient refusal on the PDF path (PHI-safety parity, double-protection — D4)

**Purpose:** M1 refuses multi-patient FHIR bundles; M2 refuses multi-`recordTarget` C-CDA. The PDF path must refuse when the **LLM response's top-level `patients[]` lists more than one distinct patient** (D4) — the only multi-patient signal available for an opaque PDF. **Double-protection, mirroring M2.** **Error handler, test-first.**

**Files:**
- Modify: `Sources/HealthBridgeParsing/LLMResponseContract.swift` (expose the top-level `patients[]`) and `PDFExtractor.swift` (enforce)
- Create fixture: `llm-response-multi-patient.json`
- Test: extend `PDFExtractorTests`

- [ ] **Step 1: Create fixture** `llm-response-multi-patient.json` — top-level `"patients": [{"name":"Jane Public","dob":"2000-01-01"}, {"name":"John Sample","dob":"1980-06-15"}]` plus a couple of observations, synthetic identities.

- [ ] **Step 2: Write failing tests:**
```swift
func testRefusesMultiPatientResponse() async throws {
    let ex = PDFExtractor(extractor: MockLLMExtractor(reply: try fixtureText("llm-response-multi-patient")), model: "m")
    do { _ = try await ex.extractDocument(try fixture("pdf-minimal","pdf"), subjectId: "s"); XCTFail() }
    catch let e as ParseError {
        guard case .malformed(let m) = e else { return XCTFail() }
        XCTAssertTrue(m.lowercased().contains("patient"), m)
    }
}
func testSinglePatientResponseAccepted() async throws {
    let ex = PDFExtractor(extractor: MockLLMExtractor(reply: try fixtureText("llm-response-valid")), model: "m")
    _ = try await ex.extractDocument(try fixture("pdf-minimal","pdf"), subjectId: "s")  // no throw
}
```

- [ ] **Step 3: Run to verify it fails** — Expected: FAIL.

- [ ] **Step 4: Implement** the top-level `patients[]` parse + refusal (count of distinct patients `> 1` → `ParseError.malformed("multiple patients in PDF — refusing")`). Keep it conservative: identical/absent patient info proceeds; two distinct identities refuse. (Wire the decoder's `patients` through to `PDFExtractor` per the Task 4 wrapper/accessor decision.)

- [ ] **Step 5: Run to verify pass** — Expected: all PASS.

- [ ] **Step 6: Commit**
```
git add Sources/HealthBridgeParsing/LLMResponseContract.swift Sources/HealthBridgeParsing/PDFExtractor.swift Tests/HealthBridgeParsingTests/PDFExtractorTests.swift Tests/HealthBridgeParsingTests/Fixtures/llm-response-multi-patient.json
github-agent-commit "feat(parsing): PDF multi-patient refusal via top-level patients[] (single-subject parity)"
```

---

## Task 7: `AnthropicExtractor` — JSON-forcing via PREFILL + pure request/envelope seams (DEFAULT provider, no network in tests)

> **T1 [HIGH] — Anthropic JSON-forcing MUST be assistant PREFILL, not tool-use.** Anthropic's Messages API has **no `response_format: json_object`** (that is OpenAI-only). The two Anthropic mechanisms are not interchangeable for this plan: **PREFILL** (seed the assistant turn with `{`) keeps the reply at `content[0].text`, so `parseEnvelope` and `anthropic-envelope.json` below stay correct. **TOOL-USE** (`input_schema` + `tool_choice`) moves the reply into a `tool_use` block's `.input`, NOT `content[0].text` -> `parseEnvelope` would silently mis-parse. This plan locks **PREFILL**. **If tool-use is ever adopted later, `parseEnvelope` MUST read the `tool_use` block's `input`, not `content[0].text`.**

**Purpose:** the first real adapter and the **default provider (D1)**. `makeRequest` encodes Anthropic's **native JSON-forcing via assistant PREFILL (D2)** — seed the assistant turn with `{` so the model continues valid JSON; the reply stays in `content[0].text`. Unit-test the **pure** halves (request body construction; envelope parsing); the single `URLSession` line + the bounded 2× retry (D5) is the only un-unit-tested code (covered by Task 9 manual smoke). **Key-safety asserted here.** **Resolve and record the current model id + `anthropic-version` (D6) via Context7/provider docs at implementation time — do NOT hardcode a guessed id.**

**Files:**
- Create: `Sources/HealthBridgeParsing/AnthropicExtractor.swift`
- Create fixture: `anthropic-envelope.json` (a sample API envelope with the contract JSON in `content[0].text` — the PREFILL shape; NOT a tool-use `input` block)
- Test: `Tests/HealthBridgeParsingTests/AnthropicExtractorTests.swift`

**Interface:**
- `struct AnthropicExtractor: LLMExtractor` (`init(session: URLSession = .shared, apiKey: String, model: String)` — key + model passed at construction by the CLI; key held only for the request, never logged):
  - internal `func makeRequest(_ r: LLMRequest) throws -> URLRequest` — sets `x-api-key`, `anthropic-version`, JSON body with the user message PLUS a seeded `{role:"assistant", content:"{"}` PREFILL turn (D2); **pure** (no I/O). Does NOT use `tools`/`tool_choice`.
  - internal `static func parseEnvelope(_ data: Data) throws -> LLMRawResponse` — extracts the contract JSON from **`content[0].text`** (re-prepend the `{` seed if the API does not echo it); throws `LLMError.malformedResponse` on wrong shape.
  - `func extract(_:)` — `makeRequest` → `session.data(for:)` (bounded **2× retry on 429/5xx/timeout — D5**) → status check (401/403 → `LLMError.http`) → `parseEnvelope`.

- [ ] **Step 1: Create fixture** `anthropic-envelope.json` — realistic envelope carrying the contract JSON in **`content[0].text`** (the PREFILL shape: `{"content":[{"type":"text","text":"<contract JSON>"}], ...}`). (Verify the **current** Anthropic envelope shape via provider docs / Context7 (D6) before finalizing — but it MUST be the `content[0].text` prefill shape, not a `tool_use` block.)

- [ ] **Step 2: Write failing tests (pure seams + JSON-forcing + key safety):**
```swift
func testMakeRequestSetsAuthHeaderAndForcesJSON() throws {
    let ex = AnthropicExtractor(apiKey: "sk-ant-TESTKEY", model: "claude-x")
    let req = try ex.makeRequest(LLMRequest(pages: ["x"], instructions: "do", model: "claude-x"))
    XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-ant-TESTKEY")
    XCTAssertNotNil(req.value(forHTTPHeaderField: "anthropic-version"))
    XCTAssertEqual(req.httpMethod, "POST")
    let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
    XCTAssertTrue(body.contains("assistant"))                                      // PREFILL turn present (D2)
    XCTAssertFalse(body.contains("tool_choice") || body.contains("input_schema"))  // NOT tool-use (T1)
}
func testParseEnvelopeExtractsContractText() throws {
    let raw = try AnthropicExtractor.parseEnvelope(loadFixtureData("anthropic-envelope"))
    XCTAssertTrue(raw.jsonText.contains("observations") || raw.jsonText.contains("loinc"))
}
func testMalformedEnvelopeThrows() throws {
    XCTAssertThrowsError(try AnthropicExtractor.parseEnvelope(Data("{}".utf8))) {
        guard case LLMError.malformedResponse = $0 else { return XCTFail() }
    }
}
func testErrorDescriptionsNeverLeakKey() {   // key-safety
    let e = LLMError.transport("connection refused")
    XCTAssertFalse("\(e)".contains("sk-ant"))
}
```

- [ ] **Step 3: Run to verify it fails** — Expected: FAIL.

- [ ] **Step 4: Implement** `AnthropicExtractor`. Body per the **current** Messages API with the assistant-**prefill** JSON-forcing (D2; NOT tool-use — T1); `extract` wraps the pure halves around one `session.data(for:)` + the bounded 2× retry (D5). **No `print`/log of the key or request body anywhere.** Record the resolved model id + version header (D6) in a code comment + the PR notes.

- [ ] **Step 5: Run to verify pass** — Expected: PASS.

- [ ] **Step 6: Commit** (re-run Task 0 Step 4(c) key scan first)
```
git add Sources/HealthBridgeParsing/AnthropicExtractor.swift Tests/HealthBridgeParsingTests/AnthropicExtractorTests.swift Tests/HealthBridgeParsingTests/Fixtures/anthropic-envelope.json
github-agent-commit "feat(parsing): AnthropicExtractor — Messages adapter, native JSON-forcing + 2x retry"
```

---

## Task 8: `OpenAIExtractor` — JSON-forcing + pure request/envelope seams (no network in tests)

**Purpose:** the second adapter, proving the protocol generalizes (a third provider is now obviously "just another conformance"). `makeRequest` encodes OpenAI's **native JSON-forcing (D2)** — `response_format: { type: "json_schema", json_schema: <the contract schema> }`. Same pure-seam discipline + bounded 2× retry (D5). **Resolve and record the current model id + endpoint (D6) via Context7/provider docs.**

**Files:**
- Create: `Sources/HealthBridgeParsing/OpenAIExtractor.swift`
- Create fixture: `openai-envelope.json` (`choices[0].message.content` = the contract JSON)
- Test: `Tests/HealthBridgeParsingTests/OpenAIExtractorTests.swift`

**Interface:** `struct OpenAIExtractor: LLMExtractor` (`init(session:apiKey:model:)`): `makeRequest` sets `Authorization: Bearer <key>`, JSON body `{model, messages, response_format: {type:"json_schema", json_schema: …}}` (D2); `parseEnvelope` extracts `choices[0].message.content`; `extract` mirrors Anthropic's status-handling + bounded 2× retry (D5).

- [ ] **Step 1: Create fixture** `openai-envelope.json` (verify the **current** Chat Completions envelope + `response_format` json_schema shape via provider docs / Context7 — D6).

- [ ] **Step 2: Write failing tests** mirroring Task 7: `makeRequest` sets `Authorization: Bearer …` + POST + a body containing `response_format`/`json_schema` (D2); `parseEnvelope` extracts the contract text; malformed envelope → `LLMError.malformedResponse`; key never in error strings.

- [ ] **Step 3: Run to verify it fails** — Expected: FAIL.

- [ ] **Step 4: Implement** `OpenAIExtractor` (native `response_format` json_schema — D2; bounded 2× retry — D5). Record the resolved model id + endpoint (D6) in a comment + PR notes.

- [ ] **Step 5: Run to verify pass** — Expected: PASS.

- [ ] **Step 6: Commit** (re-run key scan)
```
git add Sources/HealthBridgeParsing/OpenAIExtractor.swift Tests/HealthBridgeParsingTests/OpenAIExtractorTests.swift Tests/HealthBridgeParsingTests/Fixtures/openai-envelope.json
github-agent-commit "feat(parsing): OpenAIExtractor — Chat Completions adapter, response_format json_schema + 2x retry"
```

---

## Task 9: CLI integration — route `.pdf` to the LLM path, default Anthropic, resolve key (env/`--api-key`), stamp `.pdf`

**Purpose:** wire the PDF path into `healthbridge parse`. Route `.pdf` input to `PDFExtractor`, **default the provider to Anthropic (D1)** when `--provider` is omitted, resolve the API key (env var or `--api-key`) **only on the PDF branch**, build the chosen adapter, stamp `source.kind = .pdf` + `Extractor(engine: "<provider>-llm", version:)`, and reuse the existing mapping/dedupe/validate/write/log/exit-code surface. **Key never persisted, never logged — asserted.**

**Files (read the REAL M2 `HealthBridge.swift`/`ParserRegistry.swift` first — Task 0 Step 5):**
- Modify: `Sources/healthbridge/HealthBridge.swift` — add `--api-key`, `--provider` (anthropic|openai; **default anthropic — D1**), `--model` (optional override) options; PDF branch in `Parse.run` (and/or a PDF-aware `BridgeBuilder` entry that takes an injected/constructed `LLMExtractor`).
- Test: `Tests/healthbridgeTests/PDFCLITests.swift` (and key-resolution + provider-default unit tests)

**Provider default (D1):** a `resolveProvider(flag: String?) -> Provider` helper returns `.anthropic` when `flag == nil`, else parses the flag (`anthropic`/`openai`); unknown → a clear `Fail`. Unit-test the default explicitly.

**Key resolution (pure, unit-testable without env mutation):** a helper `resolveAPIKey(flag: String?, provider: Provider, env: [String:String]) -> String?` — `flag ?? env[provider.envVar]`. Test it with an **injected env dict**, not the process env. The CLI calls it with `ProcessInfo.processInfo.environment`. On `nil` → `Fail("no API key: set \(provider.envVar) or pass --api-key")` (message names the **variable**, never a value).

**Routing decision (T2 — uses the Task 0 Step 5 record):** the `parse` command **hard special-cases PDF**: call `PDFExtractor.canParse(data)` **BEFORE** any `ParserRegistry` dispatch. If it is a PDF, take the async LLM branch (resolve provider — default Anthropic, D1; require a key; build the chosen adapter; `await PDFExtractor.extractDocument`). Only non-PDF input falls through to the existing registry/FHIR/C-CDA path (no key required). This is because `PDFExtractor` is async and intentionally does NOT conform to `DocumentParser` (Task 5), so it cannot be returned/dispatched by a `DocumentParser`-typed registry — the special-case branch is the seam.

**Async-bridge sub-step (T2, conditional):** if Task 0 Step 5(b) found the command is a **sync `ParsableCommand`**, converting `@main`/`run()` to `AsyncParsableCommand` (and `run()` -> `func run() async throws`) is **its own sub-step before the PDF branch**, with a risk note: the conversion can ripple to the `@main` entry point and any synchronous callers of `run()`. If the command is already `AsyncParsableCommand`, skip the conversion. Either way the FHIR/C-CDA branches stay synchronous internally (only the PDF branch awaits). Multi-patient: the PDF branch relies on Task 6's response-level refusal (FHIR/C-CDA keep their own).

- [ ] **Step 1: Write failing tests** — `BridgeBuilder`-level (or a PDF-aware builder) with an **injected mock `LLMExtractor`** so the CLI test does no network:
```swift
func testDefaultProviderIsAnthropic() {   // D1
    XCTAssertEqual(resolveProvider(flag: nil), .anthropic)
    XCTAssertEqual(resolveProvider(flag: "openai"), .openai)
}
func testResolveAPIKeyPrefersFlagThenEnv() {
    XCTAssertEqual(resolveAPIKey(flag: "k1", provider: .anthropic, env: ["ANTHROPIC_API_KEY":"k2"]), "k1")
    XCTAssertEqual(resolveAPIKey(flag: nil, provider: .anthropic, env: ["ANTHROPIC_API_KEY":"k2"]), "k2")
    XCTAssertNil(resolveAPIKey(flag: nil, provider: .openai, env: [:]))
}
func testPDFBuildStampsPDFKindAndModelConfidence() async throws {
    let mock = MockLLMExtractor(reply: try fixtureText("llm-response-valid"))
    let result = try await BridgeBuilder.buildPDF(data: try fixture("pdf-minimal","pdf"),
                    fileName: "p.pdf", subject: testSubject, extractor: mock, engine: "anthropic-llm", now: fixedNow)
    XCTAssertEqual(result.document.source.kind, .pdf)
    XCTAssertEqual(result.document.source.extractor.engine, "anthropic-llm")
    XCTAssertTrue(result.document.observations.contains { $0.confidence < 1.0 })   // model confidence, not 1.0
}
func testKeyNeverWrittenToDocument() async throws {
    let mock = MockLLMExtractor(reply: try fixtureText("llm-response-valid"))
    let result = try await BridgeBuilder.buildPDF(data: try fixture("pdf-minimal","pdf"),
                    fileName: "p.pdf", subject: testSubject, extractor: mock, engine: "anthropic-llm", now: fixedNow)
    let json = String(decoding: try BridgeJSON.encoder.encode(result.document), as: UTF8.self)
    XCTAssertFalse(json.lowercased().contains("api") && json.contains("key"))   // no key field leaked
}
```
> Adjust `BridgeBuilder` entry-point names to match the real M2 builder read in Task 0. The PDF builder takes an **injected `LLMExtractor`** so tests never touch network or a real key.

- [ ] **Step 2: Run to verify it fails** — Expected: FAIL.

- [ ] **Step 3: Implement** the CLI options (`--provider` default `anthropic` — D1), `resolveProvider`, `resolveAPIKey`, the PDF builder entry (injected extractor; mapping/dedupe/validate identical to the FHIR/C-CDA builder; `kind: .pdf`, `extractor: Extractor(engine: "<provider>-llm", version: "0.1.0")`), and the `Parse.run` branch (resolve provider + key from `ProcessInfo` env + flag; construct the chosen real adapter with its resolved model id; await `extractDocument`; reuse existing write/log/`ExitCode(2)`). Ensure the async bridge matches M2's command type.

- [ ] **Step 4: Run to verify pass** — Expected: all PASS.

- [ ] **Step 5: Run the FULL suite** — `swift build && swift test`. Expected: **all M1 + M2 + M3 tests green** (M3 added no schema change, so M1/M2 outputs are unchanged).

- [ ] **Step 6: Manual network smoke (NOT in CI, NOT committed) — the only real-network check.** With a **real BYO key in the shell env** (never echoed, never committed), run `healthbridge parse <synthetic.pdf>` (defaults to Anthropic — D1) and `healthbridge parse <synthetic.pdf> --provider openai` against the two live APIs **once** to confirm the request/envelope shapes + native JSON-forcing + current model ids (D6) match current provider behavior (the un-unit-tested `URLSession` line). Record pass/fail + the resolved model ids in the PR description (no key, no patient data). If a provider's envelope/JSON-mode drifted, fix `parseEnvelope`/`makeRequest` and re-run the pure-seam tests.

- [ ] **Step 7: Commit** (re-run key scan)
```
git add Sources/healthbridge/HealthBridge.swift Tests/healthbridgeTests/PDFCLITests.swift Tests/healthbridgeTests/Fixtures/pdf-patient.pdf
github-agent-commit "feat(cli): route .pdf to LLM extraction — default Anthropic, BYO key (env/--api-key), stamp source.kind=.pdf"
```

---

## Task 10: Docs + PR

**Files:**
- Modify: `README.md` (PDF usage: `healthbridge parse report.pdf` defaults to Anthropic, `--provider openai` for OpenAI, with `ANTHROPIC_API_KEY`/`OPENAI_API_KEY` or `--api-key`; note non-deterministic + review-gated; note macOS-only PDF path + the 30-page cap).
- Modify: the design spec `docs/superpowers/specs/2026-06-22-bridgekit-cli-design.md` roadmap line, marking M3 done (via `agent-gh` PUT-to-main only when the PR merges — or leave for the lead).

- [ ] **Step 1: Update `README.md`** — PDF section: default provider Anthropic (D1), key handling (env/flag, never persisted), the "non-deterministic, gated by iOS review" framing, macOS-only PDF path, the 30-page cap (D3), synthetic-fixtures/no-PHI note.
- [ ] **Step 2: Commit**
```
git add README.md
github-agent-commit "docs: document PDF/LLM extraction (default Anthropic, BYO key, review-gated, 30-page cap)"
```
- [ ] **Step 3: Open the PR** (one PR for the milestone) via `agent-gh`:
```
agent-gh pr create --title "M3: PDF + cloud LLM extraction (BYO key, Anthropic default + OpenAI)" --body-file <path> --base main --head bridgekit-m3
```
The body summarizes the provider protocol, the locked decisions (D1–D6) incl. the resolved model ids, the no-schema-change confirmation, the native-JSON + validating-decoder approach, the key-safety guarantees, the synthetic-fixtures statement, and the manual-smoke result.

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Stale local `origin/main` ref (M2 absent) | Build M3 on M1, miss/clobber M2 | Task 0 Step 1: lead `git fetch`es; agent verifies M2 commit + `CCDAParser.swift`/`ParserRegistry.swift` present before branching |
| Provider request/response schema drift (model ids — D6, envelope shape, JSON-forcing fields, headers) | Real calls 4xx or mis-parse | Resolve current shapes + model ids via Context7/provider docs at Task 7/8 (D6); mandatory Task 9 manual smoke against both live APIs before the PR |
| PDFKit `PDFPage.string` returns nil / different text than expected | Empty/garbled extraction | Empirical gate in Task 2 (`testExtractsPageText` must contain the synthetic string); `pdf-no-text.pdf` exercises the no-text refusal |
| Untrusted LLM output (hallucinated codes, bad confidence, injected fields) | Wrong data reaches the document | Native JSON-forcing (D2) AND `LLMResponseContract` validates every field, drops/rejects bad entries (Task 4, error-handlers-first); `BridgeKit.validate` backstop; iOS review screen is the human gate |
| API key leak (logs, error strings, the .bridge.json, config, git) | Credential exposure | Key in memory only; never persisted/logged; Task 0 key scan before every adapter/fixture commit; explicit "no key in error/json" tests (Tasks 7,9) |
| Real patient PDF committed to a public repo | PHI leak | Synthetic-only fixtures generated from text; Task 0 Step 4 scan rejects any non-fixture `.pdf` and real identities before every fixture commit |
| async `LLMExtractor` vs sync `DocumentParser`/registry (T2) | `PDFExtractor` can't be returned by a `DocumentParser`-typed registry | Hard PDF special-case branch in the CLI, checked via `PDFExtractor.canParse` BEFORE registry dispatch (Task 9); deterministic parsers untouched; Task 0 Step 5(a) records the registry's return contract |
| Sync `ParsableCommand` -> `AsyncParsableCommand` conversion (T2) | Conversion ripples to `@main` entry point / `run()` callers | Task 0 Step 5(b) records the command type; Task 9 makes the conversion a discrete sub-step done ONLY if needed; FHIR/C-CDA branches stay internally sync |
| Large PDF exceeds token budget | Truncated/failed extraction | 30-page cap refusal (D3, Task 2); chunking deferred + documented |
| Non-determinism leaks into tests | Flaky CI | All tests inject a mock `LLMExtractor` with canned JSON, fixed `now:`; zero network, zero real key in CI |

## Resolved decisions (locked — D1–D6)

These were open questions; the user resolved them. They are locked and propagated into the tasks above.

1. **D1 — Default provider = Claude (Anthropic).** Both adapters build. When neither `--provider` nor key context disambiguates, the CLI defaults to Anthropic; OpenAI via `--provider openai`. (Provider table; Task 9 `resolveProvider`, tested by `testDefaultProviderIsAnthropic`.)
2. **D2 — JSON enforcement = native JSON modes AND the validating decoder (BOTH), per-provider.** OpenAI `response_format` json_schema; **Anthropic assistant PREFILL** (NOT tool-use — T1; Anthropic has no `response_format`, and tool-use would move the reply out of `content[0].text`) in each adapter's `makeRequest`; the shared `LLMResponseContract` decoder still treats output as untrusted. (Provider table; Tasks 4, 7, 8.)
3. **D3 — Large-PDF policy = refuse over ~30 pages** (`PDFText.maxPages = 30`) with a clear error; chunking deferred. Refusal path tested before happy path. (Task 2.)
4. **D4 — Multi-patient contract = explicit top-level `patients[]`**; refuse when count > 1 (M2-parity). (Tasks 3, 4, 6.)
5. **D5 — Retry = bounded 2× on 429/5xx/timeout**; real backoff tuning deferred. (Tasks 7, 8; noted in Known limitations.)
6. **D6 — Model ids pinned from current provider docs at Task 7/8** (resolve via Context7/provider docs at implementation time; record the resolved ids in the task + PR; do NOT hardcode now). (Provider table; Tasks 7, 8, 9 smoke.)

## Threat model (named, not pretended-covered)

- **E1 [prompt injection via PDF text].** Untrusted PDF text is embedded directly into the extraction prompt (Task 3). A crafted PDF could attempt to suppress real entries, fabricate contract-valid (well-formed, plausibly-typed) entries, or otherwise steer extraction. **What guards it:** (1) the validating `LLMResponseContract` decoder rejects malformed/out-of-range output — but it **cannot** catch plausible-but-wrong values that satisfy the contract; (2) the downstream **iOS human-review gate** (separate spec), which is the actual safety boundary for any LLM-sourced value. **What is NOT done (deferred):** input sanitization, instruction/data isolation (e.g. delimiting or structurally separating untrusted text from instructions), and adversarial-PDF testing. This is a real, accepted residual risk for M3, mitigated only by the human-review gate.
- **E2 [PDFKit text-ordering on complex layouts].** See the Known-limitations bullet below — multi-column reading order is unverified by the synthetic suite.

## Known limitations / deferred

- **Text-layer only** — image-only/scanned PDFs are refused (no OCR; deferred).
- **Multi-column / complex-layout fidelity unverified (E2).** Synthetic single-column fixtures do NOT exercise multi-column clinical PDFs, where PDFKit `PDFPage.string` can return **scrambled reading order** (interleaved columns) — extracted values may be mis-associated and `snippet`/`page` locators may not match the visual source. The synthetic suite cannot catch this; the **iOS human-review gate** is the backstop. Real-layout fidelity testing is deferred.
- **Real API spend (minor, accepted).** The Task 9 live smoke and any real use spend real provider money (BYO key). Bounded by the 30-page cap (D3) + BYO key; there is **no dollar/spend guard** in M3.
- **30-page cap (D3)** — PDFs over 30 pages are refused; token-budget chunking / sliding-window reconciliation is a later milestone.
- **Bounded 2× retry only (D5)** — transient 429/5xx/timeout get a bounded retry; full exponential-backoff/circuit-breaker tuning is deferred.
- **Page/snippet locators only** — no pixel-region locators (`SourceLocator` has no region field; schema-bounded).
- **Single non-streaming request per document** — no streaming/batch; no tool-use/function-calling at all. Anthropic JSON-forcing is **assistant prefill** (D2/T1), OpenAI is `response_format` json_schema.
- **Two providers** — Anthropic (default — D1) + OpenAI; a third is a new `LLMExtractor` conformance (the protocol is built for it).
- **The `URLSession.data(for:)` line is the only un-unit-tested code** — covered by the mandatory Task 9 manual smoke, never by CI.
- **Non-deterministic by nature** — correctness of *which* values the model extracts is not asserted; the iOS review screen (separate spec) is the human safety gate. M3 guarantees the *shape, validation, and safety* of whatever the model returns, not its clinical accuracy.

## Success Criteria

1. `healthbridge parse <synthetic.pdf>` (Anthropic default — D1; `--provider openai` for OpenAI) produces a valid `*.bridge.json` with `source.kind = .pdf`, per-observation model `confidence`, and `sourceLocator` page/snippet — using a key from env or `--api-key`, never persisted/logged.
2. The full suite (M1 + M2 + M3) is green **on a macOS runner** (T3 — Linux compiles the guarded PDF/XML paths out and is a false green) with **zero network and zero real API key**; M1/M2 outputs are byte-unchanged (no schema change). The un-guarded sentinel test (Task 1) proves the PDF path was compiled in on macOS.
3. Untrusted LLM output is validated even with native JSON-forcing (D2): malformed JSON, missing fields, out-of-range confidence, over-page-limit PDFs (D3), and multi-patient responses (D4) are all rejected/dropped with the existing `Skip`/`ParseError` discipline (error-handler tests green before happy paths).
4. Adding a hypothetical third provider requires only a new `LLMExtractor` conformance — no change to `PDFExtractor`, the contract decoder, or schema.
5. The manual two-provider live smoke (Task 9, off-CI) passes against current provider APIs with the resolved model ids (D6), recorded in the PR.
