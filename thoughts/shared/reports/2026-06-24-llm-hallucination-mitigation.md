# Detecting & Mitigating Hallucinated Observations in the M3 PDF→LLM Path

**Date:** 2026-06-24
**Scope:** Analysis & recommendation only — no code changes. Deterministic FHIR/C-CDA paths untouched.
**Context:** Milestone 3 added a PDF→cloud-LLM extraction path (Anthropic `claude-opus-4-8` or OpenAI `gpt-5.5`). Extracted PDF text is sent to an LLM that returns a strict per-observation JSON contract (LOINC code, value or valueText, unit, effectiveDate, category, confidence, page, verbatim snippet). The path is non-deterministic, gated downstream by a human-review screen, and protected by a validate-don't-trust decoder.

---

## 1. The failure class

The decoder is a **validity** gate: it rejects output that violates the contract or basic plausibility (malformed JSON, missing code/date/value, out-of-range confidence, implausible/future dates, ambiguous value+valueText). Validity is checkable in isolation.

The two observed failures are **veracity** failures — output that satisfies the contract but does not correspond to the source:

- **Run A:** 0 observations (dropped everything).
- **Run B:** a spurious duplicate body-weight observation with display `"Body weight unit alias"` (a string absent from the source), carrying a valid LOINC `29463-7`, value `72.5 kg`, and the real date. Code/value/date are valid and plausible → the decoder cannot reject it. Display differs → the deterministic dedup (keyed on code+value+unit+date) did not collapse it.

Veracity cannot be checked in isolation — it requires comparing the output back against the source, or against other samples. Every approach below either **adds a veracity check** or **reduces the variance** that produces veracity failures. None eliminate the residue; they shrink it and ideally **label** it for the human reviewer, who is the actual veracity boundary.

**Key reframe.** The model's `display` field is the lowest-value, highest-risk field in the contract. The system already has a validated LOINC code; the canonical display *is* that code. Treating `display` as model-generated free text is what produced Run B's distinguishing artifact. Several approaches converge on "stop trusting it."

A second candor point up front: **you cannot make this path deterministic.** You can only reduce variance and add verification. `temperature=0` is greedy decoding, not determinism; structured outputs constrains shape, not values.

---

## 2. Approaches

Each is rated on mechanism · what it catches · cost · failure modes · architectural fit.

### 2.1 Snippet-grounding verification — *the standout*
- **Mechanism:** the contract already returns a verbatim snippet + page. Verify the snippet actually occurs in the extracted PDF text that was sent. Exact substring first; fall back to whitespace/ligature/hyphenation-normalized match, then a fuzzy threshold. Page must match.
- **Catches:** fabricated entries whose evidence string is not in the source — *exactly* Run B (`"Body weight unit alias"` is not in the text). Also catches paraphrased/drifted snippets.
- **Cost:** effectively zero — deterministic string op, no tokens, no added latency. Low complexity; the only real work is PDF-extraction normalization.
- **Failure modes:**
  - PDF mangling makes a *true* snippet fail to match → false rejection. Run A already shows over-dropping is a real harm, so this must **flag, not drop**.
  - A real snippet paired with a *misread value* grounds fine — this validates the evidence string, not the number.
  - Does not catch a fabrication that copies a real substring.
- **Fit:** drop-in extension of the existing validate-don't-trust decoder; same philosophy, same pipeline slot (post-decode, pre-dedup). Touches nothing in FHIR/C-CDA.

### 2.2 Canonical display from code + clinical-key dedup
- **Mechanism:** ignore the model's `display` entirely; populate it from a deterministic LOINC→display table keyed on the already-validated code. Then dedup on `(code, normalized value, unit, date)` with display excluded from the key.
- **Catches:** Run B's duplicate collapses two ways at once — the invented display is discarded *and* the clinical key now merges the pair.
- **Cost:** trivial; needs a static LOINC display table.
- **Failure modes:** legitimately distinct same-key observations (e.g., two devices at the same timestamp) would merge — rare, and arguably correct to merge. It removes the *duplicate*, not the underlying hallucinated *observation* — but with identical canonical display and clinical key, nothing remains to distinguish it from the real one.
- **Clinically safe?** Yes. For a validated LOINC code the display is cosmetic; identity lives in the code. The unsafe move is the opposite — trusting free-text display as semantic.
- **Fit:** dedup stage + static asset.

