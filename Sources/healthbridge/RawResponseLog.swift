import Foundation
import HealthBridgeParsing

// MARK: - Opt-in raw-response eval logging (#4)
//
// PHI-safe, OFF by default. Captures the model's raw reply (the OUTPUT contract JSON) plus
// content-SHA-only input reference for offline eval. NEVER stores page/prompt text or the API key.
// The pure halves (`rawLoggingEnabled`, `RawResponseLog.encodeEntry`, `rawResponseLogURL`) are
// unit-tested without disk; `RawResponseLog.append` is the lone side effect, at the CLI edge.

/// Pure: logging is enabled by ANY source (OR semantics); default OFF.
/// 1) the `--log-raw-responses` flag, 2) `HEALTHBRIDGE_LOG_RAW_RESPONSES` truthy (`1`/`true`,
/// case-insensitive), 3) config `raw_response_log = true`. Env dict is injected for testability.
func rawLoggingEnabled(flag: Bool, env: [String: String], config: Bool) -> Bool {
    flag || envTruthy(env[rawResponseLogEnvVar]) || config
}

let rawResponseLogEnvVar = "HEALTHBRIDGE_LOG_RAW_RESPONSES"

/// Pure: a value is truthy iff it equals `1` or `true` (case-insensitive). Anything else → false.
private func envTruthy(_ value: String?) -> Bool {
    guard let v = value?.lowercased() else { return false }
    return v == "1" || v == "true"
}

/// Pure: resolve the JSONL log location. Default `<dataRoot>/raw-responses.jsonl`; an override path
/// (config `raw_response_log_path`) wins and has `~` expanded.
func rawResponseLogURL(dataRoot: URL, override: String?) -> URL {
    if let override, !override.isEmpty {
        return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
    }
    return dataRoot.appendingPathComponent("raw-responses.jsonl")
}

/// The JSONL writer. `encodeEntry` is pure (one physical line, unit-tested without disk);
/// `append` is the impure file side effect.
enum RawResponseLog {
    /// Pure: encode one eval-log entry as a single-line JSON object. Keys: timestamp, contentSHA256,
    /// provider, model, apiVersion (omitted when nil), inputTokens/outputTokens/stopReason (omitted
    /// when meta is nil or the field is nil), rawResponse. NEVER includes the API key.
    static func encodeEntry(timestamp: String, contentSHA256: String, provider: String,
                            model: String, apiVersion: String?, meta: LLMResponseMeta?,
                            rawResponse: String) -> String {
        var entry: [String: Any] = [
            "timestamp": timestamp,
            "contentSHA256": contentSHA256,
            "provider": provider,
            "model": model,
            "rawResponse": rawResponse,
        ]
        if let apiVersion { entry["apiVersion"] = apiVersion }
        if let meta {
            if let v = meta.inputTokens { entry["inputTokens"] = v }
            if let v = meta.outputTokens { entry["outputTokens"] = v }
            if let v = meta.stopReason { entry["stopReason"] = v }
        }
        // Sorted keys = stable, diff-friendly lines; no pretty-printing keeps it to one physical line.
        let data = (try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Side effect: append one newline-terminated line, creating the parent directory and file if
    /// missing. Simple, robust, single-writer (no concurrent-writer handling per spec).
    static func append(entry: String, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = Data((entry + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
        }
    }
}
