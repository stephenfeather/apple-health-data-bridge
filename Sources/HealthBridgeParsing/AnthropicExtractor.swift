import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Anthropic Messages API adapter — the DEFAULT provider (D1).
///
/// JSON-forcing is **assistant PREFILL** (D2/T1), NOT tool-use: the request seeds the assistant turn
/// with `{` so the model continues valid JSON, and the reply stays in `content[0].text`. Anthropic's
/// Messages API has no `response_format` (that is OpenAI-only). If tool-use were ever adopted, the
/// reply would move into a `tool_use` block's `.input` and `parseEnvelope` would need to read THAT,
/// not `content[0].text`.
///
/// The two pure halves (`makeRequest`, `parseEnvelope`) are unit-tested directly; only `extract`
/// touches the network (one `URLSession.data(for:)` call wrapped in a bounded 2× retry — D5),
/// covered by the Task 9 manual smoke. The API key is held only for the auth header — never logged,
/// never placed in an error string.
public struct AnthropicExtractor: LLMExtractor {
    /// Anthropic Messages API version header. Stable GA value; confirm current at the Task 9 smoke (D6).
    static let anthropicVersion = "2023-06-01"
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

    /// PURE: build the POST request with assistant-PREFILL JSON-forcing (T1). No I/O. No tool-use.
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
                ["role": "assistant", "content": "{"],   // PREFILL — seeds JSON; reply continues after '{'
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// PURE: extract the assistant text from `content[0].text` and reconstruct the full JSON.
    /// Because the assistant turn was prefilled with `{`, the returned text continues AFTER it, so the
    /// seed is re-prepended unless the model already echoed it.
    static func parseEnvelope(_ data: Data) throws -> LLMRawResponse {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String else {
            throw LLMError.malformedResponse("unexpected Anthropic envelope shape")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = trimmed.hasPrefix("{") ? trimmed : "{" + trimmed
        return LLMRawResponse(jsonText: json)
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
                    try? await Task.sleep(nanoseconds: Self.retryDelayNanos)
                    continue
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw LLMError.http(status: http.statusCode)
                }
                return try Self.parseEnvelope(data)
            } catch let e as LLMError {
                throw e   // non-retryable HTTP or malformed envelope — surface immediately (key-free)
            } catch {
                // Transport/timeout — retry if attempts remain. Message is fixed/key-free by design.
                lastError = .transport("network request failed")
                if attempt < Self.maxRetries {
                    try? await Task.sleep(nanoseconds: Self.retryDelayNanos)
                    continue
                }
                throw lastError
            }
        }
        throw lastError
    }

    private static func isRetryable(_ status: Int) -> Bool { status == 429 || (500..<600).contains(status) }
}
