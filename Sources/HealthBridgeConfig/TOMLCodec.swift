import Foundation
import TOMLKit

/// The single point of contact with TOMLKit, so any API drift is contained to one file.
public enum TOMLCodec {
    public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try TOMLDecoder().decode(type, from: text)
    }
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        try TOMLEncoder().encode(value)
    }
}
