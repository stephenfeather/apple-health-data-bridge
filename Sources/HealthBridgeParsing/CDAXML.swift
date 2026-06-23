import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

#if canImport(FoundationXML) || os(macOS)
/// Foundation XMLDocument access for C-CDA, robust to the CDA default namespace (urn:hl7-org:v3)
/// by selecting on local-name() so no prefix registration is required.
enum CDAXML {
    static func document(_ data: Data) throws -> XMLDocument {
        do { return try XMLDocument(data: data, options: [.nodePreserveWhitespace]) }
        catch { throw ParseError.malformed("not well-formed C-CDA XML: \(error)") }
    }

    static func isClinicalDocument(_ data: Data) -> Bool {
        guard let doc = try? XMLDocument(data: data, options: []),
              let root = doc.rootElement() else { return false }
        return root.localName == "ClinicalDocument"
    }

    static func elements(_ node: XMLNode, localName: String) throws -> [XMLElement] {
        let nodes = try node.nodes(forXPath: ".//*[local-name()='\(localName)']")
        return nodes.compactMap { $0 as? XMLElement }
    }

    static func child(_ el: XMLElement, localName: String) -> XMLElement? {
        el.children?.compactMap { $0 as? XMLElement }.first { $0.localName == localName }
    }

    static func attr(_ el: XMLElement, _ name: String) -> String? {
        el.attribute(forName: name)?.stringValue
    }
}
#endif
