import XCTest
@testable import bridge_eval

final class FixturesTests: XCTestCase {
    private func fixturesRoot() throws -> String {
        // Bundle.module .copy("Fixtures") -> resources root; the case dirs live directly under it.
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/vitals-basic/expected", withExtension: "json"))
        return url.deletingLastPathComponent().deletingLastPathComponent().path
    }

    func testMissingExpectedThrows() throws {
        let root = try fixturesRoot()
        XCTAssertThrowsError(try Fixtures.loadExpected(root: root, caseName: "does-not-exist")) { error in
            XCTAssertTrue(error is Fixtures.LoadError)
        }
    }

    func testLoadExpectedParsesSyntheticGold() throws {
        let root = try fixturesRoot()
        let doc = try Fixtures.loadExpected(root: root, caseName: "vitals-basic")
        XCTAssertEqual(doc.patients.first?.name, "Jane Public")
        XCTAssertEqual(doc.observations.count, 2)
        XCTAssertEqual(doc.observations.first?.loinc, "8867-4")
    }

    func testDiscoverCasesFindsCaseDir() throws {
        let root = try fixturesRoot()
        let cases = try Fixtures.discoverCases(root: root)
        XCTAssertTrue(cases.contains("vitals-basic"))
    }

    func testInputPDFURLComposesPath() {
        let url = Fixtures.inputPDFURL(root: "/x", caseName: "c")
        XCTAssertEqual(url.path, "/x/c/input.pdf")
    }
}
