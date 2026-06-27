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
    /// TIME components (hour/minute/second) are intentionally NOT compared. The bug
    /// class is calendar-impossible dates; sub-day time rollover is harmless
    /// precision drift. Critically, a fractional/leap second that rounds to 60
    /// (e.g. `09:30:59.6` -> second 60) legitimately carries into the minute, so
    /// comparing minute/second would WRONGLY drop a valid observation. Date
    /// integrity is still guarded at day granularity (a time that rolls across
    /// midnight changes the day and is caught by the .day comparison). FHIR
    /// time-field ranges are enforced by ModelsR4 at construction, so excluding
    /// them here loses no malformed-time protection.
    // TODO (deferred): cross-parser dedup of round-trip guard — see plan 2026-06-27
    private static func strictDate(from c: DateComponents, calendar: Calendar) -> Date? {
        guard let date = calendar.date(from: c) else { return nil }
        let rt = calendar.dateComponents([.year, .month, .day], from: date)
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
