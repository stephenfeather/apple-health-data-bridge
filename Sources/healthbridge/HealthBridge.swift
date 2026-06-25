import Foundation
import CryptoKit
import ArgumentParser
import BridgeKit
import HealthBridgeConfig
import HealthBridgeParsing
import ModelsR4

public struct BuildResult { public let document: BridgeDocument; public let skipped: [Skip] }

public enum BridgeBuilder {
    public static func build(data: Data, fileName: String, subject: SubjectRef, now: Date = Date()) throws -> BuildResult {
        let sha = sha256Hex(data)
        guard let (parser, kind) = ParserRegistry.detect(data) else { throw ParseError.unrecognizedFormat }
        let result = try parser.parse(data, subjectId: subject.id)
        let resolved = result.observations.map { o -> BridgeKit.Observation in
            var o = o
            o.mapping = MappingTable.resolve(loinc: o.code?.code, value: o.value, unit: o.unit)
            return o
        }
        var seen = Set<String>()
        let deduped = resolved.filter { seen.insert($0.id).inserted }
        let doc = BridgeDocument(
            schemaVersion: BridgeDocument.currentSchemaVersion,
            source: Source(kind: kind, fileName: fileName, sha256: sha, extractedAt: now,
                           extractor: Extractor(engine: kind == .ccda ? "ccda-parser" : "fhir-parser", version: "0.1.0")),
            subject: subject, observations: deduped)
        return BuildResult(document: doc, skipped: result.skipped)
    }
    public static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

// MARK: - PDF/LLM provider routing (M3)

/// The cloud LLM providers. Default is Anthropic (D1); OpenAI via `--provider openai`.
enum Provider: String, Equatable {
    case anthropic, openai
    var envVar: String { self == .anthropic ? "ANTHROPIC_API_KEY" : "OPENAI_API_KEY" }
    /// Current default model id per provider (D6); overridable via `--model`. Confirmed at the live smoke.
    var defaultModel: String { self == .anthropic ? "claude-opus-4-8" : "gpt-5.5" }
    var engine: String { self == .anthropic ? "anthropic-llm" : "openai-llm" }
}

/// Pure: default Anthropic when `--provider` is omitted (D1); unknown value → a clear Fail.
func resolveProvider(flag: String?) throws -> Provider {
    guard let flag else { return .anthropic }
    guard let p = Provider(rawValue: flag.lowercased()) else {
        throw Fail("unknown provider '\(flag)' — use anthropic or openai")
    }
    return p
}

/// Pure: `--api-key` flag wins, else the provider env var, else nil. Takes an INJECTED env dict so it
/// is testable without mutating the process environment. NEVER returns/logs the value elsewhere.
func resolveAPIKey(flag: String?, provider: Provider, env: [String: String]) -> String? {
    flag ?? env[provider.envVar]
}

/// The subject-binding policy decision, factored out pure so it is unit-testable and applied
/// IDENTICALLY on every parser path (FHIR/C-CDA inline; PDF via this function).
enum SubjectGateDecision: Equatable { case proceed; case refuse(String) }

/// `match`/`noPatient` → proceed; `mismatch` → refuse unless `--force`; `incomplete` (patient present
/// but missing name/dob) → refuse unless `--allow-unverified-subject`.
func subjectGate(_ result: PatientMatchResult, force: Bool, allowUnverified: Bool,
                 detail: String = "") -> SubjectGateDecision {
    switch result {
    case .match, .noPatient: return .proceed
    case .mismatch:
        return force ? .proceed : .refuse("Patient mismatch — refusing.\(detail.isEmpty ? "" : "\n\(detail)")\nUse --force to override.")
    case .incomplete:
        return allowUnverified ? .proceed : .refuse("Patient present but unverifiable — refusing. Use --allow-unverified-subject to override.")
    }
}

#if canImport(PDFKit) && os(macOS)
extension BridgeBuilder {
    /// PDF/LLM build: takes an INJECTED `LLMExtractor` (mock in tests — zero network), stamps
    /// `source.kind = .pdf` + `Extractor(engine:"<provider>-llm")`, and reuses the SAME
    /// mapping/dedupe pipeline as the FHIR/C-CDA `build`. Multi-patient refusal happens inside
    /// `PDFExtractor.extractDocument` (Task 6). The API key is never passed here — it lives only in the
    /// already-constructed adapter — so it can never reach the document.
    static func buildPDF(data: Data, fileName: String, subject: SubjectRef,
                         extractor: any LLMExtractor, engine: String, model: String,
                         subjectDOB: Date? = nil, now: Date = Date())
        async throws -> (result: BuildResult, extractedPatient: (name: String, dob: String)?,
                         meta: LLMResponseMeta?, rawResponse: String) {
        let sha = sha256Hex(data)
        let extraction = try await PDFExtractor(extractor: extractor, model: model)
            .extractDocument(data, subjectId: subject.id, subjectDOB: subjectDOB, now: now)
        let resolved = extraction.result.observations.map { o -> BridgeKit.Observation in
            var o = o
            o.mapping = MappingTable.resolve(loinc: o.code?.code, value: o.value, unit: o.unit)
            return o
        }
        var seen = Set<String>()
        let deduped = resolved.filter { seen.insert($0.id).inserted }
        let doc = BridgeDocument(
            schemaVersion: BridgeDocument.currentSchemaVersion,
            source: Source(kind: .pdf, fileName: fileName, sha256: sha, extractedAt: now,
                           extractor: Extractor(engine: engine, version: "0.1.0")),
            subject: subject, observations: deduped)
        return (BuildResult(document: doc, skipped: extraction.result.skipped),
                extraction.extractedPatient, extraction.meta, extraction.rawResponse)
    }
}
#endif

public enum PatientMatchResult { case match, mismatch, noPatient, incomplete }

public enum PatientMatch {
    public static func check(data: Data, subject: SubjectEntry) -> PatientMatchResult {
        #if canImport(FoundationXML) || os(macOS)
        if CCDAParser.canParse(data) {
            let pts = CCDAParser.patientDemographics(data)
            guard let first = pts.first else { return .noPatient }
            if pts.count > 1 { return .mismatch }   // defensive; the parser also refuses in build()
            return compare(name: first.name, dob: first.dob, subject: subject)
        }
        #endif
        guard let patient = firstPatient(data) else { return .noPatient }
        guard let (name, dob) = nameAndDOB(patient) else { return .incomplete }
        return compare(name: name, dob: dob, subject: subject)
    }
    /// Shared first+last-token name match plus exact dob — identical for FHIR, C-CDA, and the PDF path
    /// (which compares the model-extracted identity). Internal so the CLI can reuse it.
    static func compare(name: String, dob: String, subject: SubjectEntry) -> PatientMatchResult {
        guard !name.isEmpty, !dob.isEmpty else { return .incomplete }
        let docTokens = name.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let subjTokens = subject.name.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let df = docTokens.first, let dl = docTokens.last,
              let sf = subjTokens.first, let sl = subjTokens.last else { return .mismatch }
        return (df == sf && dl == sl && dob == subject.dob) ? .match : .mismatch
    }
    public static func extracted(data: Data) -> (name: String, dob: String)? {
        #if canImport(FoundationXML) || os(macOS)
        if CCDAParser.canParse(data) {
            guard let first = CCDAParser.patientDemographics(data).first, !first.name.isEmpty else { return nil }
            return (first.name, first.dob)
        }
        #endif
        guard let p = firstPatient(data), let (n, d) = nameAndDOB(p) else { return nil }
        return (n, d)
    }
    /// Number of Patient resources in the document. `check` only verifies the first, but the
    /// parser imports every Observation, so a multi-patient bundle must be refused upstream.
    public static func patientCount(data: Data) -> Int {
        #if canImport(FoundationXML) || os(macOS)
        if CCDAParser.canParse(data) { return CCDAParser.patientDemographics(data).count }
        #endif
        let dec = JSONDecoder()
        if let bundle = try? dec.decode(ModelsR4.Bundle.self, from: data) {
            return bundle.entry?.compactMap { $0.resource?.get(if: ModelsR4.Patient.self) }.count ?? 0
        }
        return (try? dec.decode(ModelsR4.Patient.self, from: data)) != nil ? 1 : 0
    }
    private static func firstPatient(_ data: Data) -> ModelsR4.Patient? {
        let dec = JSONDecoder()
        if let bundle = try? dec.decode(ModelsR4.Bundle.self, from: data) {
            return bundle.entry?.compactMap { $0.resource?.get(if: ModelsR4.Patient.self) }.first
        }
        return try? dec.decode(ModelsR4.Patient.self, from: data)
    }
    private static func nameAndDOB(_ p: ModelsR4.Patient) -> (String, String)? {
        guard let hn = p.name?.first else { return nil }
        let given = (hn.given ?? []).compactMap { $0.value?.string }.joined(separator: " ")
        let family = hn.family?.value?.string ?? ""
        let dob = p.birthDate?.value?.description ?? ""
        return ("\(given) \(family)".trimmingCharacters(in: .whitespaces), dob)
    }
}

@main
struct HealthBridge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "healthbridge",
        abstract: "Parse medical-record documents into subject-bound Bridge Documents.",
        subcommands: [Parse.self, Subject.self])
}

