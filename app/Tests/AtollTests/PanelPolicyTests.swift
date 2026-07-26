import AppKit
import XCTest
@testable import Atoll

final class PanelPolicyTests: XCTestCase {
    // MARK: Notch geometry

    func testNotchWindowAddsDecorativeWingsWithoutReducingContentWidth() {
        let size = NotchGeometry.windowSize(contentWidth: 182, height: 26)
        XCTAssertEqual(size.width, 196)
        XCTAssertEqual(size.height, 26)
    }

    func testExpandedWindowUsesTheLargerNativeCornerWing() {
        let size = NotchGeometry.windowSize(
            contentWidth: 600, height: 560,
            wingWidth: NotchGeometry.expandedWingWidth)
        XCTAssertEqual(size.width, 628)
        XCTAssertEqual(size.height, 560)
    }

    func testNotchShapeIsWideAtTheTopAndInsetBelowTheCorner() {
        let path = NotchShape(topRadius: 7, bottomRadius: 8)
            .path(in: CGRect(x: 0, y: 0, width: 196, height: 26))

        XCTAssertTrue(path.contains(CGPoint(x: 6, y: 1)),
                      "the top wing should connect to the menu bar")
        XCTAssertFalse(path.contains(CGPoint(x: 1, y: 10)),
                       "the body should curve inward below the top wing")
    }

    func testPhysicalNotchGeometryWinsOverFallback() {
        let compact = NotchGeometry.collapsedWindowSize(
            style: .compact, fallbackContentWidth: 182, fallbackHeight: 26,
            safeAreaTop: 32, auxiliaryLeftMaxX: 620, auxiliaryRightMinX: 820)
        let detailed = NotchGeometry.collapsedWindowSize(
            style: .detailed, fallbackContentWidth: 182, fallbackHeight: 26,
            safeAreaTop: 32, auxiliaryLeftMaxX: 620, auxiliaryRightMinX: 820)

        XCTAssertEqual(compact, NSSize(width: 200, height: 32))
        XCTAssertEqual(detailed, NSSize(width: 372, height: 32))
    }

    func testNoNotchDisplayUsesMeasuredNativeAppFallback() {
        let size = NotchGeometry.collapsedWindowSize(
            style: .compact, fallbackContentWidth: 182, fallbackHeight: 26,
            safeAreaTop: 0, auxiliaryLeftMaxX: nil, auxiliaryRightMinX: nil)
        XCTAssertEqual(size, NSSize(width: 196, height: 26))
    }

    func testNotchFrameStaysTopCentredWhileChangingWidthAndHeight() {
        let screen = NSRect(x: 100, y: 50, width: 1_400, height: 900)
        let collapsed = NotchGeometry.frame(
            screenFrame: screen, size: NSSize(width: 196, height: 26))
        let expanded = NotchGeometry.frame(
            screenFrame: screen, size: NSSize(width: 628, height: 500))

        XCTAssertEqual(collapsed.midX, screen.midX)
        XCTAssertEqual(expanded.midX, screen.midX)
        XCTAssertEqual(collapsed.maxY, screen.maxY)
        XCTAssertEqual(expanded.maxY, screen.maxY)
    }

    func testCollapsedHoverExcludesTransparentWingsButExpandedUsesFullPanel() {
        let target = NSRect(x: 500, y: 900, width: 196, height: 26)
        let collapsed = NotchGeometry.interactionFrame(targetFrame: target, expanded: false)
        let expanded = NotchGeometry.interactionFrame(targetFrame: target, expanded: true)

        XCTAssertEqual(collapsed.width, 186) // 182pt body + 2pt margin per side
        XCTAssertEqual(collapsed.midX, target.midX)
        XCTAssertEqual(expanded.width, 200) // full window + margin
    }

    func testLegacyDefaultGeometryMigratesWithoutOverwritingCustomValues() {
        let suite = "AtollTests.PanelGeometry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(240.0, forKey: "notchWidth")
        defaults.set(40.0, forKey: "notchHeight")

        PanelGeometryDefaults.migrate(defaults)

        XCTAssertEqual(defaults.double(forKey: "notchWidth"), PanelGeometryDefaults.notchWidth)
        XCTAssertEqual(defaults.double(forKey: "notchHeight"), 40,
                       "a custom height must not be replaced by the migration")
    }

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
