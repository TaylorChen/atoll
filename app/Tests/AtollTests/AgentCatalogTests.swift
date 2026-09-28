import XCTest
@testable import Atoll

final class AgentCatalogTests: XCTestCase {
    func testEveryDescriptorHasUniqueID() {
        let ids = AgentCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "agent ids must be unique")
    }

    func testLookupHelpersFallBackForUnknownSource() {
        XCTAssertEqual(AgentCatalog.displayName("nope"), "nope")
        XCTAssertFalse(AgentCatalog.canApprove("nope"))
        XCTAssertFalse(AgentCatalog.trustGated("nope"))
        XCTAssertTrue(AgentCatalog.frontmostKeywords("nope").isEmpty)
    }

    func testKnownAgentsResolve() {
        XCTAssertEqual(AgentCatalog.displayName("claude"), "Claude Code")
        XCTAssertTrue(AgentCatalog.canApprove("claude"))
        XCTAssertEqual(AgentCatalog.frontmostKeywords("codex"), ["chatgpt", "codex"])
        XCTAssertTrue(AgentCatalog.trustGated("codex"))
    }

    func testQoderIsMonitorOnlyButStillTrustGated() {
        XCTAssertFalse(AgentCatalog.canApprove("qoder"),
                       "QoderWork has no PermissionRequest event → monitor only")
        XCTAssertTrue(AgentCatalog.trustGated("qoder"), "hooks are cached per session: new task needed after install")
        XCTAssertFalse(AgentCatalog.approveCapableIDs.contains("qoder"))
    }

    func testWorkingAgentsHaveNoLimitationNote() {
        XCTAssertNil(AgentCatalog.note("qoder"), "QoderWork hooks run since the ~/.qoderwork fix")
        XCTAssertNil(AgentCatalog.note("claude"))
        XCTAssertNil(AgentCatalog.note("codex"))
    }

    func testApproveCapableSetMatchesDescriptors() {
        let expected = Set(AgentCatalog.all.filter(\.canApprove).map(\.id))
        XCTAssertEqual(AgentCatalog.approveCapableIDs, expected)
        // The claude-format approval group (gateway hold + settings picker).
        XCTAssertEqual(AgentCatalog.approveCapableIDs,
                       ["claude", "codex", "qwen", "factory", "codebuddy", "opencode"])
    }

    func testMonitorOnlyAgentsAreNotApproveCapable() {
        for id in ["gemini", "cursor", "kimi", "qoder", "pi"] {
            XCTAssertFalse(AgentCatalog.canApprove(id), "\(id) should be monitor-only")
        }
    }
}
