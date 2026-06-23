import Foundation

struct MappingEntry {
    let loinc: String
    let quantityType: String
    let canonicalUnit: String
    let convert: (Double, String?) -> Double?
}

public enum MappingTable {
    public static func resolve(loinc: String?, value: ObservationValue, unit: String?) -> HealthKitMapping? {
        guard let loinc, case .quantity(let raw) = value, let entry = table[loinc],
              let converted = entry.convert(raw, unit) else { return nil }
        return HealthKitMapping(quantityType: entry.quantityType, canonicalUnit: entry.canonicalUnit, convertedValue: converted)
    }

    private static func passthrough(_ ok: Set<String>) -> (Double, String?) -> Double? {
        { v, u in (u == nil || ok.contains(u!)) ? v : nil }
    }
    private static let mass: (Double, String?) -> Double? = { v, u in
        switch u { case "kg", nil: return v; case "g": return v/1000; case "[lb_av]", "lb": return v*0.45359237; default: return nil } }
    private static let length: (Double, String?) -> Double? = { v, u in
        switch u { case "cm", nil: return v; case "m": return v*100; case "[in_i]", "in": return v*2.54; default: return nil } }
    private static let temperature: (Double, String?) -> Double? = { v, u in
        switch u { case "Cel", "degC", nil: return v; case "[degF]", "degF": return (v-32)*5/9; default: return nil } }
    private static let glucose: (Double, String?) -> Double? = { v, u in
        switch u { case "mg/dL", "mg/dl", nil: return v; case "mmol/L", "mmol/l": return v*18.0182; default: return nil } }

    private static let table: [String: MappingEntry] = {
        let e: [MappingEntry] = [
            MappingEntry(loinc: "29463-7", quantityType: "HKQuantityTypeIdentifierBodyMass", canonicalUnit: "kg", convert: mass),
            MappingEntry(loinc: "8302-2",  quantityType: "HKQuantityTypeIdentifierHeight", canonicalUnit: "cm", convert: length),
            MappingEntry(loinc: "8310-5",  quantityType: "HKQuantityTypeIdentifierBodyTemperature", canonicalUnit: "degC", convert: temperature),
            MappingEntry(loinc: "39156-5", quantityType: "HKQuantityTypeIdentifierBodyMassIndex", canonicalUnit: "kg/m2", convert: passthrough(["kg/m2", "kg/m^2"])),
            MappingEntry(loinc: "8867-4",  quantityType: "HKQuantityTypeIdentifierHeartRate", canonicalUnit: "count/min", convert: passthrough(["/min","count/min","{beats}/min"])),
            MappingEntry(loinc: "9279-1",  quantityType: "HKQuantityTypeIdentifierRespiratoryRate", canonicalUnit: "count/min", convert: passthrough(["/min","count/min","{breaths}/min"])),
            MappingEntry(loinc: "2708-6",  quantityType: "HKQuantityTypeIdentifierOxygenSaturation", canonicalUnit: "%", convert: passthrough(["%","{percent}"])),
            MappingEntry(loinc: "8480-6",  quantityType: "HKQuantityTypeIdentifierBloodPressureSystolic", canonicalUnit: "mmHg", convert: passthrough(["mm[Hg]","mmHg"])),
            MappingEntry(loinc: "8462-4",  quantityType: "HKQuantityTypeIdentifierBloodPressureDiastolic", canonicalUnit: "mmHg", convert: passthrough(["mm[Hg]","mmHg"])),
            MappingEntry(loinc: "2339-0",  quantityType: "HKQuantityTypeIdentifierBloodGlucose", canonicalUnit: "mg/dL", convert: glucose),
        ]
        return Dictionary(uniqueKeysWithValues: e.map { ($0.loinc, $0) })
    }()
}
