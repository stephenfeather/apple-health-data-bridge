# Plan: `bridge-eval iterate` subcommand (TDD, plan-only)

- **Date:** 2026-06-29
- **Author:** architect-agent
- **Status:** Plan only — for a later `kraken` TDD execution. Nothing implemented.
- **Base ref:** `origin/main` @ d529aaf (Track C merge). All source citations verified post-fetch via `git show origin/main:<path>`.
- **Sources of truth:** `thoughts/shared/agents/scout/iterate-loop-scope.md` (verified scope) and `thoughts/shared/plans/2026-06-24-bridge-eval-design.md` §3/§7/§11.

> **Implementation base discipline:** the kraken run MUST start from a fresh worktree off `origin/main` (`.claude/worktrees/<branch>`), never local `main` (no `Sources/` there) and never a leftover branch. Commits via `github-agent-commit` on a feature branch only.

---

## 1. Goal

Add an operator-driven, budget-bounded `iterate` subcommand that evaluates a **human-curated set of candidate prompts** against the existing gold-fixture fitness function and keeps the best one by a **noise-aware decision rule**, recording every evaluation in an **append-only journal**. This is the Karpathy autoresearch shape: a **frozen read-only harness** (the existing `run`/`score`/aggregate path), **one mutable surface** (the prompt), a **mechanical decision rule**, and an **append-only journal** — minus any autonomy.

## 2. Non-goals (explicit)

- **No `research`/LLM-variant stage.** Variants are NOT proposed by an LLM. The "analyze failures → propose next variant" stage from design §11 is DEFERRED and out of scope here.
- **Not autonomous.** No never-stop loop. The loop runs a **bounded** candidate-set × samples batch and then **stops and reports**. The fitness metric requires live API calls plus hand-verified Tier B gold (PHI), so a human curates inputs and reviews outputs each batch. The command never proposes work, never self-continues.
- **No production-source change.** Zero edits to `HealthBridgeParsing` or the shipping `healthbridge` CLI. `ExtractionPrompt.make` is untouched (✓ VERIFIED — the override is injected at the bridge-eval call site). The only non-test files touched are inside `Sources/bridge-eval/`.
- **No new fitness metric.** Reuses `Aggregator.aggregate` → `AggregateF1{mean,stdev,n}` as-is (✓ VERIFIED EvalModels.swift). No new scoring surface.

---

## 3. Verified facts this plan builds on

| Claim | Status | Evidence (origin/main) |
|---|---|---|
| `RunCore.runCase(...)` builds prompt via `ExtractionPrompt.make(pages:)`, no override; `promptHash`/`LLMRequest.instructions`/`ArtifactWriter.key`/`RawArtifact.promptHash` all flow off it | ✓ VERIFIED | `RunCommand.swift` `enum RunCore` |
| `ExtractionPrompt.make(pages:)` **embeds the page text inside the returned prompt** (page-numbered block between `BEGIN DOCUMENT`/`END DOCUMENT`) | ✓ VERIFIED | `ExtractionPrompt.swift` — drives the template-vs-static decision below |
| The document block is exactly `pages.enumerated().map { "----- PAGE \(offset+1) -----\n\(text)" }.joined(separator: "\n")`, wrapped as `BEGIN DOCUMENT\n<document>\nEND DOCUMENT` | ✓ VERIFIED | `ExtractionPrompt.swift` — `renderPrompt` MUST reproduce this block byte-identically (see Task 3b / Risk 5) |
| `RunCommand.run()` pre-pass **re-derives** `promptHashSet.insert(Hashing.promptHash(ExtractionPrompt.make(pages: pages)))` independently of `RunCore.runCase`, then writes the manifest before the network loop | ✓ VERIFIED | `RunCommand.swift` run() pre-pass — **the critical gotcha** |
| `BridgeEval.configuration.subcommands = [RunCommand, ScoreCommand, ReportCommand]` | ✓ VERIFIED | `BridgeEval.swift` |
| `AggregateF1{mean,stdev,n}`, `FixtureModelStats.strictF1`, `RunResults{promptHashes,stats}`, `CaseScore.strict.f1`, `Manifest{...}` | ✓ VERIFIED | `EvalModels.swift` |
| `Aggregator.aggregate(_ scores: [CaseScore], promptHashes: [String]) -> RunResults` (population stdev, n carried) | ✓ VERIFIED | `Aggregator.swift` |
| `ArtifactWriter.key/runDir/writeManifest/writeRaw/writeScored/writeResults` (sorted-keys pretty JSON, atomic) | ✓ VERIFIED | `ArtifactWriter.swift` |
| `Preflight.assertUntracked(_ path:role:)` PHI guard refuses git-tracked paths | ✓ VERIFIED | `Preflight.swift` |
| House style: `@Option(name: .long ...)`, `@Option(name: .customLong("..."))`, `validate()` for cross-option checks; no `@Argument` positionals | ✓ VERIFIED | `RunCommand.swift` |
| `RootCommandTests.testRootHasThreeSubcommands` asserts exactly `{"run","score","report"}` | ✓ VERIFIED | `RootCommandTests.swift` |
| Test dir is `Tests/BridgeEvalTests/`; offline patterns A (stub `LLMExtractor`), B (build artifacts + call `*Core`), C (temp dir + `command.run()`) | ✓ VERIFIED | `RunCommandTests.swift`, `ScoreCommandTests.swift` |
| Existing suite ≈ 320 tests, currently green | ? INFERRED | from task prompt; not run by this planning pass |

