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
}