struct Parse: AsyncParsableCommand {
    @Argument(help: "Input document (FHIR JSON, C-CDA XML, or PDF).") var input: String
    @Option(name: .long) var config: String = ConfigLoader.defaultPath
    @Option(name: .long) var subject: String?
    @Option(name: .long) var dataRoot: String?
    @Option(name: .long, help: "PDF only: LLM provider (anthropic|openai). Default anthropic.") var provider: String?
    @Option(name: .long, help: "PDF only: API key (else the provider env var). Never persisted/logged.") var apiKey: String?
    @Option(name: .long, help: "PDF only: override the provider's default model id.") var model: String?
    // ModelsR4 also exports a `Flag` (FHIR resource), so qualify the ArgumentParser property wrapper.
    @ArgumentParser.Flag(name: .long) var verbose = false
    @ArgumentParser.Flag(name: .long) var quiet = false
    @ArgumentParser.Flag(name: .long, help: "Proceed despite a Patient mismatch.") var force = false
    @ArgumentParser.Flag(name: .long, help: "Proceed when the Patient is present but unverifiable.") var allowUnverifiedSubject = false
    // #4: opt-in raw-response logging for offline eval (content-SHA-only input ref; the captured
    // raw model reply may contain PHI, so the log stays local/gitignored/nukable). Also enabled by
    // HEALTHBRIDGE_LOG_RAW_RESPONSES=1|true or config raw_response_log=true. OFF by default.
    @ArgumentParser.Flag(name: .long, help: "PDF only: append the model's raw response to a local eval log (off by default).") var logRawResponses = false

