import XCTest
import ArgumentParser
@testable import bridge_eval

final class IterateCommandTests: XCTestCase {
    func testIterateCommandParsesOptions() throws {
        let cmd = try IterateCommand.parse([
            "--variants", "/v",
            "--fixtures", "/f",
            "--iterate-root", "/it",
            "--models", "claude-x",
            "--samples", "3",
            "--noise-threshold", "2.0",
            "--min-improvement", "0.02",
            "--min-improvement-low-n", "0.07",
            "--max-fixture-regression", "0.04",
            "--max-variants", "5",
            "--budget-calls", "100",
            "--include-baseline",
        ])

        XCTAssertEqual(cmd.variants, "/v")
        XCTAssertEqual(cmd.fixtures, "/f")
        XCTAssertEqual(cmd.iterateRoot, "/it")
        XCTAssertEqual(cmd.models, ["claude-x"])
        XCTAssertEqual(cmd.samples, 3)
        XCTAssertEqual(cmd.noiseThreshold, 2.0)
        XCTAssertEqual(cmd.minImprovement, 0.02)
        XCTAssertEqual(cmd.minImprovementLowN, 0.07)
        XCTAssertEqual(cmd.maxFixtureRegression, 0.04)
        XCTAssertEqual(cmd.maxVariants, 5)
        XCTAssertEqual(cmd.budgetCalls, 100)
        XCTAssertTrue(cmd.includeBaseline)
    }

    func testIterateCommandDefaults() throws {
        let cmd = try IterateCommand.parse(["--models", "claude-x"])

        XCTAssertEqual(cmd.variants, "eval/prompts")
        XCTAssertEqual(cmd.iterateRoot, "eval/iterate")
        XCTAssertEqual(cmd.samples, 1)
        XCTAssertEqual(cmd.noiseThreshold, 1.0)
        XCTAssertEqual(cmd.minImprovement, 0.01)
        XCTAssertEqual(cmd.minImprovementLowN, 0.05)
        XCTAssertEqual(cmd.maxFixtureRegression, 0.05)
        XCTAssertNil(cmd.maxVariants)
        XCTAssertNil(cmd.budgetCalls)
        XCTAssertTrue(cmd.includeBaseline)   // open Q 8.1 — default true
    }

    func testIterateValidateRejectsNonPositiveSamplesAndBudget() {
        // parse() runs validate(), so a bad value makes parse throw.
        XCTAssertThrowsError(try IterateCommand.parse(["--models", "m", "--samples", "0"]))
        XCTAssertThrowsError(try IterateCommand.parse(["--models", "m", "--budget-calls", "0"]))
    }

    func testIterateValidateRejectsMultipleModels() {
        XCTAssertThrowsError(try IterateCommand.parse(["--models", "a", "b"]))
    }

    func testIterateValidateRejectsUnknownProvider() {
        XCTAssertThrowsError(try IterateCommand.parse(["--models", "m", "--provider", "foo"]))
        XCTAssertNoThrow(try IterateCommand.parse(["--models", "m", "--provider", "OpenAI"]))   // case-insensitive
    }

    func testIterateValidateRejectsNonPositiveMaxVariants() {
        XCTAssertThrowsError(try IterateCommand.parse(["--models", "m", "--max-variants", "0"]))
        XCTAssertThrowsError(try IterateCommand.parse(["--models", "m", "--max-variants", "-1"]))
        XCTAssertNoThrow(try IterateCommand.parse(["--models", "m", "--max-variants", "2"]))
        XCTAssertNoThrow(try IterateCommand.parse(["--models", "m"]))   // nil ok
    }
}
