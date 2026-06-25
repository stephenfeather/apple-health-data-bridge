import XCTest
@testable import bridge_eval

final class PreflightTests: XCTestCase {
    func testTrackedPathIsRefused() {
        let result = Preflight.decide(path: "Tests/Fixtures/real.pdf", isTracked: true)
        guard case .failure(let err) = result else { return XCTFail("expected refusal") }
        XCTAssertTrue(err.message.lowercased().contains("tracked"))
    }

    func testUntrackedPathIsAllowed() {
        let result = Preflight.decide(path: "eval/fixtures/case/input.pdf", isTracked: false)
        guard case .success = result else { return XCTFail("expected allow") }
    }

    func testAssertUntrackedThrowsOnTracked() throws {
        // .gitignore is committed -> tracked -> must throw.
        XCTAssertThrowsError(try Preflight.assertUntracked(".gitignore", role: "fixtures")) { error in
            let g = error as? Preflight.GuardError
            XCTAssertNotNil(g)
            XCTAssertTrue((g?.message ?? "").contains("fixtures"))
        }
    }

    func testAssertUntrackedAllowsNonexistentLocalPath() throws {
        // A path not tracked by git (here: a scratch path) must NOT throw.
        let scratch = NSTemporaryDirectory() + "bridge-eval-untracked-\(UUID().uuidString)/input.pdf"
        XCTAssertNoThrow(try Preflight.assertUntracked(scratch, role: "fixtures"))
    }
}
