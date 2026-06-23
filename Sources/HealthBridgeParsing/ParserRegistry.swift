import Foundation
import BridgeKit

/// Format auto-detection: tries each known parser's `canParse` in order (FHIR first, then C-CDA)
/// and returns the matching parser and its SourceKind. `nil` when no parser recognizes the bytes.
public enum ParserRegistry {
    /// Single detection point: returns the matching parser AND its SourceKind together so the two
    /// can never diverge, and so callers run format detection once. FHIR first, then guarded C-CDA.
    public static func detect(_ data: Data) -> (parser: any DocumentParser, kind: SourceKind)? {
        if FHIRParser.canParse(data) { return (FHIRParser(), .fhir) }
        #if canImport(FoundationXML) || os(macOS)
        if CCDAParser.canParse(data) { return (CCDAParser(), .ccda) }
        #endif
        return nil
    }
    public static func parser(for data: Data) -> (any DocumentParser)? { detect(data)?.parser }
    public static func sourceKind(for data: Data) -> SourceKind? { detect(data)?.kind }
}