---

## 4. Design decisions

### 4.1 Variant representation — directory of `.txt` template files

**Decision:** the candidate set is a **directory of `*.txt` files** (default `eval/prompts/`), one file per variant. Filename stem = stable `variantId`; file contents = a **prompt template** that MUST contain exactly one `{{DOCUMENT}}` placeholder. This is the `program.md` analog — a human edits plain prompt text.

**Why a directory, not a JSON manifest:** the prompt is a large multi-paragraph string whose body literally contains JSON braces and quotes (the response-contract example in `ExtractionPrompt.make`). Hand-authoring that inside a JSON string field (escaping every `"` and newline) is unreadable and error-prone. Plain `.txt` files are the ergonomic, diff-friendly, operator-facing surface, and lexical filename order gives deterministic evaluation order. (✓ VERIFIED the prompt body contains JSON examples — `ExtractionPrompt.swift`.)

**Why templates, not static strings:** `ExtractionPrompt.make` embeds the page text *inside* the prompt (✓ VERIFIED). A raw static override would send the model **no document**. So each variant is a template; the harness renders the per-fixture prompt by substituting the page-numbered document block for `{{DOCUMENT}}`. The rendered string is what gets passed as `promptOverride` — keeping the scout-specified one-line `runCase` change exactly as is (it receives a finished string).

**Baseline seeding:** a `--include-baseline` flag (default **true**) injects the current production prompt (`ExtractionPrompt.make`, evaluated with `promptOverride: nil`) as synthetic variant id `baseline`, evaluated first → it becomes the seed champion. This answers the real question — *"did any human variant beat the shipping prompt?"* — and exercises the default path. (Open question 8.1: confirm default-on.)

> **Staleness caveat (accepted tradeoff — full-prompt over delta-injection):** because each variant `.txt` reproduces the *entire* prompt (all ~40 fixed instruction lines from `ExtractionPrompt.make`, with `{{DOCUMENT}}` where the document goes), **if `ExtractionPrompt.make` is ever changed the variant files silently go stale** — they no longer reflect the shipping instructions they were forked from. We accept this in exchange for autoresearch fidelity (the *whole* prompt is the mutable surface — a variant may restructure anything, not just a bounded delta). Mitigations: (a) the `--include-baseline` seed always re-evaluates the *current* `make()` output, so a stale variant is measured against the live baseline, not a stale one; (b) Task 3b's golden test trips if `make()`'s document-block format drifts; (c) **document that variants must be re-baselined after any `ExtractionPrompt.make` change** (added to §9 open questions). A delta-injection representation (vary only an instruction fragment) was considered and rejected for v1: it avoids staleness but caps what can be explored and is a larger design change.

### 4.2 Noise-aware decision rule (`IterateCore.selectWinner`) — stated precisely

Each variant's batch of `[CaseScore]` is pooled to one overall `AggregateF1` over every `score.strict.f1` (across fixtures × models × samples) via `IterateCore.overallStrictF1`. Let champion `C{mean_c, sd_c, n_c}` and challenger `X{mean_x, sd_x, n_x}`. Define the standard error of the difference:

```
SE_diff = sqrt( sd_c^2 / n_c  +  sd_x^2 / n_x )
```

**Promote the challenger iff ALL THREE hold:**
1. **Absolute floor:** `mean_x - mean_c >= minImprovement` (default `0.01`).
2. **Noise margin:**
   - if `n_c >= 2 && n_x >= 2`: `mean_x - mean_c >= noiseThreshold * SE_diff` (default `noiseThreshold = 1.0`);
   - else (**low-n trap**: population stdev of a single sample is `0`, so `SE_diff` collapses to `0` and would promote on any positive jitter): require the larger fallback floor `mean_x - mean_c >= minImprovementLowN` (default `0.05`).
3. **No per-fixture regression (anti-overfitting gate — Task 5c):** for EVERY fixture (×model) the challenger evaluated, `strictF1_x(fixture) >= strictF1_c(fixture) - maxFixtureRegression` (default `0.05`). This uses the per-fixture `FixtureModelStats.strictF1.mean` that `Aggregator.aggregate` already produces (no new scoring). **Rationale (Gemini + premortem):** the pooled mean can rise while a single fixture craters — a variant that wins one easy fixture and tanks a hard one is *overfitting*, not improving. Pooling cross-fixture F1 also means `SE_diff` reflects *fixture-difficulty* variance, not sampling noise, so conditions 1–2 alone cannot catch this; the per-fixture floor is the principled guard. A challenger that improves overall but regresses any fixture beyond the margin is **not** promoted (and the journal records which fixture blocked it).

