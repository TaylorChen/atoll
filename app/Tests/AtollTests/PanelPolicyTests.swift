import XCTest
@testable import Atoll

final class PanelPolicyTests: XCTestCase {
    // MARK: Dismiss

    func testPendingAlwaysKeepsPanelOpenForEveryTrigger() {
        for trigger in [CollapseTrigger.escKey, .outsideClick, .reminderTimeout] {
            XCTAssertFalse(
                PanelDismissPolicy.shouldCollapse(trigger: trigger, pendingPresent: true,
                                                  userOpened: false, hovering: false),
                "\(trigger) must never close a pending approval/question/plan")
        }
    }

    func testEscAndOutsideClickCollapseAReminder() {
        XCTAssertTrue(PanelDismissPolicy.shouldCollapse(trigger: .escKey, pendingPresent: false,
                                                        userOpened: false, hovering: false))
        XCTAssertTrue(PanelDismissPolicy.shouldCollapse(trigger: .outsideClick, pendingPresent: false,
                                                        userOpened: false, hovering: false))
    }

    func testReminderTimeoutSpareUserOpenedOrHoveredPanel() {
        XCTAssertTrue(PanelDismissPolicy.shouldCollapse(trigger: .reminderTimeout, pendingPresent: false,
                                                        userOpened: false, hovering: false))
        XCTAssertFalse(PanelDismissPolicy.shouldCollapse(trigger: .reminderTimeout, pendingPresent: false,
                                                         userOpened: true, hovering: false),
                       "a user-opened panel is not closed by a reminder timing out")
        XCTAssertFalse(PanelDismissPolicy.shouldCollapse(trigger: .reminderTimeout, pendingPresent: false,
                                                         userOpened: false, hovering: true),
                       "hovering holds the reminder open")
    }

    // MARK: Idle visibility

    func testHideWhenIdleOnlyWithNothingLiveAndCollapsed() {
        XCTAssertTrue(PanelVisibilityPolicy.shouldHideWhenIdle(
            enabled: true, hasLiveSession: false, pendingPresent: false,
            expanded: false, hovering: false))
    }

    func testPendingAndLiveSessionOverrideIdleHide() {
        XCTAssertFalse(PanelVisibilityPolicy.shouldHideWhenIdle(
            enabled: true, hasLiveSession: false, pendingPresent: true,
            expanded: false, hovering: false), "pending keeps the panel visible")
        XCTAssertFalse(PanelVisibilityPolicy.shouldHideWhenIdle(
            enabled: true, hasLiveSession: true, pendingPresent: false,
            expanded: false, hovering: false), "a live session keeps the panel visible")
    }

    func testExpandedHoveredOrDisabledNeverHides() {
        XCTAssertFalse(PanelVisibilityPolicy.shouldHideWhenIdle(
            enabled: true, hasLiveSession: false, pendingPresent: false,
            expanded: true, hovering: false))
        XCTAssertFalse(PanelVisibilityPolicy.shouldHideWhenIdle(
            enabled: true, hasLiveSession: false, pendingPresent: false,
            expanded: false, hovering: true))
        XCTAssertFalse(PanelVisibilityPolicy.shouldHideWhenIdle(
            enabled: false, hasLiveSession: false, pendingPresent: false,
            expanded: false, hovering: false), "disabled setting never hides")
    }
}