### 2.3 Provider determinism settings (temperature / seed / structured outputs)
- **Mechanism:** `temperature=0`, fix seed where the API honors it, keep structured outputs.
- **Catches:** reduces run-to-run *variance* (the Run A vs Run B divergence).
- **Cost:** free.
- **Failure modes (candid):** `temperature=0` is greedy decoding, **not determinism** — floating-point non-associativity across batched/MoE kernels and provider-infra changes still produce variance; hosted seeds are best-effort and often not exposed for these models. Structured outputs constrains *shape* (all fields present, valid types) but does nothing for *values* — and it is precisely what forces `display` to be populated, removing the "omit a field" option. Lowers variance; does nothing for fabrication.
- **Fit:** config-level. Set it; do not rely on it.

### 2.4 Prompt tightening
- **Mechanism:** e.g. "snippet MUST be an exact substring of the provided text; do not invent display variants; one observation per source line."
- **Catches:** nudges the distribution away from the failure.
- **Cost:** free — but the prompt is compiled into the binary, so iteration requires a rebuild/release; no hotfix.
- **Failure modes:** instructions are soft. "Omit uncertain entries" is already present, yet Run A omitted everything and Run B fabricated. Shifts a distribution; enforces nothing.
- **Fit:** cheap reinforcement only. Pair "snippet must be exact substring" with the deterministic check in §2.1 that actually enforces it.

### 2.5 Self-consistency / N-sample voting
- **Mechanism:** N calls; cluster by clinical key; keep observations recurring in ≥k of N; surface the k/N count.
- **Catches:** run-to-run non-determinism directly — rescues Run A (other samples find the real observation) and dilutes Run B (a 1-of-5 spurious entry drops or flags low-agreement).
- **Cost:** N× tokens/$/latency — the real constraint at batch scale.
- **Failure modes:** voting catches *variance, not bias* — a consistent hallucination survives. Threshold tuning trades false-drops against noise. The merge step inherits the display-variant problem, so it depends on §2.2's keying.
- **Fit:** wraps the call; its natural output is the agreement signal for §2.9. Best reserved for high-stakes documents or budget-permitting, not always-on.

### 2.6 Cross-provider agreement
- **Mechanism:** run Claude + OpenAI; intersect, flag disagreement.
- **Catches:** *provider-specific* hallucinations/biases that single-provider voting cannot (a systematic Claude bias is not shared by GPT).
- **Cost:** 2× providers, two schemas to keep aligned, two integrations/keys/rate limits.
- **Failure modes:** frequent benign formatting disagreement → flag noise; shared failure on genuinely ambiguous source; operational weight.
- **Fit:** same wrapper point as §2.5. A heavier, better-bias-coverage variant of voting — best kept as an offline eval harness rather than the runtime default.

### 2.7 Second-pass verifier / judge call
- **Mechanism:** feed (source text + each observation) to a second model: "supported? yes/no + evidence."
- **Catches:** the residue §2.1 cannot — value misreads, wrong-date/wrong-subject attribution, unsupported inference.
- **Cost:** +1 call (batch per doc to amortize); another compiled-in prompt.
- **Failure modes:** correlated blind spots if same provider/family; LLM judges tend to rubber-stamp (sycophancy); it is itself non-deterministic — fighting non-determinism with more of it.
- **Fit:** post-process. Below §2.1 for the headline case, but the right tool for value-misreads. Use a **different provider/family** to decorrelate, and surface the verdict as a signal, not a gate.

