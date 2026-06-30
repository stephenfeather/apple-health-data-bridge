import XCTest
import ArgumentParser
@testable import bridge_eval

final class RootCommandTests: XCTestCase {
    func testRootHasFourSubcommands() {
        let names = BridgeEval.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertEqual(Set(names.compactMap { $0 }), ["run", "score", "report", "iterate"])
    }

    func testRootCommandName() {
        XCTAssertEqual(BridgeEval.configuration.commandName, "bridge-eval")
    }

    func testScoreCommandParsesRunDirOption() throws {
        let parsed = try ScoreCommand.parse(["--run-dir", "/tmp/run", "--fixtures", "/tmp/fx"])
        XCTAssertEqual(parsed.runDir, "/tmp/run")
        XCTAssertEqual(parsed.fixtures, "/tmp/fx")
    }
}
