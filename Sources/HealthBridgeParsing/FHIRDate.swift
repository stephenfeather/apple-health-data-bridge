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

    /// Builds a Date and rejects calendar-impossible DATES that Foundation would
    /// otherwise silently roll over (e.g. 2000-02-30 -> 2000-03-01). Only the
    /// year/month/day components actually present in `c` must round-trip unchanged,
    /// so partial FHIR dates (year-only or year-month) are preserved rather than
    /// rejected.
    ///
    /// Calendar validity is checked against the DATE components only. A separate
    /// date-only `DateComponents` (year/month/day, no time) is round-tripped through
    /// the calendar: if any present component fails to round-trip unchanged the DATE
    /// is calendar-impossible and we reject. Crucially the returned value is still the
    /// FULL `date` (with time), so time rollover can never reject a valid observation.
    /// This matters at the end of day: a fractional/leap second that rounds to 60
    /// (e.g. `23:59:59.6` -> second 60) carries across midnight into the NEXT day, yet
    /// the original date is perfectly valid. Validating against date-only components
    /// keeps that observation instead of silently dropping it as `.noDate`. FHIR
    /// time-field ranges are enforced by ModelsR4 at construction, so excluding time
    /// from validation here loses no malformed-time protection; only calendar-
    /// impossible DATES (e.g. 2000-02-30) are rejected.
    // TODO (deferred): cross-parser dedup of round-trip guard — see plan 2026-06-27
    private static func strictDate(from c: DateComponents, calendar: Calendar) -> Date? {
        guard let date = calendar.date(from: c) else { return nil }
        var dateOnly = DateComponents()
        dateOnly.year = c.year
        dateOnly.month = c.month
        dateOnly.day = c.day
        guard let validationDate = calendar.date(from: dateOnly) else { return nil }
        let rt = calendar.dateComponents([.year, .month, .day], from: validationDate)
        if let v = c.year,  rt.year  != v { return nil }
        if let v = c.month, rt.month != v { return nil }
        if let v = c.day,   rt.day   != v { return nil }
        return date
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
        return strictDate(from: c, calendar: utcCalendar(dt.timeZone))
    }

    /// Date-only FHIR `date` (e.g. `Patient.birthDate`). Partial dates (year- or year-month-only)
    /// resolve to the first instant of the coarsest known component, in UTC.
    static func date(from d: ModelsR4.FHIRDate) -> Date? {
        var c = DateComponents()
        c.year = d.year
        c.month = d.month.map(Int.init) ?? 1
        c.day = d.day.map(Int.init) ?? 1
        c.hour = 0; c.minute = 0; c.second = 0
        return strictDate(from: c, calendar: utcCalendar(nil))
    }

    static func date(from inst: Instant) -> Date? {
        // InstantDate has non-optional year/month/day (unlike DateTime's FHIRDate); time/timeZone non-optional too.
        var c = DateComponents()
        c.year = inst.date.year
        c.month = Int(inst.date.month)
        c.day = Int(inst.date.day)
        c.hour = Int(inst.time.hour); c.minute = Int(inst.time.minute)
        c.second = Int(NSDecimalNumber(decimal: inst.time.second).doubleValue.rounded())
        return strictDate(from: c, calendar: utcCalendar(inst.timeZone))
    }
}
