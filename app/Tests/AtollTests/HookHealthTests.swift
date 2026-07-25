import XCTest
@testable import Atoll

final class HookHealthTests: XCTestCase {
    private func verdict(cliPresent: Bool = true, enabled: Bool = true, installed: Bool = true,
                         healthy: Bool = true, error: String = "", missingHooks: Int = 0,
                         seen: Bool = false, trustGated: Bool = false) -> HookHealth {
        HookHealthPolicy.verdict(cliPresent: cliPresent, enabled: enabled, installed: installed,
                                 healthy: healthy, error: error, missingHooks: missingHooks,
                                 seen: seen, trustGated: trustGated)
    }

    func testNotDetectedWhenCLIAbsent() {
        XCTAssertEqual(verdict(cliPresent: false), .notDetected)
    }

    func testLeftoverVsNotEnabled() {
        XCTAssertEqual(verdict(enabled: false, installed: true), .leftoverConfig)
        XCTAssertEqual(verdict(enabled: false, installed: false), .notEnabled)
    }

    func testBlockersWinInOrder() {
        XCTAssertEqual(verdict(error: "config-invalid: boom"), .configInvalid)
        XCTAssertEqual(verdict(error: "bridge-missing"), .bridgeMissing)
        XCTAssertEqual(verdict(missingHooks: 2), .hooksMissing(2))
    }

    func testConnectedWhenSeen() {
        XCTAssertEqual(verdict(seen: true), .connected)
    }

    func testAwaitingEventsDistinguishesTrustGated() {
        XCTAssertEqual(verdict(seen: false, trustGated: false), .awaitingEvents(trustGated: false))
        XCTAssertEqual(verdict(seen: false, trustGated: true), .awaitingEvents(trustGated: true))
    }

    func testTrustGatedHintMentionsInAppTrust() {
        let hint = HookHealth.awaitingEvents(trustGated: true).hint
        XCTAssertTrue(hint.contains("信任"), "trust-gated hint should tell the user to trust in-app")
        let cliHint = HookHealth.awaitingEvents(trustGated: false).hint
        XCTAssertTrue(cliHint.contains("重启"), "CLI hint should suggest restarting the session")
    }

    func testConnectedIsGreenBlockersAreRed() {
        XCTAssertEqual(HookHealth.connected.color, .green)
        XCTAssertEqual(HookHealth.bridgeMissing.color, .red)
        XCTAssertEqual(HookHealth.awaitingEvents(trustGated: false).color, .orange)
    }
}
