import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenAI Chat Completions adapter — selected via `--provider openai`.
///
/// JSON-forcing = native structured outputs (D2): `response_format: { type: "json_schema",
/// json_schema: { name, strict: true, schema } }`. Differs from Anthropic: `Authorization: Bearer`
/// (not `x-api-key`), the schema is nested under `json_schema` with a `name` + `strict: true`, and the
/// top-level key is `response_format` (not `output_config`). It reuses the SAME shape-only contract
/// schema (`AnthropicExtractor.contractSchema` — the single source of truth for the response shape;
/// a neutral home is a candidate for a later refactor). Proves the protocol generalizes — a third
/// provider is just another conformance.
///
/// Structured outputs guarantees response SHAPE, not clinical correctness, so the shared
/// `LLMResponseContract` decoder STILL validates every reply as untrusted (D2).
///
/// Pure halves (`makeRequest`, `parseEnvelope`) are unit-tested; only `extract` touches the network
/// (one `URLSession.data(for:)` call + bounded 2× retry — D5), covered by the Task 9 smoke. The key
/// is held only for the auth header — never logged, never in an error string.
public struct OpenAIExtractor: LLMExtractor {
    static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    static let schemaName = "health_observations"
    /// D5: bounded retry on transient failures; real exponential backoff deferred.
    static let maxRetries = 2
    static let retryDelayNanos: UInt64 = 200_000_000   // 200ms fixed

    private let session: URLSession
    private let apiKey: String

    public init(session: URLSession = .shared, apiKey: String) {
        self.session = session
        self.apiKey = apiKey
    }

    /// PURE: build the POST request with `response_format` json_schema (strict). No I/O.
    func makeRequest(_ r: LLMRequest) throws -> URLRequest {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": r.model,
            "messages": [
                ["role": "user", "content": r.instructions],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": Self.schemaName,
                    "strict": true,
                    "schema": AnthropicExtractor.contractSchema,
                ],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// PURE: extract the complete, schema-valid JSON from `choices[0].message.content`.
    /// Throws `LLMError.malformedResponse` on an unexpected envelope shape.
    static func parseEnvelope(_ data: Data) throws -> LLMRawResponse {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.malformedResponse("unexpected OpenAI envelope shape")
        }
        return LLMRawResponse(jsonText: content.trimmingCharacters(in: .whitespacesAndNewlines))
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
