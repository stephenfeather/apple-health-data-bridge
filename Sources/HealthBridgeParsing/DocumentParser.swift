import Foundation
import BridgeKit

public enum ParseError: Error, Equatable { case unrecognizedFormat; case malformed(String) }

public struct Skip: Equatable, Sendable {
    public enum Reason: Equatable, Sendable { case noCode, noDate, unrepresentableValue, negated, implausibleDate }
    /// Structured, machine-readable refinement of why an entry was skipped (issue #5). Additive
    /// observability layered over `Reason` — populated at each rejection site (LLM, FHIR, and C-CDA
    /// paths all set it where applicable); `nil` when not explicitly set.
    public enum Detail: Equatable, Sendable {
        case bothValueAndText
        case noUsableValue
        case nonFiniteValue
        case confidenceOutOfRange(got: String)   // e.g. "1.5" / "missing"
        case dateMalformed
        case dateBeforeDOB
        case dateAfterNow
        case missingCode
    }
    public let reason: Reason
    public let label: String
    public let detail: Detail?            // additive, defaults nil
    public init(reason: Reason, label: String, detail: Detail? = nil) {
        self.reason = reason; self.label = label; self.detail = detail
    }
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
