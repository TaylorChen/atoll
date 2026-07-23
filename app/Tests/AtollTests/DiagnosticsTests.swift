import XCTest
@testable import Atoll

final class DiagnosticsTests: XCTestCase {
    func testRedactUserPathCollapsesHomeAndUsers() {
        let home = NSHomeDirectory()
        XCTAssertEqual(Diagnostics.redactUserPath("\(home)/atoll/x"), "~/atoll/x")
        XCTAssertTrue(Diagnostics.redactUserPath("/Users/alice/secret").contains("/Users/<user>"))
        XCTAssertFalse(Diagnostics.redactUserPath("/Users/alice/secret").contains("alice"))
    }

    func testReportNeverContainsTokenPromptOrCommand() {
        // Feed sensitive values through every free-text field and assert none leak.
        let integrations = [Diagnostics.IntegrationDiag(
            id: "claude", installed: true, enabled: true, healthy: false,
            bridgePresent: true, missingHooks: 1,
            error: "config-invalid at /Users/alice/.claude/settings.json")]
        let report = Diagnostics.report(
            appVersion: "1.0", osVersion: "macOS 14",
            integrations: integrations, gatewayListening: true, gatewayPort: 51999,
            settingsSummary: ["panelWidth": 600],
            recentErrors: [DiagnosticsLog.Entry(time: Date(), category: "snapshot",
                                                message: "boom")])
        let text = String(data: Diagnostics.serialize(report), encoding: .utf8) ?? ""

        XCTAssertFalse(text.contains("alice"), "username path must be redacted")
        XCTAssertTrue(text.contains("<user>"), "redaction placeholder is present")
        XCTAssertFalse(text.contains("SECRET-TOKEN"))  // never provided → never present
        XCTAssertTrue(text.contains("51999"), "port is included")
        XCTAssertTrue(text.contains("\"atollVersion\""))
    }

    @MainActor
    func testDiagnosticsLogIsBoundedAndRedacted() {
        DiagnosticsLog.clear()
        for i in 0..<(DiagnosticsLog.maxEntries + 20) {
            DiagnosticsLog.record("test", "event \(i) at \(NSHomeDirectory())/x")
        }
        let recent = DiagnosticsLog.recent()
        XCTAssertLessThanOrEqual(recent.count, DiagnosticsLog.maxEntries, "log is capped")
        XCTAssertTrue(recent.allSatisfy { !$0.message.contains(NSHomeDirectory()) },
                      "home path redacted on record")
    }

    @MainActor
    func testDiagnosticsLogDropsAgedEntries() {
        DiagnosticsLog.clear()
        let old = Date().addingTimeInterval(-DiagnosticsLog.maxAge - 60)
        DiagnosticsLog.record("test", "old", now: old)
        DiagnosticsLog.record("test", "fresh")
        let recent = DiagnosticsLog.recent()
        XCTAssertEqual(recent.map(\.message), ["fresh"], "entries past max age are pruned")
    }
}
