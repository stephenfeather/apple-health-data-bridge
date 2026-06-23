import Foundation
import BridgeKit

public enum ParseError: Error, Equatable { case unrecognizedFormat; case malformed(String) }

public struct Skip: Equatable, Sendable {
    public enum Reason: Equatable, Sendable { case noCode, noDate, unrepresentableValue, negated }
    public let reason: Reason
    public let label: String
    public init(reason: Reason, label: String) { self.reason = reason; self.label = label }
}

public struct ParseResult: Sendable {
    public let observations: [Observation]
    public let skipped: [Skip]
    public init(observations: [Observation], skipped: [Skip]) { self.observations = observations; self.skipped = skipped }
}

public protocol DocumentParser {
    static func canParse(_ data: Data) -> Bool
    func parse(_ data: Data, subjectId: String) throws -> ParseResult
}
