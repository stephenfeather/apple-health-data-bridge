# bridge-eval fixtures

The `bridge-eval` harness runs synthetic fixture cases (fixtures × models × N samples) against live
models and writes scored artifacts. This README documents the local dev fixtures used for keyed runs.

## Layout

```
eval/
  README.md            # this file (committed)
  fixtures/            # gitignored — local dev artifacts, NEVER committed (.gitignore)
    <case>/
      pages.txt        # plain text input (PDF-less path); pages split on form-feed U+000C
      expected.json    # gold ExpectedDoc (patients + observations)
      notes.md         # what branch the case probes
  runs/                # gitignored — run outputs
```

`eval/fixtures/` and `eval/runs/` are gitignored; only `eval/README.md` is committed. A developer
recreates the four fixtures below locally from this README. **Synthetic identities only** (Jane Public /
John Sample), past DOBs, past observation dates (today is 2026-06-26; all dates are 2024 to avoid
`dateAfterNow`). This repo is public — never place real PHI under `eval/`.

## Input paths

A case supplies input either as a binary `input.pdf` (the realistic PDFKit path) or a plain `pages.txt`
(the PDF-less convenience path). Precedence: **`input.pdf` wins** when both are present; `pages.txt` is
the fallback; neither present is a loud `Fixtures.LoadError`.

`pages.txt` is one file per case; pages are separated by the ASCII form-feed control character `\f`
(U+000C) — exactly what `pdftotext` emits between pages, so a `pages.txt` produced from a real extraction
is a drop-in. A trailing `\f` (the `pdftotext` artifact) drops the single trailing empty page; interior
empty pages are preserved. A `pages.txt` with no `\f` is a single-page document (the common case here).

## CI-provability boundary (read first)

The only **CI-provable** facts about these fixtures are structural: each `expected.json` decodes into
`ExpectedDoc` and each `pages.txt` parses into a page array (proved generically by the temp-dir loader
test against a fixture the test writes itself). The **discrimination** — strict F1 < 1.0, a
`confidenceOutOfRange(...)` histogram bucket appearing, `distinctCountCorrect=false`, etc. — requires a
**live model to misbehave** and is therefore a manual/keyed `run`, NOT a CI assertion. Do not write a
test that asserts a fixture scores F1<1.0; that is unprovable offline.

## The four fixtures

Recreate each under `eval/fixtures/<case>/` with the exact content below.

### A — `unit-slip` → `partial` w/ `fieldErrors.unit`; strict F1=0 / lenient F1=0.5

Probes unit field-grading. The document prints the non-UCUM unit `mmHg`, but gold requires the UCUM
bracket form `mm[Hg]`. A model that copies the document's `mmHg` verbatim → unit mismatch → `partial`
(`fieldErrors.unit=true`, strict F1=0 / lenient F1=0.5). A model that normalizes to UCUM `mm[Hg]` →
`hit` (F1=1.0). Identity (loinc 8480-6 + 2024-03-10) still matches either way, so the unit is the only
field in error. The discriminator rewards UCUM-normalization knowledge.

`pages.txt`:
```
SYNTHETIC VITALS — EVAL FIXTURE (NOT REAL PHI)
Patient: Jane Public   DOB: 1990-05-01
Visit date: 2024-03-10

Vital Signs
  Blood pressure (systolic): 128 mmHg
```

`expected.json`:
```json
{
  "patients": [{ "name": "Jane Public", "dob": "1990-05-01" }],
  "observations": [
    { "loinc": "8480-6", "display": "Systolic blood pressure", "value": 128,
      "valueText": null, "unit": "mm[Hg]", "effectiveDate": "2024-03-10", "category": "vital" }
  ]
}
```

### B — `bad-confidence` → `confidenceOutOfRange(...)` bucket + `missedRejected`

Probes `mapEntry`'s confidence guard (`LLMResponseContract.swift:197-200`). Document content cannot
*force* a bad confidence — this discriminates models that fabricate out-of-range confidence. When a
model emits e.g. `confidence: 1.4` for glucose, the entry is skipped with detail
`.confidenceOutOfRange("1.4")`; the skip label contains "Glucose", gold `display` is "Glucose", so
`rejectedLoincSet` links it (`Scorer.swift:65-76`) → `missedRejected`;
`skipHistogram["confidenceOutOfRange(1.4)"]++` (`Scorer.swift:16`). A well-behaved model → hit. The
`display` MUST match the model's emitted label for linkage to fire.