    func validate() throws {
        if verbose && quiet { throw ValidationError("--verbose and --quiet are mutually exclusive") }
    }

    func run() async throws {
        let cfg = try ConfigLoader.load(path: config)
        let overrides = Overrides(dataRoot: dataRoot, subject: subject,
                                  logLevel: verbose ? .verbose : (quiet ? .quiet : nil))
        let settings = SettingsResolver.resolve(config: cfg, overrides: overrides)
        guard let entry = settings.selectedSubject else { throw Fail("no subject selected (set --subject or default_subject in config)") }

        let inputURL = URL(fileURLWithPath: input)
        let data = try Data(contentsOf: inputURL)

        // T2 hard special-case: PDF routes to the async LLM path BEFORE registry dispatch (PDFExtractor
        // is async/non-conforming to the sync DocumentParser). A key is required ONLY on this branch.
        #if canImport(PDFKit) && os(macOS)
        if PDFExtractor.canParse(data) {
            let pdf = try await buildFromPDF(
                data: data, fileName: inputURL.lastPathComponent, entry: entry)
            // Single-subject binding parity (HIGH): verify the model-extracted patient against the bound
            // subject with the SAME comparator + gating as FHIR/C-CDA. No document is written on refusal.
            let match = pdf.extractedPatient.map { PatientMatch.compare(name: $0.name, dob: $0.dob, subject: entry) } ?? .noPatient
            let detail = "  document: \(pdf.extractedPatient?.name ?? "?") / \(pdf.extractedPatient?.dob ?? "?")\n  roster:   \(entry.name) / \(entry.dob)"
            if case .refuse(let message) = subjectGate(match, force: force, allowUnverified: allowUnverifiedSubject, detail: detail) {
                throw Fail(message)
            }
            // #3 additive observability: only on --verbose, only the PDF/LLM path. Key-free.
            if settings.logLevel == .verbose, let meta = pdf.meta {
                log(llmUsageLine(meta))
            }
            try finalize(pdf.result, entry: entry, settings: settings)
            // #4 raw-response eval log: only AFTER a kept extraction is finalized (never on refusal/throw),
            // and only when opt-in (flag || env || config). Content-SHA only — no page/prompt text, no key.
            if rawLoggingEnabled(flag: logRawResponses,
                                 env: ProcessInfo.processInfo.environment,
                                 config: cfg?.rawResponseLog ?? false) {
                writeRawResponseLog(sha: pdf.result.document.source.sha256,
                                    provider: pdf.provider, model: pdf.model,
                                    meta: pdf.meta, rawResponse: pdf.rawResponse,
                                    settings: settings, logPathOverride: cfg?.rawResponseLogPath)
            }
            return
        }
        #endif

        // FHIR/C-CDA path (synchronous; no key required).
        // Subject binding only verifies the first Patient; refuse mixed-patient bundles to avoid
        // importing another person's observations under the selected subject.
        if PatientMatch.patientCount(data: data) > 1 {
            throw Fail("multiple patients in bundle — refusing")
        }

        switch PatientMatch.check(data: data, subject: entry) {
        case .match, .noPatient: break
        case .mismatch:
            if !force { throw Fail("Patient mismatch — refusing.\n\(mismatchDetail(data, entry))\nUse --force to override.") }
        case .incomplete:
            if !allowUnverifiedSubject { throw Fail("Patient present but unverifiable — refusing. Use --allow-unverified-subject to override.") }
        }

        let subjectRef = SubjectRef(id: entry.subjectId, label: entry.label,
                                    hash: SubjectHash.make(name: entry.name, dob: entry.dob),
                                    name: entry.name, dob: entry.dob)
        let result = try BridgeBuilder.build(data: data, fileName: inputURL.lastPathComponent, subject: subjectRef)
        try finalize(result, entry: entry, settings: settings)
    }

