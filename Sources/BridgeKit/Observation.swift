import Foundation

public struct CodeableRef: Codable, Equatable, Sendable {
    public var system: String; public var code: String; public var display: String
    public init(system: String, code: String, display: String) {
        self.system = system; self.code = code; self.display = display
    }
}

public enum ObservationCategory: String, Codable, Sendable { case vital, lab, other }

public struct SourceLocator: Codable, Equatable, Sendable {
    public var page: Int?; public var snippet: String?
    public init(page: Int? = nil, snippet: String? = nil) { self.page = page; self.snippet = snippet }
}

public enum ObservationValue: Equatable, Sendable {
    case quantity(Double)
    case string(String)
    private enum Kind: String, Codable { case quantity, string }
    private enum CodingKeys: String, CodingKey { case type, value }
}

extension ObservationValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .quantity: self = .quantity(try c.decode(Double.self, forKey: .value))
        case .string:   self = .string(try c.decode(String.self, forKey: .value))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .quantity(let d): try c.encode(Kind.quantity, forKey: .type); try c.encode(d, forKey: .value)
        case .string(let s):   try c.encode(Kind.string, forKey: .type);   try c.encode(s, forKey: .value)
        }
    }
}

public struct Observation: Codable, Equatable, Sendable {
    public var id: String
    public var code: CodeableRef?
    public var name: String
    public var value: ObservationValue
    public var unit: String?
    public var effectiveDate: Date
    public var category: ObservationCategory
    public var mapping: HealthKitMapping?
    public var confidence: Double
    public var sourceLocator: SourceLocator?
    public init(id: String, code: CodeableRef?, name: String, value: ObservationValue, unit: String?,
                effectiveDate: Date, category: ObservationCategory, mapping: HealthKitMapping?,
                confidence: Double, sourceLocator: SourceLocator?) {
        self.id = id; self.code = code; self.name = name; self.value = value; self.unit = unit
        self.effectiveDate = effectiveDate; self.category = category; self.mapping = mapping
        self.confidence = confidence; self.sourceLocator = sourceLocator
    }
}
