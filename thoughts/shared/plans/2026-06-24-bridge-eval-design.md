# bridge-eval — Extraction Evaluation Harness (Design)

- **Date:** 2026-06-24
- **Status:** Design approved; §13 open items resolved (2026-06-25) → writing implementation plan
- **Scope:** New dev-only evaluation harness for the LLM PDF-extraction path (M3)
- **Branch discipline:** This spec lives on `main` (shared across feature branches). The harness itself is built in the `bridgekit-m3` worktree.

---

## 1. Purpose

We send `ExtractionPrompt` (Sources/HealthBridgeParsing/ExtractionPrompt.swift) to two models (gpt-5.5, opus-4.8) to extract clinical observations from medical PDFs. Today the only visibility into a response is the CLI's stderr log of observation/skip counts. We need to **evaluate** each response — success, failure, and quirks — in a structured, repeatable way.

**Near-term goal:** a measurable, machine-readable score per response against gold fixtures, plus a rich quirk breakdown.

**Long-term goal:** that score becomes the **fitness function** for an auto-iterate / auto-research loop (prompt variant → measure → keep the winner → research failures → propose the next variant). Every design choice below optimizes for that future: deterministic offline scoring, provenance-tagged artifacts, and failure cases preserved as research input.

---

## 2. Key decisions (settled)

| Decision | Choice | Rationale |
|---|---|---|
| Fitness signal | **Gold fixtures (labeled)** | Deterministic, free to re-run, no model variance — the right objective for a tight optimization loop. |
| Harness form | **New SwiftPM executable target** `bridge-eval` | Reuses the real adapters + prompt; keeps the security-critical shipping CLI clean; natural host for the future loop. |
| Real data | **Allowed, never committed** | Real PDFs are the actual target distribution. Committed fixtures stay synthetic (public-repo rule). |
| Skip granularity | **Structured `Skip.Detail`** (assumed resolved — §8) | Per-quirk histograms without prose parsing or contract reimplementation. |
| Token usage / stop_reason / full envelope | **Assumed captured** | Richer response type accepted (§4). |
| Match identity | **(loinc, effectiveDate) + field grading** | Surfaces partials/quirks; a unit slip reads as "partial," not a double-penalized FP+FN. |

---

## 3. Architecture

`bridge-eval` is a SwiftPM `.executableTarget` that imports `HealthBridgeParsing` and reuses the **real** production path — no reimplementation. Every pipeline stage is already `public`, so the harness reproduces the exact four steps and tees off each intermediate:

```
PDFText.pages(data)            →  page text  (D3 30-page cap applies)
ExtractionPrompt.make(pages:)  →  prompt string (+ hash)
extractor.extract(request)     →  raw response (real Anthropic/OpenAI adapter)
LLMResponseContract.decode(…)  →  ParseResult { observations, skipped }
+ distinctPatientCount / extractedPatient
```

> **Why not call `PDFExtractor.extractDocument`?** It decodes the raw JSON inline and never returns it — discarding the single most valuable eval artifact. The harness re-runs the public steps itself so nothing is lost.

The target is **dev-only**: declared as a target, NOT added to the package `products`, so it never ships in the `healthbridge` binary.

### Subcommands (swift-argument-parser, mirroring the CLI)

| Command | Network? | Purpose |
|---|---|---|
| `run` | **yes** | fixtures × models × N samples → call models → write raw responses + decoded results + per-case scores. |
| `score` | no (pure) | (re)score already-saved raw responses **offline**. Develop the scorer cheaply; re-score historical runs after a scorer change. |
| `report` | no (pure) | aggregate a run dir → human table + machine `results.json`. |

Splitting `run` (network, costly, non-deterministic) from `score`/`report` (pure, deterministic, replayable) is the central architectural move. It makes scoring reproducible, lets the scorer be unit-tested and iterated without burning API calls, and keeps cost bounded.

---

## 4. Capture spec — what we save/log

The harness saves the following per `(promptHash, model, fixture, sample)`. Starred rows are not surfaced by the current pipeline and matter most.

