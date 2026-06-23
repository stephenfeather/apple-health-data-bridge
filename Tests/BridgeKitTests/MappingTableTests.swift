import XCTest
@testable import BridgeKit

final class MappingTableTests: XCTestCase {
    func testMapsBodyWeightKilograms() {
        let m = MappingTable.resolve(loinc: "29463-7", value: .quantity(72.5), unit: "kg")
        XCTAssertEqual(m?.quantityType, "HKQuantityTypeIdentifierBodyMass")
        XCTAssertEqual(m?.convertedValue ?? 0, 72.5, accuracy: 0.0001)
    }
    func testConvertsPoundsToKilograms() {
        let m = MappingTable.resolve(loinc: "29463-7", value: .quantity(160), unit: "[lb_av]")
        XCTAssertEqual(m?.convertedValue ?? 0, 72.5747, accuracy: 0.01)
    }
    func testConvertsFahrenheitToCelsius() {
        let m = MappingTable.resolve(loinc: "8310-5", value: .quantity(98.6), unit: "[degF]")
        XCTAssertEqual(m?.quantityType, "HKQuantityTypeIdentifierBodyTemperature")
        XCTAssertEqual(m?.convertedValue ?? 0, 37.0, accuracy: 0.05)
    }
    func testBMIUnitVariants() {
        XCTAssertNotNil(MappingTable.resolve(loinc: "39156-5", value: .quantity(22), unit: "kg/m2"))
        XCTAssertNotNil(MappingTable.resolve(loinc: "39156-5", value: .quantity(22), unit: "kg/m^2"))
    }
    func testOxygenPercentVariants() {
        XCTAssertNotNil(MappingTable.resolve(loinc: "2708-6", value: .quantity(98), unit: "%"))
        XCTAssertNotNil(MappingTable.resolve(loinc: "2708-6", value: .quantity(98), unit: "{percent}"))
    }
    func testGlucoseUnits() {
        XCTAssertEqual(MappingTable.resolve(loinc: "2339-0", value: .quantity(5), unit: "mmol/L")?.convertedValue ?? 0, 90.09, accuracy: 0.5)
        XCTAssertNotNil(MappingTable.resolve(loinc: "2339-0", value: .quantity(90), unit: "mg/dl"))
    }
    func testTemperatureCelVariant() {
        XCTAssertEqual(MappingTable.resolve(loinc: "8310-5", value: .quantity(37), unit: "Cel")?.convertedValue ?? 0, 37, accuracy: 0.01)
    }
    func testUnknownLoincReturnsNil() { XCTAssertNil(MappingTable.resolve(loinc: "1234-5", value: .quantity(1), unit: "g")) }
    func testNonQuantityReturnsNil() { XCTAssertNil(MappingTable.resolve(loinc: "29463-7", value: .string("x"), unit: nil)) }
    func testUnconvertibleUnitReturnsNil() { XCTAssertNil(MappingTable.resolve(loinc: "29463-7", value: .quantity(1), unit: "banana")) }
}
