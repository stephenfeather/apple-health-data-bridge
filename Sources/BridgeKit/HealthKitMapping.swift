import Foundation

public struct HealthKitMapping: Codable, Equatable, Sendable {
    public var quantityType: String
    public var canonicalUnit: String
    public var convertedValue: Double
    public init(quantityType: String, canonicalUnit: String, convertedValue: Double) {
        self.quantityType = quantityType; self.canonicalUnit = canonicalUnit; self.convertedValue = convertedValue
    }
}