Otherwise **retain the champion** (ties, within-noise differences, and per-fixture regressions keep the incumbent — intentional incumbency bias: do not churn the prompt on noise or on a lopsided win).

`selectWinner` takes BOTH the pooled `AggregateF1` pair AND the per-fixture `[FixtureModelStats]` for champion and challenger (so it can evaluate condition 3), and returns a `WinnerDecision { promoted: Bool, deltaMean, seDiff, blockingFixture: String?, reason: String }` so the journal records *why* (including the fixture that blocked a per-fixture regression, if any). **Justification:** a bare "mean improved → keep" promotes on sampling noise; requiring separation beyond ~1σ of the difference, plus an explicit guard for the unestimable-variance `n<2` case, is the minimum honest rule given the harness already captures stdev/n. **This is premortem target #1.**

> **Stated limitation (premortem elephant — do NOT mistake this margin for a significance test):** pooling every `strict.f1` across **fixtures × models × samples** makes the population stdev dominated by *between-fixture difficulty variance*, not sampling noise. So `SE_diff` and the `noiseThreshold·SE_diff` margin are NOT a real statistical significance test — they are a deliberately **conservative, incumbency-biased** guard that won't over-promote, nothing more. Two consequences to honor:
> - **Run one model per `iterate` batch** (`--models` with a single model). Pooling F1 across models conflates prompt quality with model choice — a prompt better for model A but worse for B averages out. Optimize a prompt against one model at a time.
> - The per-fixture `FixtureModelStats` are still written to each variant's `results.json` run dir, so a per-fixture regression masked by the overall mean remains **recoverable by the operator post-hoc** (it is only absent from the *automatic* decision). Treat auto-promotion as a hint, confirm by inspecting per-fixture stats before trusting a champion.

### 4.3 Journal schema — append-only

```
eval/iterate/<session-timestamp>/
  journal.json         # IterateJournal: append-only, EVERY evaluation (incl. failures); written after each variant (§4.7)
  champion.txt         # the winning variant's template; rewritten on each promotion (§4.8)
  champion.json        # pointer: { variantId, promptHash, strictF1Mean, runDir }
  runs/<variant-timestamp>/   # one standard run dir per variant (manifest/raw/scored/results)
```

```swift
struct PromptVariant: Codable, Equatable { let id: String; let template: String }   // template contains {{DOCUMENT}}

struct DecisionRecord: Codable, Equatable {
    let promoted: Bool
    let deltaMean: Double
    let seDiff: Double
    let reason: String
}

struct JournalEntry: Codable, Equatable {       // superset of scout's ChampionEntry
    let variantId: String
    let promptHash: String?       // nil only for a `failure` entry that never produced a run
    let strictF1Mean: Double?     // nil on failure
    let strictF1Stdev: Double?    // nil on failure
    let sampleCount: Int          // total samples pooled (n); 0 on failure
    let runDir: String?           // relative path for traceability; nil on failure
    let evaluatedAt: String       // ISO-8601
    let decision: DecisionRecord? // nil on failure
    let failure: String?          // nil = evaluated OK; non-nil = error summary (NO PHI). §4.7
}

struct IterateJournal: Codable, Equatable { let session: String; var entries: [JournalEntry] }
```

The running champion is the most-recent `promoted == true` entry. Scout's `ChampionEntry` is folded into `JournalEntry` (we record *all* evaluations, the full append-only trace, not just winners).

### 4.4 Budget / stop bounding

Finite by construction: the candidate set is the `.txt` files; each variant is evaluated exactly once over (fixtures × models × `--samples`). Bounds:
- `--samples` (Int, default 1) — per (fixture, model), mirrors `run`.
- `--max-variants` (Int?, default nil = all) — cap evaluated variants.
- `--budget-calls` (Int?, default nil) — hard cap on total live API calls. The loop tracks calls spent; **before evaluating each variant** it compares that single variant's cost (`fixtures * models * samples`) against the remaining budget — if evaluating it would exceed the cap, **stop and report** what was completed (do not start a variant it can't finish). The per-variant check (not a `remainingVariants * …` whole-set estimate) is what bounds the spend.

No LLM-proposed variants; no auto-continue; terminates when the candidate set is exhausted or budget is hit.

### 4.5 Where `promptOverride` threads through

One-line scope change (bridge-eval-only, ✓ VERIFIED seam): add a trailing defaulted param to `RunCore.runCase`:

```swift
static func runCase(..., now: Date, promptOverride: String? = nil) async throws -> (raw: RawArtifact, score: CaseScore) {
    let prompt = promptOverride ?? ExtractionPrompt.make(pages: pages)
    // promptHash, LLMRequest.instructions, ArtifactWriter.key, RawArtifact.promptHash all flow off `prompt` unchanged
```

Defaulted + trailing → the existing `RunCommand.run()` call site compiles unchanged and behaves identically (existing tests stay green).

### 4.6 The promptHash-consistency requirement (the gotcha) — solved by "hash the string you send"

