import XCTest
import BridgeKit
import HealthBridgeConfig
import HealthBridgeParsing
@testable import healthbridge

final class PDFCLIResolutionTests: XCTestCase {
    func testDefaultProviderIsAnthropic() throws {
        XCTAssertEqual(try resolveProvider(flag: nil), .anthropic)
        XCTAssertEqual(try resolveProvider(flag: "openai"), .openai)
        XCTAssertEqual(try resolveProvider(flag: "anthropic"), .anthropic)
    }

    func testUnknownProviderThrows() {
        XCTAssertThrowsError(try resolveProvider(flag: "bogus"))
    }

    func testResolveAPIKeyPrefersFlagThenEnv() {
        XCTAssertEqual(resolveAPIKey(flag: "k1", provider: .anthropic, env: ["ANTHROPIC_API_KEY": "k2"]), "k1")
        XCTAssertEqual(resolveAPIKey(flag: nil, provider: .anthropic, env: ["ANTHROPIC_API_KEY": "k2"]), "k2")
        XCTAssertEqual(resolveAPIKey(flag: nil, provider: .openai, env: ["OPENAI_API_KEY": "ok"]), "ok")
        XCTAssertNil(resolveAPIKey(flag: nil, provider: .openai, env: [:]))
    }
}

#if canImport(PDFKit) && os(macOS)
final class PDFBuildCLITests: XCTestCase {
    private func fixture(_ n: String, _ ext: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(n)", withExtension: ext)))
    }
    private func fixtureText(_ n: String) throws -> String {
        try String(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(n)", withExtension: "json")),
                   encoding: .utf8)
    }
    private let subject = SubjectRef(id: "11111111-1111-1111-1111-111111111111", label: "Jane",
                                     hash: "h", name: "Jane Public", dob: "2000-01-01")
    // After the fixture's observation dates (2024-03-15) so the plausible-date guard keeps them.
    private let fixedNow = Date(timeIntervalSince1970: 1_730_000_000)   // 2024-10-27

    struct MockLLMExtractor: LLMExtractor {
        let reply: String
        func extract(_ request: LLMRequest) async throws -> LLMRawResponse { .init(jsonText: reply) }
    }

    func testPDFBuildStampsPDFKindAndModelConfidence() async throws {
        let mock = MockLLMExtractor(reply: try fixtureText("llm-response-valid"))
        let out = try await BridgeBuilder.buildPDF(
            data: try fixture("pdf-patient", "pdf"), fileName: "p.pdf", subject: subject,
            extractor: mock, engine: "anthropic-llm", model: "m", now: fixedNow)
        XCTAssertEqual(out.result.document.source.kind, .pdf)
        XCTAssertEqual(out.result.document.source.extractor.engine, "anthropic-llm")
        XCTAssertTrue(out.result.document.observations.contains { $0.confidence < 1.0 })   // model confidence, not 1.0
    }

    func testKeyNeverWrittenToDocument() async throws {
        let mock = MockLLMExtractor(reply: try fixtureText("llm-response-valid"))
        let out = try await BridgeBuilder.buildPDF(
            data: try fixture("pdf-patient", "pdf"), fileName: "p.pdf", subject: subject,
            extractor: mock, engine: "anthropic-llm", model: "m", now: fixedNow)
        let json = String(decoding: try BridgeJSON.encoder.encode(out.result.document), as: UTF8.self)
        XCTAssertFalse(json.contains("ANTHROPIC_API_KEY"))
        XCTAssertFalse(json.contains("OPENAI_API_KEY"))
        XCTAssertFalse(json.lowercased().contains("api-key"))
        XCTAssertFalse(json.lowercased().contains("authorization"))
    }

    func testBuildPDFSurfacesExtractedPatient() async throws {
        let mock = MockLLMExtractor(reply: try fixtureText("llm-response-valid"))
        let out = try await BridgeBuilder.buildPDF(
            data: try fixture("pdf-patient", "pdf"), fileName: "p.pdf", subject: subject,
            extractor: mock, engine: "anthropic-llm", model: "m", now: fixedNow)
        XCTAssertEqual(out.extractedPatient?.name, "Jane Public")
        XCTAssertEqual(out.extractedPatient?.dob, "2000-01-01")
    }
}
#endif

/// Subject-binding gate + comparator parity for the PDF path (pure; no PDF/network).
final class SubjectGateTests: XCTestCase {
    private func entry(_ name: String, _ dob: String) -> SubjectEntry {
        SubjectEntry(key: "jane", subjectId: "u", label: "L", name: name, dob: dob)
    }

    func testGateProceedsOnMatchAndNoPatient() {
        XCTAssertEqual(subjectGate(.match, force: false, allowUnverified: false), .proceed)
        XCTAssertEqual(subjectGate(.noPatient, force: false, allowUnverified: false), .proceed)
    }

    func testGateRefusesMismatchUnlessForce() {
        guard case .refuse = subjectGate(.mismatch, force: false, allowUnverified: false) else {
            return XCTFail("mismatch must refuse without --force")
        }
        XCTAssertEqual(subjectGate(.mismatch, force: true, allowUnverified: false), .proceed)
    }

    func testGateRefusesIncompleteUnlessAllowUnverified() {
        guard case .refuse = subjectGate(.incomplete, force: false, allowUnverified: false) else {
            return XCTFail("incomplete must refuse without --allow-unverified-subject")
        }
        XCTAssertEqual(subjectGate(.incomplete, force: false, allowUnverified: true), .proceed)
    }

    func testPatientCompareParity() {
        let jane = entry("Jane Public", "2000-01-01")
        XCTAssertEqual(PatientMatch.compare(name: "John Sample", dob: "1980-06-15", subject: jane), .mismatch)
        XCTAssertEqual(PatientMatch.compare(name: "Jane Public", dob: "2000-01-01", subject: jane), .match)
        XCTAssertEqual(PatientMatch.compare(name: "", dob: "", subject: jane), .incomplete)   // extracted patient missing fields
    }
}
