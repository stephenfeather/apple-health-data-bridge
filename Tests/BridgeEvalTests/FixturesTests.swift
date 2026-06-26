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

    // MARK: - parsePages (pure, form-feed split)

    func testParsePagesSinglePageNoFormFeed() throws {
        let pages = try Fixtures.parsePages("only one page")
        XCTAssertEqual(pages, ["only one page"])
    }

    func testParsePagesTwoPagesPreservesOrder() throws {
        let pages = try Fixtures.parsePages("page one\u{000C}page two")
        XCTAssertEqual(pages, ["page one", "page two"])
    }

    func testParsePagesDropsTrailingFormFeedKeepsInteriorEmpty() throws {
        // "a\f\fb\f" -> split ["a","","b",""] -> drop single trailing empty -> ["a","","b"]
        let pages = try Fixtures.parsePages("a\u{000C}\u{000C}b\u{000C}")
        XCTAssertEqual(pages, ["a", "", "b"])
    }

    func testParsePagesAllWhitespaceThrows() {
        XCTAssertThrowsError(try Fixtures.parsePages("   \n\t  ")) { error in
            XCTAssertTrue(error is Fixtures.LoadError)
        }
    }

    // MARK: - resolveInput (pure decision; both arms CI-testable)

    func testResolveInputPDFOnly() throws {
        XCTAssertEqual(try Fixtures.resolveInput(pdfExists: true, pagesText: nil), .pdf)
    }

    func testResolveInputPDFWinsOverPages() throws {
        XCTAssertEqual(try Fixtures.resolveInput(pdfExists: true, pagesText: ["p"]), .pdf)
    }

    func testResolveInputPagesWhenNoPDF() throws {
        XCTAssertEqual(try Fixtures.resolveInput(pdfExists: false, pagesText: ["p"]), .pages(["p"]))
    }

    func testResolveInputNeitherThrows() {
        XCTAssertThrowsError(try Fixtures.resolveInput(pdfExists: false, pagesText: nil)) { error in
            XCTAssertTrue(error is Fixtures.LoadError)
        }
    }
}
