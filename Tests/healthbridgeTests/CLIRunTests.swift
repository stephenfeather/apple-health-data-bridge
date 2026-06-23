import XCTest

final class CLIRunTests: XCTestCase {
    private var binary: URL {
        // The test bundle sits next to the built products in .build/<config>/.
        Bundle(for: CLIRunTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("healthbridge")
    }
    private func fixturePath(_ n: String, _ ext: String = "json") throws -> String {
        try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(n)", withExtension: ext)).path
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
    func testMultiPatientBundleRefuses() throws {
        // A bundle with >1 distinct Patient could leak another person's observations under the selected subject.
        let r = try run(["parse", try fixturePath("bundle-two-patients"), "--config", try tmpConfig(), "--subject", "jane"])
        XCTAssertNotEqual(r.status, 0)
    }

    // MARK: C-CDA end-to-end
    func testParsesCCDAEndToEnd() throws {
        let cfg = try tmpConfig()
        let dataRoot = NSTemporaryDirectory() + "hbccda-\(UUID().uuidString)"
        let r = try run(["parse", try fixturePath("ccda-patient", "xml"), "--config", cfg, "--subject", "jane", "--data-root", dataRoot])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertTrue(r.err.contains("observations"))
    }
    func testCCDAMismatchRefuses() throws {
        let r = try run(["parse", try fixturePath("ccda-patient-mismatch", "xml"), "--config", try tmpConfig(), "--subject", "jane"])
        XCTAssertNotEqual(r.status, 0)
    }
    // SAFETY: --force overrides the subject cross-check, NOT the multi-patient refusal.
    func testCCDAMultiPatientRefuses() throws {
        let dataRoot = NSTemporaryDirectory() + "hbccda-mp-\(UUID().uuidString)"
        let r = try run(["parse", try fixturePath("ccda-multi-patient", "xml"), "--config", try tmpConfig(),
                         "--subject", "jane", "--force", "--data-root", dataRoot])
        XCTAssertNotEqual(r.status, 0)   // --force must NOT bypass the parser's multi-patient refusal
        // And no document may be written for a refused multi-patient doc.
        let subjectsDir = dataRoot + "/subjects"
        XCTAssertFalse(FileManager.default.fileExists(atPath: subjectsDir),
                       "no Bridge Document should be written for a refused multi-patient C-CDA")
    }
}