| Stage | Saved | Why |
|---|---|---|
| Input | PDF sha256, filename, page count, per-page char counts | Provenance; correlate quirks with doc size; detect D3 page-cap truncation. |
| Prompt | exact `ExtractionPrompt.make` string + **hash** | The optimization target. The hash keys every run to a prompt version — the loop's provenance spine. |
| Request | model id, provider, params | Fair gpt-5.5 vs opus-4.8 comparison. |
| **Raw response** ⭐ | full LLM envelope: `jsonText` verbatim (pre-trim) **+ token usage + stop_reason** | *The* artifact. Offline replay, model diffing, future research input. Cost/length tracking via usage; truncation detection via stop_reason. |
| Decode outcome | `decode` **threw** (`ParseError.malformed`) vs succeeded | Catastrophic contract failure is a distinct top-line signal. |
| Valid observations | full `Observation` (loinc, value/unit, date, category, **confidence**, page, snippet) | Numerator for hits/partials; confidence enables calibration analysis. |
| **Skips** ⭐ | every `Skip { reason, label, detail }` (§8) | Richest quirk signal. Structured `detail` → clean per-quirk histograms. |
| Patient extraction | `distinctPatientCount`, `extractedPatient` (name/dob) | Single-subject safety quirks; multi-patient refusals. |
| Timing | wall-clock latency per call | Latency dimension of model choice. |

---

## 5. Fixtures — two tiers

**Tier A — synthetic, committed** (`Tests/HealthBridgeParsingTests/Fixtures/`): existing synthetic data (Jane Public / John Sample). Used **only to unit-test the matcher/scorer** — pure, public-safe, runs in CI.

**Tier B — real, local-only** (`eval/fixtures/`, **gitignored**, or any off-repo path via `--fixtures`): real PDFs + hand-verified `expected.json`, for live eval against gpt-5.5 / opus-4.8. Never committed.

### Fixture layout (Tier B)

```
<fixtures-root>/<case-name>/
  input.pdf          # real PDF (or pages.txt for prompt-only cases)
  expected.json      # hand-verified gold: { patients:[…], observations:[…] }
  notes.md           # optional: what this case probes
```

`expected.json` uses the same observation shape the contract produces, so scoring compares like-to-like.

---

## 6. Scoring model

The pipeline has **two** prompt-influenced failure surfaces; both are scored.

### (a) Contract conformance
From `decode`:
- **Catastrophic:** malformed JSON → `ParseError.malformed` (whole response unusable).
- **Per-entry:** each `Skip`, grouped by structured `detail` (§8). The skip histogram per prompt version is itself a prompt-quality signal (e.g. many `confidenceOutOfRange` = model fabricating certainty).

### (b) Extraction quality
Match predicted **valid** `[Observation]` against `expected.observations`. **Identity = (loinc, effectiveDate)**; matched pairs are then graded field-by-field.

| Outcome | Meaning |
|---|---|
| **Hit** | matched + all graded fields correct → TP |
| **Partial** | matched on identity, but value/unit/category wrong → "right test, wrong detail" (quirk) |
| **Missed–rejected** | model produced it but the contract skipped it (links to the skip `detail`) |
| **Missed–absent** | never produced → FN |
| **Hallucinated** | predicted, not in gold → FP |

Distinguishing **missed-rejected** from **missed-absent** is what later tells the research stage whether to fix the prompt's *extraction guidance* vs its *contract/formatting guidance*.

### Field grading on matched pairs
- **value (numeric):** configurable tolerance (default exact).
- **value (qualitative):** normalized string equality.
- **unit:** exact UCUM string.
- **date:** exact at UTC calendar-day.
- **category:** exact (`vital`/`lab`/`other`).

### Metrics
- **Headline:** strict **F1** (hits only) — precision = hits / predicted-valid, recall = hits / expected.
- **Secondary:** lenient F1 (partials = ½).
- **Diagnostic:** skip-`detail` histogram; partial-field error-type counts; catastrophic-failure rate; patient-extraction correctness; (later) confidence calibration.

---

## 7. Sampling, aggregation & artifacts

Model output is non-deterministic, so a single run is a noisy estimate. The harness runs **N samples per (fixture, model)** and aggregates: **mean ± stdev F1** plus output-consistency (how often samples agree). This lets the future loop separate a real prompt gain from sampling noise.

### Run directory layout
```
<runs-root>/<timestamp>/
  manifest.json      # prompt hash, models, params, sample count — provenance (NO PHI)
  raw/<…>.json       # full LLM envelope (replay + research input)
  scored/<…>.json    # decoded result + per-case metrics
  results.json       # aggregate fitness numbers (the loop's objective)
```
Naming key: `<promptHash>__<model>__<fixture>__<sample>`.

---

## 8. Dependency — structured `Skip.Detail` (assumed resolved)

