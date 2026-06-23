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
        guard FHIRParser.canParse(data) else { throw ParseError.unrecognizedFormat }
        let result = try FHIRParser().parse(data, subjectId: subject.id)
        let resolved = result.observations.map { o -> BridgeKit.Observation in
            var o = o
            o.mapping = MappingTable.resolve(loinc: o.code?.code, value: o.value, unit: o.unit)
            return o
        }
        var seen = Set<String>()
        let deduped = resolved.filter { seen.insert($0.id).inserted }
        let doc = BridgeDocument(
            schemaVersion: BridgeDocument.currentSchemaVersion,
            source: Source(kind: .fhir, fileName: fileName, sha256: sha, extractedAt: now,
                           extractor: Extractor(engine: "fhir-parser", version: "0.1.0")),
            subject: subject, observations: deduped)
        return BuildResult(document: doc, skipped: result.skipped)
    }
    public static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

public enum PatientMatchResult { case match, mismatch, noPatient, incomplete }

public enum PatientMatch {
    public static func check(data: Data, subject: SubjectEntry) -> PatientMatchResult {
        guard let patient = firstPatient(data) else { return .noPatient }
        guard let (name, dob) = nameAndDOB(patient), !name.isEmpty, !dob.isEmpty else { return .incomplete }
        let docTokens = name.lowercased().split(separator: " ").map(String.init)
        let subjTokens = subject.name.lowercased().split(separator: " ").map(String.init)
        guard let df = docTokens.first, let dl = docTokens.last,
              let sf = subjTokens.first, let sl = subjTokens.last else { return .mismatch }
        return (df == sf && dl == sl && dob == subject.dob) ? .match : .mismatch
    }
    public static func extracted(data: Data) -> (name: String, dob: String)? {
        guard let p = firstPatient(data), let (n, d) = nameAndDOB(p) else { return nil }
        return (n, d)
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
struct HealthBridge: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "healthbridge",
        abstract: "Parse medical-record documents into subject-bound Bridge Documents.",
        subcommands: [Parse.self, Subject.self])
}

struct Parse: ParsableCommand {
    @Argument(help: "Input FHIR JSON file.") var input: String
    @Option(name: .long) var config: String = ConfigLoader.defaultPath
    @Option(name: .long) var subject: String?
    @Option(name: .long) var dataRoot: String?
    // ModelsR4 also exports a `Flag` (FHIR resource), so qualify the ArgumentParser property wrapper.
    @ArgumentParser.Flag(name: .long) var verbose = false
    @ArgumentParser.Flag(name: .long) var quiet = false
    @ArgumentParser.Flag(name: .long, help: "Proceed despite a Patient mismatch.") var force = false
    @ArgumentParser.Flag(name: .long, help: "Proceed when the Patient is present but unverifiable.") var allowUnverifiedSubject = false

    func validate() throws {
        if verbose && quiet { throw ValidationError("--verbose and --quiet are mutually exclusive") }
    }

    func run() throws {
        let cfg = try ConfigLoader.load(path: config)
        let overrides = Overrides(dataRoot: dataRoot, subject: subject,
                                  logLevel: verbose ? .verbose : (quiet ? .quiet : nil))
        let settings = SettingsResolver.resolve(config: cfg, overrides: overrides)
        guard let entry = settings.selectedSubject else { throw Fail("no subject selected (set --subject or default_subject in config)") }

        let inputURL = URL(fileURLWithPath: input)
        let data = try Data(contentsOf: inputURL)

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
        let doc = result.document

        let issues = BridgeKit.validate(doc)   // disambiguate from Parse.validate() (ParsableCommand)
        for i in issues { FileHandle.standardError.write(Data("[\(i.severity)] \(i.message)\n".utf8)) }
        if issues.contains(where: { $0.severity == .error }) { throw Fail("validation failed") }

        let dir = settings.dataRoot.appendingPathComponent("subjects/\(entry.subjectId)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("\(doc.source.sha256).bridge.json")
        try BridgeJSON.encoder.encode(doc).write(to: out)

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

    private func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
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
