import Foundation

/// The provider-agnostic extraction seam — the ONLY async, network-touching surface in M3.
///
/// Everything else (prompt building, response-contract decoding, observation mapping) is
/// provider-independent and lives in pure functions tested with no network. Adding a third
/// provider is a new conformance, not a refactor.
public protocol LLMExtractor: Sendable {
    /// Send the page text + extraction instructions; return the model's raw structured reply.
    /// Throws `LLMError` on transport/auth/decoding failure. NEVER logs or returns the API key.
    func extract(_ request: LLMRequest) async throws -> LLMRawResponse
}

/// What every provider needs to build a request: the per-page text, the extraction prompt
/// (which embeds the JSON contract), and the resolved provider model id (D6).
public struct LLMRequest: Sendable, Equatable {
    public let pages: [String]
    public let instructions: String
    public let model: String
    public init(pages: [String], instructions: String, model: String) {
        self.pages = pages; self.instructions = instructions; self.model = model
    }
}

/// The assistant's raw reply text, expected to be the contract JSON. Each adapter extracts this
/// from its own provider envelope; the shared `LLMResponseContract` decoder validates it as untrusted.
public struct LLMRawResponse: Sendable, Equatable {
    public let jsonText: String
    public init(jsonText: String) { self.jsonText = jsonText }
}

public enum LLMError: Error, Equatable {
    case missingAPIKey
    /// network/timeout — message MUST NOT contain the API key.
    case transport(String)
    /// 401/403/429/5xx.
    case http(status: Int)
    /// provider envelope un-parseable.
    case malformedResponse(String)
}
