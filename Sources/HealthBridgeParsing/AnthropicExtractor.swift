import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Anthropic Messages API adapter — the DEFAULT provider (D1).
///
/// JSON-forcing = **structured outputs** (`output_config.format` json_schema). Assistant PREFILL was
/// the original plan (T1) but it returns HTTP 400 on the current model family (incl. our default
/// `claude-opus-4-8`) — prefill is removed on 4.6+; the docs direct you to structured outputs. The
/// reply is a normal text block at `content[0].text` containing complete, schema-valid JSON. (If
/// structured outputs were ever unavailable, tool-use — reading the `tool_use` block's `.input` — is
/// the alternative; NOT prefill.)
///
/// Structured outputs guarantees response SHAPE, not clinical correctness, so the shared
/// `LLMResponseContract` decoder STILL validates every reply as untrusted (D2 belt-and-suspenders) —
/// e.g. confidence-range and date-validity checks live in the decoder, not the schema.
///
/// The two pure halves (`makeRequest`, `parseEnvelope`) are unit-tested directly; only `extract`
/// touches the network (one `URLSession.data(for:)` call wrapped in a bounded 2× retry — D5),
/// covered by the Task 9 manual smoke. The API key is held only for the auth header — never logged,
/// never placed in an error string.
public struct AnthropicExtractor: LLMExtractor {
    /// Anthropic Messages API version header. Confirmed current (D6).
    /// Public so the CLI can stamp it into the #4 raw-response eval log.
    public static let anthropicVersion = "2023-06-01"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let maxTokens = 4096
    /// D5: bounded retry on transient failures; real exponential backoff deferred.
    static let maxRetries = 2
    static let retryDelayNanos: UInt64 = 200_000_000   // 200ms fixed

    private let session: URLSession
    private let apiKey: String

    public init(session: URLSession = .shared, apiKey: String) {
        self.session = session
        self.apiKey = apiKey
    }

    /// PURE: build the POST request with structured-outputs JSON-forcing. No I/O. No prefill, no tool-use.
    func makeRequest(_ r: LLMRequest) throws -> URLRequest {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": r.model,
            "max_tokens": Self.maxTokens,
            "messages": [
                ["role": "user", "content": r.instructions],
            ],
            "output_config": [
                "format": [
                    "type": "json_schema",
                    "schema": LLMResponseContract.contractSchema,
                ],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// PURE: extract the complete, schema-valid JSON from `content[0].text` (no reconstruction needed
    /// with structured outputs). Throws `LLMError.malformedResponse` on an unexpected envelope shape.
    static func parseEnvelope(_ data: Data) throws -> LLMRawResponse {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String else {
            throw LLMError.malformedResponse("unexpected Anthropic envelope shape")
        }
        return LLMRawResponse(jsonText: text.trimmingCharacters(in: .whitespacesAndNewlines),
                              meta: parseMeta(obj))
    }

    /// PURE, best-effort (#3): top-level `usage.{input_tokens,output_tokens}` + `stop_reason`.
    /// Tolerant — absent/wrong-shaped fields become nil; returns nil if NO signal is present.
    /// Never throws; meta is observability, it never gates extraction.
    static func parseMeta(_ obj: [String: Any]) -> LLMResponseMeta? {
        let usage = obj["usage"] as? [String: Any]
        let inputTokens = usage?["input_tokens"] as? Int
        let outputTokens = usage?["output_tokens"] as? Int
        let stopReason = obj["stop_reason"] as? String
        guard inputTokens != nil || outputTokens != nil || stopReason != nil else { return nil }
        return LLMResponseMeta(inputTokens: inputTokens, outputTokens: outputTokens, stopReason: stopReason)
    }

    public func extract(_ request: LLMRequest) async throws -> LLMRawResponse {
        let urlRequest = try makeRequest(request)
        var lastError: LLMError = .transport("no request attempted")
        for attempt in 0...Self.maxRetries {
            do {
                let (data, response) = try await session.data(for: urlRequest)
                guard let http = response as? HTTPURLResponse else {
                    throw LLMError.transport("non-HTTP response")
                }
                if Self.isRetryable(http.statusCode), attempt < Self.maxRetries {
                    lastError = .http(status: http.statusCode)
                    try await Task.sleep(nanoseconds: Self.retryDelayNanos)
                    continue
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw LLMError.http(status: http.statusCode)
                }
                return try Self.parseEnvelope(data)
            } catch let e as LLMError {
                throw e   // non-retryable HTTP or malformed envelope — surface immediately (key-free)
            } catch is CancellationError {
                throw CancellationError()   // cooperative cancellation: never retry, surface as-is
            } catch {
                // Transport/timeout — retry if attempts remain. Message is fixed/key-free by design.
                lastError = .transport("network request failed")
                if attempt < Self.maxRetries {
                    try await Task.sleep(nanoseconds: Self.retryDelayNanos)
                    continue
                }
                throw lastError
            }
        }
        throw lastError
    }

    private static func isRetryable(_ status: Int) -> Bool { status == 429 || (500..<600).contains(status) }
}
