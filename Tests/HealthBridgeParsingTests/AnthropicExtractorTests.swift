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

    func testMakeRequestSetsAuthHeaderAndForcesJSONViaStructuredOutputs() throws {
        let ex = AnthropicExtractor(apiKey: Self.placeholderKey)
        let req = try ex.makeRequest(LLMRequest(pages: ["x"], instructions: "do", model: "claude-x"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), Self.placeholderKey)
        XCTAssertNotNil(req.value(forHTTPHeaderField: "anthropic-version"))
        XCTAssertEqual(req.httpMethod, "POST")
        let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("output_config"), "structured outputs (output_config.format) must be present (D2)")
        XCTAssertTrue(body.contains("json_schema"))
        XCTAssertFalse(body.contains("assistant"), "no assistant PREFILL turn (prefill 400s on current models)")
        XCTAssertFalse(body.contains("tool_choice"), "must NOT use tool-use")
        XCTAssertFalse(body.contains("input_schema"), "must NOT use tool-use")
        XCTAssertTrue(body.contains("claude-x"), "model id comes from the request")
    }

    /// Contract honesty: `effectiveDate` must be NULLABLE (anyOf string|null) so a model can signal a
    /// missing date as `null` instead of being forced (required, non-nullable) to fabricate one.
    /// Kept in `required` — only the type becomes nullable.
    func testContractSchemaEffectiveDateIsNullable() throws {
        let schema = LLMResponseContract.contractSchema
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let observations = try XCTUnwrap(properties["observations"] as? [String: Any])
        let items = try XCTUnwrap(observations["items"] as? [String: Any])
        let obsProps = try XCTUnwrap(items["properties"] as? [String: Any])
        let effectiveDate = try XCTUnwrap(obsProps["effectiveDate"] as? [String: Any])
        XCTAssertNil(effectiveDate["type"], "effectiveDate must NOT be a bare type (it must be a nullable anyOf)")
        let anyOf = try XCTUnwrap(effectiveDate["anyOf"] as? [[String: Any]])
        XCTAssertTrue(anyOf.contains { ($0["type"] as? String) == "string" }, "anyOf needs a string branch")
        XCTAssertTrue(anyOf.contains { ($0["type"] as? String) == "null" }, "anyOf needs a null branch")
        // It stays REQUIRED.
        let required = try XCTUnwrap(items["required"] as? [String])
        XCTAssertTrue(required.contains("effectiveDate"))
    }

    func testParseEnvelopeExtractsContractText() throws {
        let raw = try AnthropicExtractor.parseEnvelope(try fixtureData("anthropic-envelope"))
        XCTAssertTrue(raw.jsonText.hasPrefix("{"))
        XCTAssertTrue(raw.jsonText.contains("observations") || raw.jsonText.contains("loinc"))
        // The structured-outputs JSON must be decodable by the untrusted-output contract (still validated).
        let result = try LLMResponseContract.decode(raw.jsonText, subjectId: "s")
        XCTAssertFalse(result.observations.isEmpty)
    }

    /// #3 — additive observability: token usage + stop_reason captured from the envelope.
    func testParseEnvelopeCapturesUsageAndStopReason() throws {
        let raw = try AnthropicExtractor.parseEnvelope(try fixtureData("anthropic-envelope"))
        let meta = try XCTUnwrap(raw.meta, "meta must be present when usage/stop_reason exist")
        XCTAssertEqual(meta.inputTokens, 12)
        XCTAssertEqual(meta.outputTokens, 48)
        XCTAssertEqual(meta.stopReason, "end_turn")
    }

    /// #3 — truncation signal flows through verbatim (no behavior change, just observed).
    func testParseEnvelopeCapturesTruncationStopReason() throws {
        let raw = try AnthropicExtractor.parseEnvelope(try fixtureData("anthropic-envelope-truncated"))
        let meta = try XCTUnwrap(raw.meta)
        XCTAssertEqual(meta.stopReason, "max_tokens")
        XCTAssertEqual(meta.outputTokens, 4096)
        // jsonText is STILL extracted normally — meta is purely additive, never gates extraction.
        XCTAssertTrue(raw.jsonText.hasPrefix("{"))
    }

    /// #3 — absent meta yields nil meta, never an error; jsonText still extracted.
    func testParseEnvelopeWithoutMetaYieldsNilMetaButStillExtracts() throws {
        let raw = try AnthropicExtractor.parseEnvelope(try fixtureData("anthropic-envelope-no-meta"))
        XCTAssertNil(raw.meta, "no usage/stop_reason → meta nil")
        XCTAssertTrue(raw.jsonText.hasPrefix("{"))
        XCTAssertTrue(raw.jsonText.contains("observations") || raw.jsonText.contains("loinc"))
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