The eval depends on a small, additive change to `Skip` (Sources/HealthBridgeParsing/DocumentParser.swift). The decoder already knows the exact sub-cause at each rejection; this surfaces it as a typed value instead of only as prose, because one `reason` case (`.unrepresentableValue`) currently fans out to several distinct model behaviors (both value+valueText, no usable value, out-of-range confidence).

```swift
public struct Skip: Equatable, Sendable {
    public enum Reason: Equatable, Sendable { case noCode, noDate, unrepresentableValue, negated, implausibleDate }  // UNCHANGED
    public let reason: Reason
    public let label: String
    public let detail: Detail?            // NEW — additive, defaults nil

    public enum Detail: Equatable, Sendable {
        case bothValueAndText
        case noUsableValue
        case nonFiniteValue
        case confidenceOutOfRange(got: String)   // "1.5" / "missing"
        case dateMalformed
        case dateBeforeDOB
        case dateAfterNow
        case missingCode
    }
    public init(reason: Reason, label: String, detail: Detail? = nil) { … }
}
```

**Non-breaking:** the `init` default keeps all existing call sites (FHIR/C-CDA parsers, all tests) compiling untouched; `reason` and `label` are unchanged, so the CLI's `skipped (\(reason)): \(label)` logging is unaffected. Only `LLMResponseContract.mapEntry` populates `detail`. The other parsers leave it `nil`.

The scorer aggregates `skipped` by `detail ?? .fromReason(reason)`.

> **Alternatives rejected:** parsing the `label` prose in the scorer (brittle string coupling; or reimplements contract logic) and widening the shared `Reason` enum (ripples through FHIR/C-CDA parsers, CLI logging, and every contract test — large blast radius into the safety core).

---

## 9. PHI & git safety

Real PDFs **and** the `raw/`/`scored/` artifacts contain PHI (observations, patient names/DOBs). This repo already hit fixture contamination once — guards are mandatory:

- `.gitignore` entries for `eval/fixtures/` and `eval/runs/` added **up front**.
- **Preflight guard:** `run` refuses to read fixtures from, or write artifacts into, a git-**tracked** path — fail loud rather than risk a commit.
- `manifest.json` records only prompt hash + params — never raw PHI.
- Scorer unit tests use Tier A synthetic data only.

---

## 10. Testing the harness

- **Matcher + scorer:** pure functions (`expected` + `ParseResult` → metrics). Unit-tested with Tier A synthetic fixtures and a **stub `LLMExtractor`** (the protocol already exists — trivial to fake). Zero network.
- **`run`:** the only network-touching path. Gated by API keys; never runs in CI.
- **Preflight guard:** unit-tested against a tracked vs untracked path.

---

## 11. Growth path (designed-for, NOT built in v1)

`results.json` is the future loop's fitness function; the `raw/` failure cases are the auto-research stage's input. A later `iterate` subcommand (prompt variant → run → score → keep winner) and a `research` stage (analyze failures → propose next variant) drop in without reshaping anything here. **v1 builds only `run` / `score` / `report`.**

---

## 12. Out of scope (YAGNI for v1)

- The `iterate` / `research` loop itself.
- Confidence-calibration analysis (data is captured; analysis deferred).
- A third provider.
- Any change to the shipping `healthbridge` CLI beyond the additive `Skip.Detail` it transparently inherits.

---

## 13. Open items — RESOLVED (2026-06-25)

All three settled with the recommended choice; recorded here as the source of truth for the implementation plan.

1. **Default value tolerance** for numeric grading — **RESOLVED: exact.** A predicted numeric value must equal gold exactly to count as a Hit; a rounding/unit slip reads as Partial. (A configurable tolerance remains a later knob, not v1.)
2. **`run` + `score` collapse** — **RESOLVED: separate from day one.** `run` (network) writes raw responses; `score` (pure) re-scores offline. Preserves replay, deterministic offline scorer iteration, and a unit-testable scorer with zero network.
3. **Off-repo default for Tier B fixtures** — **RESOLVED: gitignored `eval/fixtures/` default, `--fixtures` override.** In-repo but gitignored for discoverability; the preflight guard (§9) refuses git-tracked fixture/artifact paths.

> **Dependency status (2026-06-25):** all three assumed-resolved dependencies are now MERGED to `main` — §8 `Skip.Detail` (PR #7), token usage / stop_reason / richer envelope (PR #8, #3), and raw-response capture (PR #9, #4). The harness is fully unblocked.
