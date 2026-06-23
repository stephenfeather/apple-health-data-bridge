import Foundation
import BridgeKit

/// Format auto-detection: tries each known parser's `canParse` in order (FHIR first, then C-CDA)
/// and returns the matching parser and its SourceKind. `nil` when no parser recognizes the bytes.
public enum ParserRegistry {
    public static func parser(for data: Data) -> (any DocumentParser)? {
        if FHIRParser.canParse(data) { return FHIRParser() }
        #if canImport(FoundationXML) || os(macOS)
        if CCDAParser.canParse(data) { return CCDAParser() }
        #endif
        return nil
    }
    public static func sourceKind(for data: Data) -> SourceKind? {
        if FHIRParser.canParse(data) { return .fhir }
        #if canImport(FoundationXML) || os(macOS)
        if CCDAParser.canParse(data) { return .ccda }
        #endif
        return nil
    }
}
