import XCTest
@testable import HealthBridgeParsing

/// Pure-seam tests only — NO network, NO real key. The single `URLSession.data(for:)` line in
/// `extract` is covered by the Task 9 manual smoke, never in CI.
final class OpenAIExtractorTests: XCTestCase {
    private func fixtureData(_ n: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(n)", withExtension: "json")))
    }

    // Synthetic, non-real placeholder that deliberately does NOT match the `sk-...` key denylist.
    private static let placeholderKey = "OPENAI-TEST-KEY-PLACEHOLDER"

    func testMakeRequestSetsBearerAuthAndForcesJSON() throws {
        let ex = OpenAIExtractor(apiKey: Self.placeholderKey)
        let req = try ex.makeRequest(LLMRequest(pages: ["x"], instructions: "do", model: "gpt-x"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.placeholderKey)")
        XCTAssertEqual(req.httpMethod, "POST")
        let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("response_format"), "native structured outputs must be present (D2)")
        XCTAssertTrue(body.contains("json_schema"))
        XCTAssertTrue(body.contains("strict"), "OpenAI strict mode")
        XCTAssertFalse(body.contains("output_config"), "output_config is Anthropic's key, not OpenAI's")
        XCTAssertTrue(body.contains("gpt-x"), "model id comes from the request")
    }

    func testParseEnvelopeExtractsContractText() throws {
        let raw = try OpenAIExtractor.parseEnvelope(try fixtureData("openai-envelope"))
        XCTAssertTrue(raw.jsonText.hasPrefix("{"))
        XCTAssertTrue(raw.jsonText.contains("observations") || raw.jsonText.contains("loinc"))
        // Structured-outputs JSON must still be decodable by the untrusted-output contract (validated).
        let result = try LLMResponseContract.decode(raw.jsonText, subjectId: "s")
        XCTAssertFalse(result.observations.isEmpty)
    }

    func testMalformedEnvelopeThrows() throws {
        XCTAssertThrowsError(try OpenAIExtractor.parseEnvelope(Data("{}".utf8))) {
            guard case LLMError.malformedResponse = $0 else { return XCTFail("expected .malformedResponse") }
        }
    }

    /// Key-safety: LLMError is a closed enum with no key-bearing case, so a formatted error can never
    /// echo the API key.
    func testErrorDescriptionsNeverLeakKey() {
        XCTAssertFalse("\(LLMError.transport("network request failed"))".contains(Self.placeholderKey))
        XCTAssertFalse("\(LLMError.http(status: 429))".contains(Self.placeholderKey))
        XCTAssertFalse("\(LLMError.malformedResponse("bad envelope"))".contains(Self.placeholderKey))
    }
}