    #if canImport(PDFKit) && os(macOS)
    /// Resolve provider (default Anthropic — D1) + key (flag/env; required here only) + model, build the
    /// chosen adapter, and run the async PDF extraction. The key lives in memory only.
    private func buildFromPDF(data: Data, fileName: String, entry: SubjectEntry)
        async throws -> (result: BuildResult, extractedPatient: (name: String, dob: String)?,
                         meta: LLMResponseMeta?, rawResponse: String, provider: Provider, model: String) {
        let resolvedProvider = try resolveProvider(flag: provider)
        guard let key = resolveAPIKey(flag: apiKey, provider: resolvedProvider,
                                      env: ProcessInfo.processInfo.environment) else {
            throw Fail("no API key: set \(resolvedProvider.envVar) or pass --api-key")
        }
        let modelId = model ?? resolvedProvider.defaultModel
        let extractor: any LLMExtractor = resolvedProvider == .anthropic
            ? AnthropicExtractor(apiKey: key)
            : OpenAIExtractor(apiKey: key)
        let subjectRef = SubjectRef(id: entry.subjectId, label: entry.label,
                                    hash: SubjectHash.make(name: entry.name, dob: entry.dob),
                                    name: entry.name, dob: entry.dob)
        // Verified roster DOB (not the model's untrusted patients[].dob) for the plausible-date guard,
        // parsed with the decoder's identical UTC discipline.
        let subjectDOB = LLMResponseContract.parseDate(entry.dob)
        let built = try await BridgeBuilder.buildPDF(data: data, fileName: fileName, subject: subjectRef,
                                                     extractor: extractor, engine: resolvedProvider.engine,
                                                     model: modelId, subjectDOB: subjectDOB)
        return (built.result, built.extractedPatient, built.meta, built.rawResponse,
                resolvedProvider, modelId)
    }
    #endif

