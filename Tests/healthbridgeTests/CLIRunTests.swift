import XCTest

final class CLIRunTests: XCTestCase {
    private var binary: URL {
        // The test bundle sits next to the built products in .build/<config>/.
        Bundle(for: CLIRunTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("healthbridge")
    }
    private func fixturePath(_ n: String) throws -> String {
        try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(n)", withExtension: "json")).path
    }
    @discardableResult
    private func run(_ args: [String]) throws -> (status: Int32, err: String) {
        let p = Process(); p.executableURL = binary; p.arguments = args
        let ep = Pipe(); p.standardError = ep; p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
        let err = String(decoding: ep.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (p.terminationStatus, err)
    }
    private func tmpConfig() throws -> String {
        let dir = NSTemporaryDirectory() + "hbcli-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/config.toml"
        let r = try run(["subject", "add", "--label", "Jane", "--name", "Jane Public", "--dob", "2000-01-01", "--config", path])
        XCTAssertEqual(r.status, 0, r.err)
        return path
    }

    func testNoSubjectFails() throws {
        let cfg = NSTemporaryDirectory() + "empty-\(UUID().uuidString).toml"
        let r = try run(["parse", try fixturePath("bundle-vitals-and-labs"), "--config", cfg])
        XCTAssertNotEqual(r.status, 0)
    }
    func testUnknownSubjectFails() throws {
        let r = try run(["parse", try fixturePath("bundle-vitals-and-labs"), "--config", try tmpConfig(), "--subject", "nobody"])
        XCTAssertNotEqual(r.status, 0)
    }
    func testPatientMismatchRefuses() throws {
        let r = try run(["parse", try fixturePath("patient-bundle-mismatch"), "--config", try tmpConfig(), "--subject", "jane"])
        XCTAssertNotEqual(r.status, 0)
    }
    func testWritesOutputAndSummary() throws {
        let cfg = try tmpConfig()
        let dataRoot = NSTemporaryDirectory() + "hbdata-\(UUID().uuidString)"
        let r = try run(["parse", try fixturePath("patient-bundle"), "--config", cfg, "--subject", "jane", "--data-root", dataRoot])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(r.err.contains("observations"))
    }
    func testQuietSuppressesSummary() throws {
        let r = try run(["parse", try fixturePath("patient-bundle"), "--config", try tmpConfig(), "--subject", "jane",
                         "--data-root", NSTemporaryDirectory() + "q-\(UUID().uuidString)", "--quiet"])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertFalse(r.err.contains("observations"))
    }
    func testVerboseAndQuietTogetherErrors() throws {
        let r = try run(["parse", try fixturePath("patient-bundle"), "--config", try tmpConfig(), "--subject", "jane",
                         "--verbose", "--quiet"])
        XCTAssertNotEqual(r.status, 0)
    }
}