`pages.txt`:
```
SYNTHETIC LAB — EVAL FIXTURE (NOT REAL PHI)
Patient: Jane Public   DOB: 1990-05-01
Collected: 2024-03-10

Chemistry
  Glucose, fasting: 95 mg/dL
```

`expected.json`:
```json
{
  "patients": [{ "name": "Jane Public", "dob": "1990-05-01" }],
  "observations": [
    { "loinc": "2345-7", "display": "Glucose", "value": 95,
      "valueText": null, "unit": "mg/dL", "effectiveDate": "2024-03-10", "category": "lab" }
  ]
}
```

### C — `malformed-value` → `bothValueAndText` / `noUsableValue` / `dateMalformed` buckets

Three observations, each crafted to tempt one bucket:
- "Positive, 2+" tempts `bothValueAndText` (`LLMResponseContract.swift:186-189`) — a model emitting both
  `valueText:"positive"` and `value:2`.
- "see addendum (value pending)" tempts `noUsableValue` (`:192-194`) — null/whitespace valueText and
  null value.
- "(specimen dated 2024-02-30)" tempts `dateMalformed` (`:177-179`) — Feb has no 30th, fails `parseDate`
  round-trip.

**Gold-date discipline:** gold dates are all `2024-02-10` (valid) so the gold observations form usable
identity keys; the impossible date lives only in `pages.txt` to trick the model. `missedRejected`
linkage is by display-in-label, NOT by date, so it still fires.

`pages.txt`:
```
SYNTHETIC LAB — EVAL FIXTURE (NOT REAL PHI)
Patient: John Sample   DOB: 1985-11-20
Collected: 2024-02-10

Results
  Leukocyte esterase: Positive, 2+
  Potassium: see addendum (value pending)
  Influenza A PCR (specimen dated 2024-02-30): Detected
```

`expected.json`:
```json
{
  "patients": [{ "name": "John Sample", "dob": "1985-11-20" }],
  "observations": [
    { "loinc": "5799-2", "display": "Leukocyte esterase", "value": null,
      "valueText": "positive", "unit": null, "effectiveDate": "2024-02-10", "category": "lab" },
    { "loinc": "2823-3", "display": "Potassium", "value": null,
      "valueText": "pending", "unit": null, "effectiveDate": "2024-02-10", "category": "lab" },
    { "loinc": "76078-5", "display": "Influenza A PCR", "value": null,
      "valueText": "detected", "unit": null, "effectiveDate": "2024-02-10", "category": "lab" }
  ]
}
```

### D — `multi-patient` → `patientCorrectness.distinctCountCorrect=false` (diagnostic only)

Document contains two patients; gold declares ONE. **The harness does NOT refuse multi-patient** —
`RunCore.runCase` is not on the `PDFExtractor.extractDocument` refusal path (`PDFExtractor.swift:42`); it
calls `LLMResponseContract.decode` directly, then reads `distinctPatientCount`/`extractedPatient`
separately (`RunCommand.swift:31-35`). When the model emits both patients, `distinctPatientCount=2 >
expected 1` → `distinctCountCorrect=false`. `identityCorrect` stays true (first identifiable patient =
Jane = gold[0]). The two distinct-day heart rates both hit → F1=1.0, isolating the patient signal.

`pages.txt`:
```
SYNTHETIC CLINIC SUMMARY — EVAL FIXTURE (NOT REAL PHI)
This document intentionally contains two patients (probes patient-count handling).

Patient A: Jane Public   DOB: 1990-05-01
  Heart rate: 72 /min   (2024-01-15)

Patient B: John Sample   DOB: 1985-11-20
  Heart rate: 80 /min   (2024-02-20)
```

`expected.json`:
```json
{
  "patients": [{ "name": "Jane Public", "dob": "1990-05-01" }],
  "observations": [
    { "loinc": "8867-4", "display": "Heart rate", "value": 72,
      "valueText": null, "unit": "/min", "effectiveDate": "2024-01-15", "category": "vital" },
    { "loinc": "8867-4", "display": "Heart rate", "value": 80,
      "valueText": null, "unit": "/min", "effectiveDate": "2024-02-20", "category": "vital" }
  ]
}
```

## Deferred (NOT in this track)

- **`dateBeforeDOB` fixture** and the **`--subjectDOB` CLI option.** `RunCore.runCase` calls
  `LLMResponseContract.decode(..., subjectId:, now:)` with **no `subjectDOB`** (`RunCommand.swift:31`),
  so the `dateBeforeDOB` implausibility check is unreachable through the harness regardless of model
  output. Reaching it requires a new `--subjectDOB` option threaded into `decode`.