`RunCommand.run()`'s pre-pass builds the manifest's `promptHashes` by re-deriving `Hashing.promptHash(ExtractionPrompt.make(pages: pages))` **independently** of `runCase` (✓ VERIFIED). For an overridden variant the prompt actually sent is the *rendered override*, so blindly reusing that pre-pass would record the wrong (default) hash in `manifest.promptHashes` while the artifacts (`RawArtifact.promptHash`, written by `runCase`) carry the override hash.

**Resolution (revised per Gemini — a single source of truth, not a parallel re-render):** the original plan proposed a separate `IterateCore.promptHashes` helper that *re-renders and re-hashes* the override — but that re-introduces the very "compute the same string in two places" drift it's trying to prevent. Instead:

1. **Render each `(variant, fixture)` override string EXACTLY ONCE** in the `run()` shell, into a local (e.g. `renderedByFixture[fixture] = renderPrompt(template:, pages:)`). For the baseline variant, the "rendered" value is `ExtractionPrompt.make(pages:)` itself (equivalently, pass `promptOverride: nil`).
2. **Hash that same stored string** for the manifest (`Hashing.promptHash(rendered)`), AND **pass that same stored string** as `promptOverride` to `runCase`. Because it is the identical `String` value, `runCase`'s internal `Hashing.promptHash(prompt)` is byte-identical → `manifest.promptHashes` == `RawArtifact.promptHash` **by construction**, with no second rendering path to drift.
3. **Belt-and-suspenders cross-check:** `RawArtifact.promptHash` is already returned from `runCase` (✓ VERIFIED). After a variant's run loop, assert the set of observed `raw.promptHash` values is a subset of the manifest's `promptHashes`; a mismatch is a hard error (catches any future regression instantly).

This removes the brittle re-render helper entirely. Task 6 becomes: *render-once / hash-the-rendered-string / pass-the-same-string*, with a test asserting manifest hash == observed artifact hash for an overridden variant (not a re-derivation equality between two helpers).

### 4.7 Resilience & resume (premortem MISS — Gemini)

`RunCore.runCase` **throws** on a transport/network error, and neither `RunCommand.run()` nor a naive iterate loop catches per-sample (✓ VERIFIED `RunCommand.swift`). A multi-variant live batch is long and expensive (variants × fixtures × models × samples API calls); a single transient 429/503/timeout near the end would otherwise **abort the whole batch and lose every completed variant's result** if the journal were written only at the end.

