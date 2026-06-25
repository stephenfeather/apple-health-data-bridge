import Foundation
import CryptoKit

/// SHA-256 hex helpers. CryptoKit is Apple-native (macOS) — the harness is macOS-only, so this
/// adds ZERO package dependency. Mirrors `BridgeBuilder.sha256Hex`'s lowercase-hex format so eval
/// digests are comparable to the shipping CLI's `contentSHA256`.
enum Hashing {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func promptHash(_ prompt: String) -> String {
        sha256Hex(Data(prompt.utf8))
    }
}
