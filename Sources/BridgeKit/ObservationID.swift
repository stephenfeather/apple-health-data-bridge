import Foundation
import CryptoKit

public enum ObservationID {
    public static func derive(subjectId: String, system: String?, code: String?,
                              effectiveDate: Date, rawValue: String, unit: String?) -> String {
        let parts = [subjectId, system ?? "", code ?? "",
                     String(Int(effectiveDate.timeIntervalSince1970.rounded())), rawValue, unit ?? ""]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1f}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
