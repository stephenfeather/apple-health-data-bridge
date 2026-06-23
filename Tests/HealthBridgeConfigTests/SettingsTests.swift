import XCTest
@testable import HealthBridgeConfig

final class SettingsTests: XCTestCase {
    private func config() -> Config {
        Config(dataRoot: "~/from-toml", defaultSubject: "jane", logLevel: "normal",
               subjects: [SubjectEntry(key: "jane", subjectId: "uuid-c", label: "Jane",
                                       name: "Jane Public", dob: "2000-01-01")])
    }
    func testDefaultsWhenNoConfigNoOverrides() {
        let s = SettingsResolver.resolve(config: nil, overrides: Overrides())
        XCTAssertTrue(s.dataRoot.path.hasSuffix("Documents/apple-health-data-bridge"))
        XCTAssertEqual(s.logLevel, .normal); XCTAssertNil(s.selectedSubject)
    }
    func testConfigOverridesDefault() {
        let s = SettingsResolver.resolve(config: config(), overrides: Overrides())
        XCTAssertTrue(s.dataRoot.path.hasSuffix("from-toml"))
        XCTAssertEqual(s.selectedSubject?.key, "jane")
    }
    func testFlagOverridesConfig() {
        let s = SettingsResolver.resolve(config: config(),
                                         overrides: Overrides(dataRoot: "~/from-flag", subject: nil, logLevel: .verbose))
        XCTAssertTrue(s.dataRoot.path.hasSuffix("from-flag")); XCTAssertEqual(s.logLevel, .verbose)
    }
    func testTildeExpanded() {
        let s = SettingsResolver.resolve(config: nil, overrides: Overrides(dataRoot: "~/x"))
        XCTAssertFalse(s.dataRoot.path.contains("~"))
    }
    func testSubjectSelectionByFlag() {
        let s = SettingsResolver.resolve(config: config(), overrides: Overrides(subject: "jane"))
        XCTAssertEqual(s.selectedSubject?.subjectId, "uuid-c")
    }
    func testAddSubjectRejectsDuplicateKey() {
        var c = config()
        XCTAssertThrowsError(try c.addSubject(SubjectEntry(key: "jane", subjectId: "x", label: "C", name: "n", dob: "d"))) {
            XCTAssertEqual($0 as? ConfigError, .duplicateKey("jane"))
        }
    }
}
