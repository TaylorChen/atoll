import XCTest
@testable import Atoll

final class HotKeyTests: XCTestCase {
    // MARK: Conflicts

    func testDefaultBindingsHaveNoConflicts() {
        let bindings = HotKeyAction.allCases.map { (action: $0, keyCode: $0.defaultKeyCode) }
        XCTAssertTrue(HotKeyPolicy.conflicts(in: bindings).isEmpty,
                      "shipped defaults must not collide")
    }

    func testDuplicateKeyCodeIsFlaggedForBothActions() {
        let dup = HotKeyAction.approve.defaultKeyCode
        let bindings: [(action: HotKeyAction, keyCode: UInt32)] = [
            (.approve, dup), (.deny, dup), (.jump, HotKeyAction.jump.defaultKeyCode),
        ]
        let conflicts = HotKeyPolicy.conflicts(in: bindings)
        XCTAssertTrue(conflicts.contains(.approve))
        XCTAssertTrue(conflicts.contains(.deny))
        XCTAssertFalse(conflicts.contains(.jump))
    }

    func testApprovalActionsAreGuardedByNeedsPending() {
        XCTAssertTrue(HotKeyAction.approve.needsPendingApproval)
        XCTAssertTrue(HotKeyAction.deny.needsPendingApproval)
        XCTAssertTrue(HotKeyAction.autoApprove.needsPendingApproval)
        XCTAssertFalse(HotKeyAction.togglePanel.needsPendingApproval)
        XCTAssertFalse(HotKeyAction.jump.needsPendingApproval)
    }

    // MARK: Switcher

    func testForwardCyclesAndWraps() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(SessionSwitcher.step(ids: ids, current: nil, forward: true), "a")
        XCTAssertEqual(SessionSwitcher.step(ids: ids, current: "a", forward: true), "b")
        XCTAssertEqual(SessionSwitcher.step(ids: ids, current: "c", forward: true), "a")
    }

    func testBackwardCyclesAndWraps() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(SessionSwitcher.step(ids: ids, current: nil, forward: false), "c")
        XCTAssertEqual(SessionSwitcher.step(ids: ids, current: "a", forward: false), "c")
        XCTAssertEqual(SessionSwitcher.step(ids: ids, current: "b", forward: false), "a")
    }

    func testEmptyListSelectsNothing() {
        XCTAssertNil(SessionSwitcher.step(ids: [], current: nil, forward: true))
        XCTAssertNil(SessionSwitcher.step(ids: [], current: "x", forward: false))
    }

    func testStaleSelectionRestartsFromEnd() {
        // Current id no longer in the (filtered) list → start fresh.
        let ids = ["a", "b"]
        XCTAssertEqual(SessionSwitcher.step(ids: ids, current: "gone", forward: true), "a")
        XCTAssertEqual(SessionSwitcher.step(ids: ids, current: "gone", forward: false), "b")
    }
}