### 2.8 Outlier checks vs subject history / population ranges
- **Mechanism:** compare each value to per-LOINC plausible ranges and the subject's prior readings; flag large jumps or unit-scale errors (kg↔lb).
- **Catches:** value/unit errors — but **not** Run B (`72.5 kg` is perfectly plausible).
- **Cost:** low compute; needs curated ranges + history; cold-start on first observation.
- **Failure modes:** real clinical outliers get flagged → alarm fatigue; must never auto-drop an extreme value.
- **Fit:** flag generator for §2.9, never a hard gate. Orthogonal to fabrication; lower priority for *this* failure class.

### 2.9 Structured agreement signal to the human-review screen
- **Mechanism:** attach per-observation metadata — grounded? (y/n), votes k/N, judge verdict, outlier flag, page-anchored snippet link — and sort/color the queue by it.
- **Catches:** nothing automatically; it makes the reviewer better at catching the residue, which is the real boundary.
- **Cost:** UI work.
- **Failure modes:** signal overload; **automation bias** — a green "grounded" check must not read as "verified correct."
- **Fit:** the correct sink for every detector above. Given that "the final safety boundary is a human reviewer," this is the load-bearing architectural stance: instrument the trust decision, do not automate it.

---

## 3. What is not solvable in code (the human-gate residue)

- **Consistent** hallucinations — the same fabrication every run — survive voting *and* cross-provider agreement.
- A fabrication built from a **real snippet + real plausible value + wrong association** (wrong date, wrong subject, target-weight-vs-actual-weight) passes grounding, dedup, outlier checks, and can pass a judge.
- Semantic correctness of the extraction is a clinical judgment.

These are exactly the residue the human-review gate exists for. The code's job is to shrink and **label** this residue, not to eliminate it.

---

## 4. Prioritized recommendation

**Tier 1 — now. Deterministic, ~zero LLM cost, kills the demonstrated failure, extends the existing decoder:**

1. **Snippet-grounding** (§2.1), flag-don't-drop, with PDF-aware normalization.
2. **Canonical display from the validated code + clinical-key dedup** (§2.2).
3. **`temperature=0`** (§2.3) — documented as variance reduction, not a guarantee.
4. **Prompt tightening** (§2.4) to match §2.1 — understood as soft reinforcement.

> Tier 1's first two items are the 80/20: together they deterministically eliminate the exact Run B failure, add no LLM cost, sit naturally in the validate-don't-trust decoder, and do not touch FHIR/C-CDA.

**Tier 2 — when batch budget allows, or risk-gated per document:**

5. **N-sample voting** (§2.5) feeding a k/N agreement signal. Best single defense against run-to-run non-determinism (rescues Run A, dilutes Run B). Cost is the only reason it is not Tier 1.

**Tier 3 — targeted at the value-misread residue Tier 1 cannot see:**

6. **Judge call on a different provider/family** (§2.7) as a signal; or **cross-provider agreement** (§2.6) if two providers are already in use.
7. **Outlier-vs-history flags** (§2.8) for value/unit slips.

**Cross-cutting:** route every signal above into the **review screen** (§2.9) — grounded?, votes k/N, judge verdict, outlier flag, page-anchored snippet. Design explicitly against automation bias; "grounded" means "evidence string exists," not "clinically correct." That instrumentation — not any single gate — is what makes the human boundary actually work.

---

## 5. Pipeline placement (summary)

```
LLM call (temp=0, structured outputs)
  └─ [optional] N-sample / cross-provider wrap        (§2.5 / §2.6)
decode + validity gate (existing)
  └─ snippet-grounding flag                            (§2.1)
  └─ display ← canonical LOINC lookup (drop model text)(§2.2)
  └─ clinical-key dedup (code,value,unit,date)         (§2.2)
  └─ outlier flag vs history/ranges                    (§2.8)
  └─ [optional] judge verdict                          (§2.7)
assemble review payload with all signals               (§2.9)
  └─ human-review screen  ← final veracity boundary
```

---

## Appendix — relevant prior learning

A prior memory records that **automated PR review (Codex + Gemini) caught two genuine data-integrity/safety issues on the M2 C-CDA parser** that the TDD plan missed. This is direct in-repo evidence that the cross-model-check pattern (§2.6 / §2.7) has already paid off here — supporting its place in the toolkit even when it is not the runtime default.
