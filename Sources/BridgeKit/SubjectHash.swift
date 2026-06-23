import Foundation
import CryptoKit

public enum SubjectHash {
    public static func make(name: String, dob: String) -> String {
        let canonical = "\(name.lowercased().trimmingCharacters(in: .whitespaces))|\(dob.trimmingCharacters(in: .whitespaces))"
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