**Required by this plan:**
1. **Per-variant fault isolation.** In the iterate loop, wrap each variant's evaluation in `do/catch`. On a thrown error, record a `failed` journal entry for that variant (with the error summary, no PHI) and **continue to the next variant** rather than propagating. (Sample-level granularity is a nice-to-have; variant-level is the floor.)
2. **Incremental journal append.** `appendJournal` writes **immediately after each variant completes** (the §4.3 append-only design already supports this) — never buffered to the end. An interrupted batch (Ctrl-C, crash, killed process) leaves every completed variant durably recorded, plus a valid champion-so-far.
3. **Basic resume.** On startup, if the target `--iterate-root` session already has a `journal.json`, the loop **skips variants whose `variantId` already has a terminal entry** and resumes the champion from the most-recent `promoted == true` entry. Re-running the same command is therefore idempotent and cheap — it does not re-pay for completed variants. (Resume is keyed on `variantId`; changing a variant's `.txt` content without renaming it is operator error — note in docs.)

This turns a fragile, all-or-nothing batch into a checkpointed one. It is the single most important operational fix from the external review.

### 4.8 Persisting the winner (premortem MISS — Gemini)

"Keep the winner" must produce something **actionable**, not just a journal line. On every promotion, the `run()` shell writes the winning variant's template to `eval/iterate/<session>/champion.txt` (atomic write, overwrite) alongside a one-line `champion.json` pointer (`{ variantId, promptHash, strictF1Mean, runDir }`). At batch end the file holds the best prompt found — directly diff-able against the production `ExtractionPrompt.make` and ready to hand to a human for the (out-of-scope) decision to adopt it. Without this the loop is high-friction (the operator would have to reconstruct the winner from the journal + variant dir by hand).

---

## 5. File-by-file change list (all bridge-eval-only + tests)

**New — `Sources/bridge-eval/`:**
- `IterateModels.swift` — `PromptVariant`, `DecisionRecord`, `JournalEntry`, `IterateJournal`, `WinnerDecision`.
- `IterateCore.swift` — pure functions: `loadVariants`, `renderPrompt`, `overallStrictF1`, `selectWinner` (pooled + per-fixture guard), `appendJournal`, `pendingVariants`, `resumeChampion`. (No `promptHashes` helper — §4.6 render-once removes it.)
- `IterateCommand.swift` — `AsyncParsableCommand`; macOS-guarded `run()`; options + `validate()`.

**Modified — `Sources/bridge-eval/`:**
- `RunCommand.swift` — add trailing `promptOverride: String? = nil` to `RunCore.runCase` (signature + the one body line). No other change.
- `BridgeEval.swift` — add `IterateCommand.self` to `subcommands`.

**New — `Tests/BridgeEvalTests/`:**
- `IterateCoreTests.swift`, `IterateCommandTests.swift`.

**Modified — `Tests/BridgeEvalTests/`:**
- `RootCommandTests.swift` — `testRootHasThreeSubcommands` becomes four-subcommand expectation (intended behavior change; updated in the registration commit, not deferred).

No `HealthBridgeParsing` / `healthbridge` / `ExtractionPrompt.swift` / `EvalModels.swift` changes.

---

## 6. TDD task breakdown (ordered commits)

Each task: **RED** (failing test first — named, with why it fails) → **GREEN** (minimum change). Tasks 2–8 are pure/offline (zero network, zero PDFKit, zero keys); Task 9 is the integration shell (no new unit test, mirrors `RunCommand.run()`).

### Task 1 — Register `iterate` (compile-first stub)
- **RED:** `RootCommandTests.testRootHasFourSubcommands` expects `{"run","score","report","iterate"}`. Fails — symbol `IterateCommand` does not exist (won't compile). Also `testRootHasThreeSubcommands` now mis-asserts.
- **GREEN:** minimal `IterateCommand: AsyncParsableCommand` (`commandName: "iterate"`, macOS-guarded empty `run()` throwing "not yet implemented" off-macOS like `RunCommand`); add `IterateCommand.self` to `subcommands`; update the old three-subcommand test to four.

### Task 2 — `PromptVariant` + `loadVariants`
- **RED:** `IterateCoreTests.testLoadVariantsReadsTxtDirInLexicalOrder` and `testLoadVariantsRejectsTemplateMissingDocumentPlaceholder` (Pattern C: write `.txt` files to a temp dir). Fail — `IterateCore.loadVariants` absent.
- **GREEN:** define `PromptVariant`; `IterateCore.loadVariants(from dirURL:)` enumerates `*.txt` sorted by filename, reads contents, validates exactly one `{{DOCUMENT}}` placeholder, throws on absence; id = filename stem.

### Task 3 — `renderPrompt`
- **RED:** `testRenderPromptSubstitutesPageNumberedDocumentBlock` — asserts rendered string contains `----- PAGE 1 -----` + the page text and no residual `{{DOCUMENT}}`. Fails — absent.
- **GREEN:** `IterateCore.renderPrompt(template:pages:)` builds the page-numbered block (same format as `ExtractionPrompt.make`) and substitutes the placeholder.

### Task 3b — `renderPrompt` document block is byte-identical to `ExtractionPrompt.make` (fairness golden test)
- **Why:** the baseline variant is rendered by `make()` directly; all other variants by `renderPrompt`. The whole baseline-vs-variant comparison is only fair if the injected document block is **byte-identical** between the two paths. `make()` lives in HealthBridgeParsing and may not be refactored into a shared helper (no production-source change), so `renderPrompt` necessarily duplicates the block format — this test pins that duplication against drift. **This is premortem target #5.**
- **RED:** `testRenderPromptDocumentBlockMatchesExtractionPromptMake` — for known synthetic `pages`, build `ExtractionPrompt.make(pages:)`, extract the substring between `BEGIN DOCUMENT\n` and `\nEND DOCUMENT`, and assert it equals the document block `renderPrompt` substitutes for `{{DOCUMENT}}` (use a minimal template `"BEGIN DOCUMENT\n{{DOCUMENT}}\nEND DOCUMENT"` and compare the rendered result to `make()` byte-for-byte). Fails until `renderPrompt`'s block format matches `make()` exactly. Add a comment in `renderPrompt` pointing at this test as the drift tripwire if `make()` ever changes.
- **GREEN:** ensure `renderPrompt`'s page-block construction matches `make()`'s `----- PAGE n -----\n<text>` joined by `\n` exactly.

### Task 4 — `overallStrictF1` pooled reduction
- **RED:** `testOverallStrictF1PoolsAllSampleF1s` — synthetic `[CaseScore]` with known `strict.f1` values → expected `{mean,stdev,n}` (population stdev; n=1 → stdev 0). Plus `testOverallStrictF1OnEmptyScoresReturnsZeroNotNaN` — empty `[CaseScore]` (a variant whose every case errored/was skipped) must yield a well-defined result (`mean 0, stdev 0, n 0`), never `NaN`. Fail — absent.
- **GREEN:** `IterateCore.overallStrictF1(scores:) -> AggregateF1` computes mean / population stdev / n over `score.strict.f1`, guarding the empty case (return `{0,0,0}` rather than dividing by zero). A variant that produces zero scorable cases is recorded as a worst-possible (non-promotable) entry, not a crash.

### Task 5a — `selectWinner` margin rule (n>=2)
- **RED:** `testSelectWinnerPromotesWhenGainExceedsNoiseMargin`, `testSelectWinnerRetainsChampionWithinNoise`, `testSelectWinnerTieKeepsChampion` — synthetic `AggregateF1` pairs. Fail — absent.
- **GREEN:** implement conditions (1) absolute floor + (2) `noiseThreshold * SE_diff` for the `n>=2` branch; return `WinnerDecision` with deltas + reason.

### Task 5b — `selectWinner` low-n guard
- **RED:** `testSelectWinnerLowNRequiresLargerAbsoluteFloor` — `n_c=1` and/or `n_x=1` (SE_diff would be 0); a +0.02 gain must NOT promote, a +0.06 gain must. Fails — current logic promotes on any positive gain.
- **GREEN:** add the `n<2` fallback `minImprovementLowN` branch.

### Task 5c — `selectWinner` per-fixture regression guard (anti-overfitting)
- **RED:** `testSelectWinnerBlocksPromotionOnPerFixtureRegression` — challenger has a higher pooled mean but one fixture's `strictF1.mean` drops `> maxFixtureRegression` below the champion's; assert NOT promoted and `WinnerDecision.blockingFixture` names it. Plus `testSelectWinnerPromotesWhenAllFixturesWithinMargin`. Fail — `selectWinner` ignores per-fixture stats.
- **GREEN:** extend `selectWinner` to take champion + challenger `[FixtureModelStats]` and enforce condition 3 (§4.2): no fixture regresses beyond `maxFixtureRegression` (default `0.05`); record `blockingFixture`.

### Task 6 — promptHash consistency: render-once, hash-the-sent-string (the gotcha)
- **RED:** `testIterateManifestHashMatchesObservedArtifactHashForOverride` (Pattern B: build artifacts) — render an override once, hash it for a manifest, run a stubbed `runCase` with that SAME string as `promptOverride`, and assert `manifest.promptHashes` contains exactly `RawArtifact.promptHash` (no default hash leaks in). Fails — no render-once path yet.
- **GREEN:** in the `run()` shell, render each `(variant, fixture)` override ONCE into a stored value; hash THAT for the manifest and pass THAT same string as `promptOverride` (baseline → `make()`/`nil`). Add the belt-and-suspenders post-loop assertion that observed `raw.promptHash` ⊆ `manifest.promptHashes`. No separate re-rendering helper (§4.6 revised — single source of truth).

### Task 7 — `appendJournal` + journal types + resume helper
- **RED:** `testAppendJournalCreatesThenAppendsInOrder` (Pattern C, temp dir) — append to a nonexistent path → file with 1 entry; append again → 2 entries, order preserved, valid JSON. Plus `testAppendJournalRecordsFailureEntry` — a `failure`-populated entry (nil decision/metrics) round-trips. Plus `testResumeSkipsVariantsAlreadyJournaled` — given a journal with entries for ids {A,B}, `IterateCore.pendingVariants(all:journalURL:)` returns only the not-yet-done ids and the resumed champion (most-recent `promoted==true`). Fail — absent.
- **GREEN:** define `IterateJournal`/`JournalEntry`/`DecisionRecord`; `IterateCore.appendJournal(entry:journalURL:)` reads-or-empty, appends, atomic write with the sorted-keys pretty encoder (matching `ArtifactWriter`); `IterateCore.pendingVariants`/`resumeChampion` pure helpers for §4.7 resume.

### Task 8 — `IterateCommand` options + `validate()`
- **RED:** `IterateCommandTests.testIterateCommandParsesOptions` (parse `--variants --fixtures --iterate-root --models --samples --noise-threshold --min-improvement --max-variants --budget-calls --include-baseline`) and `testIterateValidateRejectsNonPositiveSamplesAndBudget`. Fail — fields/validate absent.
- **GREEN:** add `@Option` fields (house style `.long` / `.customLong`) with documented defaults; `validate()` enforces `samples > 0`, `budget-calls > 0` when present, `noise-threshold >= 0`, and (deferred to run-time existence, like `run`) the variants dir.

### Task 9 — `IterateCommand.run()` integration shell (macOS-guarded, no new unit test)
- **No RED unit test** (network path; mirrors `RunCommand.run()` being integration-only — design §10). Composed entirely of Task 2–8 helpers that are already offline-tested.
- **GREEN:** `#if canImport(PDFKit) && os(macOS)` body:
  1. `Preflight.assertUntracked(iterateRoot)` and `Preflight.assertUntracked(fixtures)`.
  2. `loadVariants`; prepend baseline if `--include-baseline`. **Resume (§4.7):** if the session journal exists, drop already-journaled variants via `pendingVariants` and seed champion via `resumeChampion`.
  3. Read each fixture's pages once (reuse `Fixtures` discovery as `run` does).
  4. For each pending variant **within budget** (per-variant budget check, §4.4): **wrapped in `do/catch` (§4.7)** — render each per-fixture override ONCE → hash the rendered string for the manifest and pass that SAME string as `promptOverride` (§4.6 render-once) → per (fixture, model, sample) call `RunCore.runCase(..., promptOverride: rendered)` → `ArtifactWriter` writes the run dir → assert observed `raw.promptHash` ⊆ manifest hashes → `Aggregator.aggregate` (per-fixture stats) → `overallStrictF1` (pooled) → `selectWinner` vs current champion (pooled + per-fixture) → **`appendJournal` immediately** → on promotion, rewrite `champion.txt`/`champion.json` (§4.8) and update champion. **On a thrown error:** append a `failure` journal entry and `continue` to the next variant — never abort the batch.
  5. Print the final champion summary to stderr, including **batch token cost** (sum `RawArtifact.inputTokens`/`outputTokens`, ✓ VERIFIED captured) and any failed/skipped variants. If **no challenger variants** were evaluated (empty variants dir, or only the synthetic `baseline`), print an explicit `"no challengers evaluated — champion is the baseline"` notice rather than implying a comparison happened.
- Optionally add a `SmokeTests`-style parse smoke check; live behavior is operator-local Tier B only.

---

## 7. Test plan

**Offline unit (CI-safe, zero network/PDFKit/keys; Tier A / synthetic):** registration (Task 1), `loadVariants` (2), `renderPrompt` (3), `overallStrictF1` (4), `selectWinner` all branches incl. low-n (5a/5b), `promptHashes` consistency (6), `appendJournal` round-trip (7), option parsing + `validate()` (8). All follow verified Patterns A/B/C.

**Live smoke (operator-local only, NEVER CI):** `IterateCommand.run()` against Tier B fixtures (real PDFs, hand-verified `expected.json` — PHI) with real API keys, exactly like `run`. Verifies the manifest's `promptHashes` match each run dir's artifact hashes (the gotcha), and that the journal records the batch.

**Regression:** the existing ≈320 tests (? INFERRED count) must stay green; the only intended change to an existing test is `RootCommandTests` three→four subcommands. The defaulted trailing `promptOverride` keeps `RunCore.runCase`'s existing call site and tests untouched.

---

## 8. Open risks / premortem targets

| # | Risk | Why it bites | Mitigation |
|---|---|---|---|
| 1 | **Decision rule** (`selectWinner`) | `n<2` → population stdev 0 → `SE_diff` 0 → promotes on noise; macro-pooling can hide a per-fixture regression behind an overall gain; pooling across fixtures (and models) makes stdev reflect *fixture difficulty*, not sampling noise, so the margin is NOT a real significance test; default `noiseThreshold`/floors are unvalidated | Low-n absolute-floor guard (Task 5b); record full `deltaMean`/`seDiff`/`reason` per entry; knobs configurable; incumbency bias on ties. **Run one model per batch** (see §4.2). Per-fixture stats stay on disk for post-hoc review. Treat auto-promotion as a hint; tune defaults empirically before relying on it. |
| 2 | **promptHash pre-pass divergence** | `RunCommand.run()` re-derives the default hash independently; reusing it records the wrong hash for overridden variants | Dedicated `IterateCore.promptHashes` helper + its own test (Task 6); `run()` must NOT call the `run` pre-pass. |
| 3 | **Variant-injection consistency** | A template missing/typo'd `{{DOCUMENT}}` sends the model no document → catastrophic scores masquerade as "bad variant" | `loadVariants` validates exactly-one placeholder and throws (Task 2); `renderPrompt` test asserts no residual placeholder (Task 3). |
| 4 | Baseline seeding ambiguity | Unclear champion seed if `--include-baseline` off and the set is unordered | Default `--include-baseline true`; deterministic lexical variant order; document seed = first evaluated. |
| 5 | **`renderPrompt` document-block drift** | `renderPrompt` re-implements `make()`'s page-block format; baseline uses `make()` directly, variants use `renderPrompt`. If the blocks differ (now, or after a future `make()` change), baseline-vs-variant deltas are silently confounded by document formatting, not prompt content — and `make()` may not be refactored to a shared helper (no production-source change) | Byte-identity golden test pinning `renderPrompt`'s block to `make()`'s actual output (Task 3b) + a drift-tripwire comment in `renderPrompt`. |
| 6 | Empty / all-skipped variant | `overallStrictF1` over zero scores → `NaN` → crash or garbage decision | Empty-scores guard returns `{0,0,0}` (mirrors existing `Aggregator.aggregateF1`, ✓ VERIFIED); variant recorded as worst-possible non-promotable entry (Task 4). |
| 7 | **Transient API failure aborts the whole batch** (Gemini; premortem MISS) | `RunCore.runCase` throws on network error with no per-sample catch (✓ VERIFIED); a late failure in a long paid batch loses everything if the journal is end-buffered | Per-variant `do/catch` + incremental `appendJournal` after each variant + `variantId`-keyed resume (§4.7, Tasks 7 & 9). |
| 8 | **Decision overfits one fixture** (Gemini; escalated) | Pooled mean can rise while a single fixture craters; pooled `SE_diff` reflects fixture difficulty not noise, so it can't catch this | Per-fixture regression guard — condition 3 in §4.2 (Task 5c); journal records `blockingFixture`. |
| 9 | **Winner not actionable** (Gemini; premortem MISS) | "Keep the winner" only journaled → operator must reconstruct the best prompt by hand | Persist `champion.txt`/`champion.json` on each promotion (§4.8, Task 9). |
| 10 | **Variant `.txt` staleness** | Full-prompt variants duplicate `make()`'s instructions; a `make()` change silently orphans them | Accepted tradeoff for autoresearch fidelity; baseline re-evaluates live `make()`; Task 3b golden tripwire; re-baseline-after-change note (§4.1, open Q 8.6). |

## 9. Open questions

- [ ] **8.1** Confirm `--include-baseline` defaults **true** (seed champion = current production prompt).
- [ ] **8.2** Default `noiseThreshold` (1.0?) and `minImprovementLowN` (0.05?) — placeholders pending an empirical batch.
- [ ] **8.3** `--iterate-root` default `eval/iterate/` (mirrors `eval/runs/`) — confirm; add to `.gitignore` if not already covered (PHI in run dirs).
- [ ] **8.4** `--variants` default `eval/prompts/` — prompt templates contain **no patient data** (operator instructions only), so unlike run dirs they MAY be committed/version-controlled. Confirm whether `eval/prompts/` should be tracked (shareable curated prompts) or gitignored. Note: `Preflight.assertUntracked` is intentionally NOT applied to the variants dir (only `iterateRoot` + `fixtures`), which is correct either way.
- [ ] **8.5** `--models` — for a meaningful decision, an `iterate` batch should pass a **single** model (see §4.2 limitation). Decide whether `validate()` should warn (or hard-reject) multiple `--models` in `iterate`, or leave it as documented operator guidance.
- [ ] **8.6** Default `maxFixtureRegression` (0.05?) — the per-fixture anti-overfitting margin (§4.2 condition 3); placeholder pending an empirical batch alongside 8.2.
- [ ] **8.7** Resume semantics (§4.7) — confirm resume keys on `variantId` only (changing a variant's content without renaming it is operator error). Decide whether to hash-check the variant template against the journaled `promptHash` and warn on drift.

## 10. Success criteria

1. `bridge-eval iterate --variants <dir> --fixtures <dir>` evaluates each `.txt` variant once over fixtures × models × samples, within budget, and prints the winning variant + batch token cost.
2. The chosen winner obeys the §4.2 rule (no promotion within sampling noise; low-n guard active; **no per-fixture regression beyond margin**).
3. Each variant's `manifest.promptHashes` equals the hashes embedded in its run-dir artifacts (gotcha closed by render-once, §4.6).
4. `journal.json` is a valid append-only record of every evaluation (incl. failures) with its decision rationale, **written incrementally** so an interrupted batch keeps completed variants and **resumes** without re-paying (§4.7).
5. On promotion, `champion.txt` holds the winning prompt (§4.8).
6. Zero changes outside `Sources/bridge-eval/` + tests; existing suite stays green.

---

## 11. Pre-Mortem (deep) — run 2026-06-29

Verified against `origin/main` @ d529aaf source (read `ExtractionPrompt.make` directly).

**Tigers addressed (folded into plan):**
1. **`renderPrompt` document-block drift** (medium) → byte-identity golden test (new **Task 3b**) + drift-tripwire comment; Risk 5; verified-facts row added.

**Elephants addressed (folded into plan):**
1. **"Noise-aware" margin is not a significance test** (medium) → §4.2 stated-limitation block: pooling reflects fixture difficulty not sampling noise; **run one model per batch**; per-fixture stats stay on disk for post-hoc review; auto-promotion is a hint. Risk 1 augmented; open question 8.5 added.

**Low notes addressed:** empty/all-skipped variant `NaN` guard (Task 4 + Risk 6); empty-challenger explicit notice (Task 9); per-variant budget-check wording (§4.4); `eval/prompts/` tracked-vs-gitignored (open question 8.4).

**Paper tiger:** per-fixture regression hidden by macro-pooling — data IS persisted to each run's `results.json`, recoverable post-hoc; only absent from the automatic decision. Not blocking.

**Verdict:** no HIGH-blocking tigers. Plan is kraken-ready once open questions 8.1–8.7 are confirmed.

### External adversarial review — Gemini, 2026-06-29 (Codex was quota-blocked)

Gemini independently confirmed the §4.2 statistics concern and surfaced three items the premortem missed; all folded in by user decision:

- **Transient-failure resilience (NEW, operational):** `runCase` throws on network error with no per-sample catch → a late failure aborts a long paid batch and (if end-buffered) loses everything. Fixed: per-variant `do/catch` + incremental journal + `variantId`-keyed resume (§4.7; Tasks 7, 9; Risk 7).
- **Simpler promptHash design (NEW, architectural):** the original re-render helper was "two sources of truth." Replaced with render-once / hash-the-sent-string + observed-hash cross-check (§4.6; Task 6 rewritten; Risk 2 closed more cleanly).
- **Per-fixture regression guard (escalated):** pooled SE can promote a fixture-overfit variant. Added as §4.2 condition 3 (Task 5c; Risk 8).
- **Persist the winner (NEW):** `champion.txt`/`champion.json` on promotion (§4.8; Task 9; Risk 9).
- **Variant staleness (design fork):** user chose to KEEP full-prompt `.txt` over delta-injection; documented as accepted tradeoff (§4.1; Risk 10; open Q 8.6).
- Nits noted: low-n floor / `maxFixtureRegression` defaults are placeholders (open Q 8.2, 8.6); batch token cost now surfaced (Task 9).

**Pipeline:** scout → architect → premortem (deep) → Gemini adversarial review → mitigations folded. No HIGH blockers remain; the open questions are tuning/confirmation, not redesign.
