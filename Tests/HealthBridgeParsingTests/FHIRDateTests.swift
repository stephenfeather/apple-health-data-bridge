import XCTest
import ModelsR4
@testable import HealthBridgeParsing

/// Verifies that `FHIRDate.date(from:)` rejects calendar-impossible dates that
/// Foundation would otherwise silently roll over (e.g. 2000-02-30 -> 2000-03-01),
/// while preserving valid edge dates, FHIR partial dates, and observations whose
/// seconds round to 60.
///
/// Inputs are built with ModelsR4 component initializers (never string literals)
/// so an invalid day provably reaches `FHIRDate.date(from:)`: ModelsR4 0.9.3
/// throws/clamps out-of-range month/day at construction, so month-13 / day-32 can
/// never reach our code — only calendar-impossible-but-in-range dates (Feb 30,
/// Feb 29 in a non-leap year, day 31 in a 30-day month) can.
final class FHIRDateTests: XCTestCase {

    // `FHIRDate` is ambiguous here (HealthBridgeParsing.enum vs ModelsR4.struct),
    // so the system-under-test enum is always fully qualified.
    private typealias SUT = HealthBridgeParsing.FHIRDate

    private let utc = TimeZone(identifier: "UTC")!

    private func md(_ year: Int, _ month: UInt8? = nil, _ day: UInt8? = nil) -> ModelsR4.FHIRDate {
        ModelsR4.FHIRDate(year: year, month: month, day: day)
    }

    // MARK: - Calendar-impossible dates must return nil

    func testRejectsCalendarImpossibleDateTime() {
        // Feb 30 -> rolls to Mar 1
        XCTAssertNil(SUT.date(from: DateTime(date: md(2000, 2, 30))))
        // Feb 29 in a non-leap year -> rolls to Mar 1
        XCTAssertNil(SUT.date(from: DateTime(date: md(2001, 2, 29))))
        // April has 30 days -> day 31 rolls to May 1
        XCTAssertNil(SUT.date(from: DateTime(date: md(2025, 4, 31))))
    }

    func testRejectsCalendarImpossibleDateOnly() {
        // Feb 30 date-only (e.g. Patient.birthDate)
        XCTAssertNil(SUT.date(from: md(2000, 2, 30)))
        // November has 30 days
        XCTAssertNil(SUT.date(from: md(2025, 11, 31)))
        // Feb 29 in a non-leap year date-only
        XCTAssertNil(SUT.date(from: md(2001, 2, 29)))
    }

    func testRejectsCalendarImpossibleInstant() {
        let inst = Instant(date: InstantDate(year: 2000, month: 2, day: 30),
                           time: FHIRTime(hour: 0, minute: 0, second: 0),
                           timezone: utc)
        XCTAssertNil(SUT.date(from: inst))
    }

    // MARK: - Valid edge / month-end dates must resolve

    func testAcceptsLeapAndMonthEndDates() {
        // Feb 29 in leap years (2000 divisible by 400; 2024 ordinary leap)
        XCTAssertNotNil(SUT.date(from: DateTime(date: md(2000, 2, 29))))
        XCTAssertNotNil(SUT.date(from: DateTime(date: md(2024, 2, 29))))
        // Last valid day of 31- and 30-day months
        XCTAssertNotNil(SUT.date(from: DateTime(date: md(2025, 12, 31))))
        XCTAssertNotNil(SUT.date(from: DateTime(date: md(2025, 11, 30))))
    }

    // MARK: - Partial FHIR dates must be preserved (the main regression risk)

    func testPreservesPartialFHIRDates() throws {
        // DateTime year-only: month/day are nil and must NOT be compared -> Jan 1 2025 UTC midnight
        let yearOnly = try XCTUnwrap(SUT.date(from: DateTime(date: md(2025))))
        XCTAssertEqual(yearOnly.timeIntervalSince1970, 1_735_689_600, accuracy: 1)
        // DateTime year-month: day nil -> Jun 1 2025
        let yearMonth = try XCTUnwrap(SUT.date(from: DateTime(date: md(2025, 6))))
        XCTAssertEqual(yearMonth.timeIntervalSince1970, 1_748_736_000, accuracy: 1)
        // Date-only overload year-only (DOB partial path): nil month/day coerced to 1 -> Jan 1 2010
        let dateOnlyYearOnly = try XCTUnwrap(SUT.date(from: md(2010)))
        XCTAssertEqual(dateOnlyYearOnly.timeIntervalSince1970, 1_262_304_000, accuracy: 1)
    }

    // MARK: - Seconds that round to 60 must NOT cause a drop (premortem mitigation)

    func testPreservesLeapAndFractionalSeconds() throws {
        // DateTime 09:30:59.6 -> second rounds to 60 -> carries to 09:31:00, SAME day.
        // If minute/second were compared this would wrongly drop; year/month/day-only guard keeps it.
        let fracSecond = try XCTUnwrap(Decimal(string: "59.6"))
        let frac = SUT.date(from: DateTime(date: md(2025, 3, 19),
                                           time: FHIRTime(hour: 9, minute: 30, second: fracSecond),
                                           timezone: utc))
        XCTAssertNotNil(frac)

        // Instant leap second 09:30:60 -> 09:31:00, day unchanged -> preserved.
        // A non-midnight time is used deliberately: a leap second AT 23:59:60 carries
        // across midnight and changes the day, which the .day comparison correctly drops
        // (see FHIRDate.strictDate doc comment "guarded at day granularity"). This case
        // isolates the second->minute carry, which is the premortem elephant.
        let leap = Instant(date: InstantDate(year: 2025, month: 3, day: 19),
                           time: FHIRTime(hour: 9, minute: 30, second: 60),
                           timezone: utc)
        XCTAssertNotNil(SUT.date(from: leap))
    }

    // MARK: - Valid full-date regressions (correct epochs preserved)

    func testValidFullDatesRegress() throws {
        // DateTime 2025-03-19T09:30:00Z -> mirrors existing CCDA fixture epoch
        let dt = try XCTUnwrap(SUT.date(from: DateTime(date: md(2025, 3, 19),
                                                       time: FHIRTime(hour: 9, minute: 30, second: 0),
                                                       timezone: utc)))
        XCTAssertEqual(dt.timeIntervalSince1970, 1_742_376_600, accuracy: 1)

        // Valid full date-only and leap-day date-only
        XCTAssertNotNil(SUT.date(from: md(2000, 1, 1)))
        XCTAssertNotNil(SUT.date(from: md(2024, 2, 29)))

        // Instant 2025-03-19T09:30:00Z -> same epoch
        let inst = Instant(date: InstantDate(year: 2025, month: 3, day: 19),
                           time: FHIRTime(hour: 9, minute: 30, second: 0),
                           timezone: utc)
        let instDate = try XCTUnwrap(SUT.date(from: inst))
        XCTAssertEqual(instDate.timeIntervalSince1970, 1_742_376_600, accuracy: 1)
    }
}
