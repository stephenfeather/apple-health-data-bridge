import XCTest
@testable import HealthBridgeConfig

final class ConfigWriterTests: XCTestCase {
    private func tmpPath() -> String {
        NSTemporaryDirectory() + "hb-\(UUID().uuidString)/config.toml"
    }
    func testWriteCreatesParentDirsAndRoundTrips() throws {
        let path = tmpPath()
        var c = Config(dataRoot: "~/Documents/x", defaultSubject: "jane", logLevel: "verbose")
        try c.addSubject(SubjectEntry(key: "jane", subjectId: "uuid-c", label: "Jane",
                                      name: "Jane Public", dob: "2000-01-01"))
        try ConfigWriter.write(c, path: path)            // parent dir did not exist
        let loaded = try XCTUnwrap(ConfigLoader.load(path: path))
        XCTAssertEqual(loaded, c)
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    /// #4 raw-response logging opt-in: the two new optional snake_case fields round-trip through TOML.
    func testRawResponseLogFieldsRoundTrip() throws {
        let path = tmpPath()
        let c = Config(dataRoot: "~/Documents/x", rawResponseLog: true,
                       rawResponseLogPath: "~/logs/raw.jsonl")
        try ConfigWriter.write(c, path: path)
        let loaded = try XCTUnwrap(ConfigLoader.load(path: path))
        XCTAssertEqual(loaded.rawResponseLog, true)
        XCTAssertEqual(loaded.rawResponseLogPath, "~/logs/raw.jsonl")
        XCTAssertEqual(loaded, c)
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    /// Default is OFF: absent fields decode to nil (logging disabled).
    func testRawResponseLogDefaultsNil() {
        let c = Config()
        XCTAssertNil(c.rawResponseLog)
        XCTAssertNil(c.rawResponseLogPath)
    }
}
