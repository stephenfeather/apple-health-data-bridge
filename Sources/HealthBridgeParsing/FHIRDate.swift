import Foundation
import ModelsR4

/// Converts FHIR temporal values to a Foundation Date, resolving timezone-less / date-only
/// values in UTC so the same input yields the same Date on any machine.
enum FHIRDate {
    private static func utcCalendar(_ tz: TimeZone?) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz ?? TimeZone(identifier: "UTC")!
        return cal
    }

    static func date(from dt: DateTime) -> Date? {
        var c = DateComponents()
        c.year = dt.date.year
        c.month = dt.date.month.map(Int.init)
        c.day = dt.date.day.map(Int.init)
        if let t = dt.time {
            c.hour = Int(t.hour); c.minute = Int(t.minute)
            c.second = Int(NSDecimalNumber(decimal: t.second).doubleValue.rounded())
        } else {
            c.hour = 0; c.minute = 0; c.second = 0   // date-only -> UTC midnight
        }
        return utcCalendar(dt.timeZone).date(from: c)
    }

    static func date(from inst: Instant) -> Date? {
        // InstantDate has non-optional year/month/day (unlike DateTime's FHIRDate); time/timeZone non-optional too.
        var c = DateComponents()
        c.year = inst.date.year
        c.month = Int(inst.date.month)
        c.day = Int(inst.date.day)
        c.hour = Int(inst.time.hour); c.minute = Int(inst.time.minute)
        c.second = Int(NSDecimalNumber(decimal: inst.time.second).doubleValue.rounded())
        return utcCalendar(inst.timeZone).date(from: c)
    }
}
