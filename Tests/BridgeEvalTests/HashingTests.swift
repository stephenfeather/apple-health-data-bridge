import XCTest
@testable import bridge_eval

final class HashingTests: XCTestCase {
    // SHA-256("abc") known vector.
    private let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    func testSha256HexEmptyData() {
        // SHA-256 of zero bytes, known vector.
        XCTAssertEqual(Hashing.sha256Hex(Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testSha256HexKnownVector() {
        XCTAssertEqual(Hashing.sha256Hex(Data("abc".utf8)), abcDigest)
    }

    func testPromptHashMatchesUTF8Bytes() {
        XCTAssertEqual(Hashing.promptHash("abc"), abcDigest)
    }

    func testPromptHashIsStableAndDistinct() {
        XCTAssertEqual(Hashing.promptHash("prompt v1"), Hashing.promptHash("prompt v1"))
        XCTAssertNotEqual(Hashing.promptHash("prompt v1"), Hashing.promptHash("prompt v2"))
    }
}
