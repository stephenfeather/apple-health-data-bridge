import XCTest
@testable import HealthBridgeParsing

/// Pure-seam tests only — NO network, NO real key. The single `URLSession.data(for:)` line in
/// `extract` is covered by the Task 9 manual smoke, never in CI.
final class AnthropicExtractorTests: XCTestCase {
    private func fixtureData(_ n: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(n)", withExtension: "json")))
    }

    // Synthetic, non-real placeholder that deliberately does NOT match the `sk-...` key denylist.
    private static let placeholderKey = "ANTHROPIC-TEST-KEY-PLACEHOLDER"

    func testMakeRequestSetsAuthHeaderAndForcesJSONViaPrefill() throws {
        let ex = AnthropicExtractor(apiKey: Self.placeholderKey)
        let req = try ex.makeRequest(LLMRequest(pages: ["x"], instructions: "do", model: "claude-x"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), Self.placeholderKey)
        XCTAssertNotNil(req.value(forHTTPHeaderField: "anthropic-version"))
        XCTAssertEqual(req.httpMethod, "POST")
        let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("assistant"), "PREFILL assistant turn must be present (D2/T1)")
        XCTAssertFalse(body.contains("tool_choice"), "must NOT use tool-use (T1)")
        XCTAssertFalse(body.contains("input_schema"), "must NOT use tool-use (T1)")
        XCTAssertTrue(body.contains("claude-x"), "model id comes from the request")
    }

    func testParseEnvelopeExtractsContractText() throws {
        let raw = try AnthropicExtractor.parseEnvelope(try fixtureData("anthropic-envelope"))
        XCTAssertTrue(raw.jsonText.hasPrefix("{"))
        XCTAssertTrue(raw.jsonText.contains("observations") || raw.jsonText.contains("loinc"))
        // Reconstructed JSON must be decodable by the untrusted-output contract.
        let result = try LLMResponseContract.decode(raw.jsonText, subjectId: "s")
        XCTAssertFalse(result.observations.isEmpty)
    }

    /// T1 prefill reconstruction: after a `{` prefill the model returns the continuation WITHOUT the
    /// leading brace, so parseEnvelope must re-prepend it.
    func testParseEnvelopeReprependsPrefillBrace() throws {
        let env = #"{"content":[{"type":"text","text":"\"observations\":[]}"}]}"#
        let raw = try AnthropicExtractor.parseEnvelope(Data(env.utf8))
        XCTAssertTrue(raw.jsonText.hasPrefix("{"))
        XCTAssertTrue(raw.jsonText.contains("observations"))
    }

    func testMalformedEnvelopeThrows() throws {
        XCTAssertThrowsError(try AnthropicExtractor.parseEnvelope(Data("{}".utf8))) {
            guard case LLMError.malformedResponse = $0 else { return XCTFail("expected .malformedResponse") }
        }
    }

    /// Key-safety: LLMError is a closed enum with no key-bearing case, so a formatted error can never
    /// echo the API key. Pinned against the placeholder we pass as the key.
    func testErrorDescriptionsNeverLeakKey() {
        XCTAssertFalse("\(LLMError.transport("network request failed"))".contains(Self.placeholderKey))
        XCTAssertFalse("\(LLMError.http(status: 401))".contains(Self.placeholderKey))
        XCTAssertFalse("\(LLMError.malformedResponse("bad envelope"))".contains(Self.placeholderKey))
    }
}
