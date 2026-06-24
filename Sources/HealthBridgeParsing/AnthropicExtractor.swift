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

    /// JSON Schema for the response envelope, within structured-output limits: `additionalProperties:
    /// false` and every object key in `required` (optional fields are nullable types instead). No
    /// `minLength`/`maximum`/`minimum`/`multipleOf` (range validation stays in the decoder), no
    /// recursion. Shape only — the decoder enforces confidence 0...1, date validity, code/value rules.
    static let contractSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["patients", "observations"],
        "properties": [
            "patients": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["name", "dob"],
                    "properties": [
                        "name": ["type": "string"],
                        "dob": ["type": "string"],
                    ],
                ],
            ],
            "observations": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["loinc", "display", "value", "valueText", "unit",
                                 "effectiveDate", "category", "confidence", "page", "snippet"],
                    "properties": [
                        "loinc": ["type": "string"],
                        "display": ["type": "string"],
                        "value": ["type": ["number", "null"]],
                        "valueText": ["type": ["string", "null"]],
                        "unit": ["type": ["string", "null"]],
                        // Nullable so a model can honestly signal a MISSING date as null (→ decoder
                        // Skip(.noDate)) instead of being forced by a required+non-nullable field to
                        // FABRICATE one (observed: gpt-4.1/gpt-5.5 invented a DOB/today's date on a
                        // dateless PDF; claude-opus-4-8 emitted ""). Kept in `required`. Both Anthropic
                        // and OpenAI accept this anyOf form AND the `["<t>","null"]` type-union used by
                        // the other 5 optionals (confirmed via live smoke); the mixed style is
                        // intentional-but-inconsistent — unifying on one nullable form is a deferred cleanup.
                        "effectiveDate": ["anyOf": [["type": "string"], ["type": "null"]]],
                        "category": ["type": "string"],
                        "confidence": ["type": "number"],
                        "page": ["type": ["integer", "null"]],
                        "snippet": ["type": ["string", "null"]],
                    ],
                ],
            ],
        ],
    ]

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
                    "schema": Self.contractSchema,
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
        return LLMRawResponse(jsonText: text.trimmingCharacters(in: .whitespacesAndNewlines))
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
