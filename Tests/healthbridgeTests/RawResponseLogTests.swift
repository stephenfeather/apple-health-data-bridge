import XCTest
import HealthBridgeConfig
import HealthBridgeParsing
@testable import healthbridge

/// #4 — opt-in, PHI-safe raw-response logging for offline eval.
/// Pure enable-resolution + pure JSON-line encoding are tested without disk;
/// a hermetic temp-dir round-trip covers the append side effect.
final class RawResponseLogEnableTests: XCTestCase {
    // MARK: enable-resolution (OR semantics; default OFF)

    func testDisabledWhenNoSourceEnables() {
        XCTAssertFalse(rawLoggingEnabled(flag: false, env: [:], config: false))
    }

    func testFlagEnables() {
        XCTAssertTrue(rawLoggingEnabled(flag: true, env: [:], config: false))
    }

    func testConfigEnables() {
        XCTAssertTrue(rawLoggingEnabled(flag: false, env: [:], config: true))
    }

    func testEnvTruthyValuesEnable() {
        for v in ["1", "true", "TRUE", "True"] {
            XCTAssertTrue(rawLoggingEnabled(flag: false,
                                            env: ["HEALTHBRIDGE_LOG_RAW_RESPONSES": v], config: false),
                          "env value \(v) should enable")
        }
    }

    func testEnvFalsyOrUnsetDoesNotEnable() {
        for v in ["0", "false", "FALSE", "no", "", "yes"] {
            XCTAssertFalse(rawLoggingEnabled(flag: false,
                                             env: ["HEALTHBRIDGE_LOG_RAW_RESPONSES": v], config: false),
                           "env value \(v) should not enable")
        }
        XCTAssertFalse(rawLoggingEnabled(flag: false, env: [:], config: false))
    }

    func testAnySourceEnablesOR() {
        XCTAssertTrue(rawLoggingEnabled(flag: true,
                                        env: ["HEALTHBRIDGE_LOG_RAW_RESPONSES": "1"], config: true))
    }
}

final class RawResponseLogEncodeTests: XCTestCase {
    private let meta = LLMResponseMeta(inputTokens: 12, outputTokens: 48, stopReason: "end_turn")

    private func decode(_ line: String) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try XCTUnwrap(obj as? [String: Any])
    }

    func testEncodedLineHasExpectedKeysAndValues() throws {
        let line = RawResponseLog.encodeEntry(
            timestamp: "2026-06-24T00:00:00Z",
            contentSHA256: "abc123", provider: "anthropic", model: "claude-opus-4-8",
            apiVersion: "2023-06-01", meta: meta, rawResponse: "{\"patients\":[]}")
        let o = try decode(line)
        XCTAssertEqual(o["timestamp"] as? String, "2026-06-24T00:00:00Z")
        XCTAssertEqual(o["contentSHA256"] as? String, "abc123")
        XCTAssertEqual(o["provider"] as? String, "anthropic")
        XCTAssertEqual(o["model"] as? String, "claude-opus-4-8")
        XCTAssertEqual(o["apiVersion"] as? String, "2023-06-01")
        XCTAssertEqual(o["inputTokens"] as? Int, 12)
        XCTAssertEqual(o["outputTokens"] as? Int, 48)
        XCTAssertEqual(o["stopReason"] as? String, "end_turn")
        XCTAssertEqual(o["rawResponse"] as? String, "{\"patients\":[]}")
    }

    func testNoAPIKeyFieldEver() throws {
        let line = RawResponseLog.encodeEntry(
            timestamp: "2026-06-24T00:00:00Z",
            contentSHA256: "abc123", provider: "anthropic", model: "m",
            apiVersion: "2023-06-01", meta: meta, rawResponse: "{}")
        let lower = line.lowercased()
        XCTAssertFalse(lower.contains("apikey"))
        XCTAssertFalse(lower.contains("api-key"))
        XCTAssertFalse(lower.contains("api_key"))
        XCTAssertFalse(lower.contains("authorization"))
    }

    func testNilMetaOmitsTokenFields() throws {
        let line = RawResponseLog.encodeEntry(
            timestamp: "2026-06-24T00:00:00Z",
            contentSHA256: "abc123", provider: "openai", model: "gpt-5.5",
            apiVersion: nil, meta: nil, rawResponse: "{}")
        let o = try decode(line)
        XCTAssertNil(o["inputTokens"])
        XCTAssertNil(o["outputTokens"])
        XCTAssertNil(o["stopReason"])
        XCTAssertNil(o["apiVersion"])   // omitted for OpenAI
        XCTAssertEqual(o["provider"] as? String, "openai")
    }

    func testSingleLineNoEmbeddedNewline() {
        let line = RawResponseLog.encodeEntry(
            timestamp: "t", contentSHA256: "s", provider: "anthropic", model: "m",
            apiVersion: "v", meta: meta, rawResponse: "line1\nline2")
        XCTAssertFalse(line.contains("\n"))   // the entry itself is one physical line
    }
}

final class RawResponseLogAppendTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hb-rawlog-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func line(_ raw: String) -> String {
        RawResponseLog.encodeEntry(timestamp: "t", contentSHA256: "s", provider: "anthropic",
                                   model: "m", apiVersion: "v", meta: nil, rawResponse: raw)
    }

    func testAppendCreatesParentDirAndWritesLine() throws {
        let file = dir.appendingPathComponent("nested/raw-responses.jsonl")
        try RawResponseLog.append(entry: line("first"), to: file)
        let contents = try String(contentsOf: file, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(contents.hasSuffix("\n"))
    }

    func testSecondAppendYieldsTwoLines() throws {
        let file = dir.appendingPathComponent("raw-responses.jsonl")
        try RawResponseLog.append(entry: line("a"), to: file)
        try RawResponseLog.append(entry: line("b"), to: file)
        let contents = try String(contentsOf: file, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(contents.contains("\"rawResponse\":\"a\""))
        XCTAssertTrue(contents.contains("\"rawResponse\":\"b\""))
    }
}

final class RawResponseLogPathTests: XCTestCase {
    func testDefaultPathUnderDataRoot() {
        let root = URL(fileURLWithPath: "/data/root")
        let url = rawResponseLogURL(dataRoot: root, override: nil)
        XCTAssertEqual(url.path, "/data/root/raw-responses.jsonl")
    }

    func testOverridePathExpandsTilde() {
        let root = URL(fileURLWithPath: "/data/root")
        let url = rawResponseLogURL(dataRoot: root, override: "~/logs/custom.jsonl")
        XCTAssertFalse(url.path.contains("~"))
        XCTAssertTrue(url.path.hasSuffix("logs/custom.jsonl"))
    }
}