    /// Shared validate → write → log → ExitCode(2) tail, identical for every parser path.
    private func finalize(_ result: BuildResult, entry: SubjectEntry, settings: Settings) throws {
        let doc = result.document
        let issues = BridgeKit.validate(doc)   // disambiguate from Parse.validate() (ParsableCommand)
        for i in issues { try? FileHandle.standardError.write(contentsOf: Data("[\(i.severity)] \(i.message)\n".utf8)) }
        if issues.contains(where: { $0.severity == .error }) { throw Fail("validation failed") }

        let dir = settings.dataRoot.appendingPathComponent("subjects/\(entry.subjectId)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("\(doc.source.sha256).bridge.json")
        try BridgeJSON.encoder.encode(doc).write(to: out, options: .atomic)

        if settings.logLevel != .quiet {
            let mapped = doc.observations.filter { $0.mapping != nil }.count
            log("Wrote \(out.path): \(doc.observations.count) observations, \(mapped) mapped, \(doc.observations.count - mapped) unmapped, \(result.skipped.count) skipped.")
            for o in doc.observations where o.mapping == nil {
                log("  unmapped: \(o.code?.code ?? "—") \(o.name)")
            }
            for s in result.skipped { log("  skipped (\(s.reason)): \(s.label)") }
        }
        if doc.observations.isEmpty { throw ExitCode(2) }   // wrote an empty document
    }

    private func log(_ s: String) { try? FileHandle.standardError.write(contentsOf: Data((s + "\n").utf8)) }

    /// #4 CLI edge: encode + append the raw-response eval-log entry. Provider name is the enum
    /// rawValue ("anthropic"/"openai"); apiVersion is the Anthropic header for Anthropic, nil for
    /// OpenAI. Failures to write are non-fatal (best-effort observability) and surfaced to stderr.
    private func writeRawResponseLog(sha: String, provider: Provider, model: String,
                                     meta: LLMResponseMeta?, rawResponse: String,
                                     settings: Settings, logPathOverride: String?) {
        let apiVersion = provider == .anthropic ? AnthropicExtractor.anthropicVersion : nil
        let entry = RawResponseLog.encodeEntry(
            timestamp: Date().ISO8601Format(),
            contentSHA256: sha, provider: provider.rawValue, model: model,
            apiVersion: apiVersion, meta: meta, rawResponse: rawResponse)
        let url = rawResponseLogURL(dataRoot: settings.dataRoot, override: logPathOverride)
        do { try RawResponseLog.append(entry: entry, to: url) }
        catch { log("warning: could not write raw-response log at \(url.path): \(error)") }
    }

    /// Pure: format the one-line LLM usage summary for --verbose. Nil fields render as "—".
    /// PDF/LLM path only; never printed at .normal/.quiet; carries no key.
    private func llmUsageLine(_ meta: LLMResponseMeta) -> String {
        func f(_ v: Int?) -> String { v.map(String.init) ?? "—" }
        return "LLM usage: input=\(f(meta.inputTokens)) output=\(f(meta.outputTokens)) stop=\(meta.stopReason ?? "—")"
    }
    private func mismatchDetail(_ data: Data, _ entry: SubjectEntry) -> String {
        let ext = PatientMatch.extracted(data: data)
        return "  document: \(ext?.name ?? "?") / \(ext?.dob ?? "?")\n  roster:   \(entry.name) / \(entry.dob)"
    }
}

struct Subject: ParsableCommand {
    static let configuration = CommandConfiguration(subcommands: [Add.self, List.self])

    struct Add: ParsableCommand {
        @Option(name: .long) var label: String
        @Option(name: .long) var name: String
        @Option(name: .long) var dob: String
        @Option(name: .long, help: "Explicit roster key (defaults from label).") var key: String?
        @Option(name: .long) var config: String = ConfigLoader.defaultPath
        func run() throws {
            var cfg = (try ConfigLoader.load(path: config)) ?? Config()
            let resolvedKey = key ?? label.lowercased().replacingOccurrences(of: " ", with: "-")
            let entry = SubjectEntry(key: resolvedKey, subjectId: UUID().uuidString, label: label, name: name, dob: dob)
            do { try cfg.addSubject(entry) }
            catch ConfigError.duplicateKey(let k) { throw Fail("Subject key '\(k)' already exists") }
            try ConfigWriter.write(cfg, path: config)
            print("Added subject '\(resolvedKey)' with subjectId \(entry.subjectId)")
        }
    }
    struct List: ParsableCommand {
        @Option(name: .long) var config: String = ConfigLoader.defaultPath
        func run() throws {
            let cfg = (try ConfigLoader.load(path: config)) ?? Config()
            for s in cfg.subjects { print("\(s.key)\t\(s.label)\t\(s.subjectId)") }
        }
    }
}

struct Fail: Error, CustomStringConvertible { let m: String; init(_ m: String) { self.m = m }; var description: String { m } }
