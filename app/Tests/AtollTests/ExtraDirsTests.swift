import XCTest
@testable import Atoll

@MainActor
final class ExtraDirsTests: XCTestCase {
    func testParseTwoDirsInParallel() {
        let json = """
        [
          {"source":"claude","directory":"/Users/x/.claude-a","installed":true,"healthy":true,"bridgePresent":true,"error":""},
          {"source":"codex","directory":"/Users/x/.codex-b","installed":true,"healthy":false,"bridgePresent":true,"error":"hooks-missing: 1"}
        ]
        """
        let dirs = HooksManager.parseExtraDirs(json)
        XCTAssertEqual(dirs.count, 2)
        XCTAssertEqual(dirs[0].source, "claude")
        XCTAssertTrue(dirs[0].healthy)
        XCTAssertEqual(dirs[1].source, "codex")
        XCTAssertFalse(dirs[1].healthy)
        XCTAssertEqual(dirs[1].error, "hooks-missing: 1")
        XCTAssertNotEqual(dirs[0].id, dirs[1].id)
    }

    func testParseEmptyOrGarbage() {
        XCTAssertTrue(HooksManager.parseExtraDirs("[]").isEmpty)
        XCTAssertTrue(HooksManager.parseExtraDirs("not json").isEmpty)
    }

    func testParseSingleAfterRemoval() {
        let json = """
        [{"source":"claude","directory":"/Users/x/.claude-b","installed":true,"healthy":true,"bridgePresent":true,"error":""}]
        """
        let dirs = HooksManager.parseExtraDirs(json)
        XCTAssertEqual(dirs.count, 1)
        XCTAssertEqual(dirs.first?.directory, "/Users/x/.claude-b")
    }
}
