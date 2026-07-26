import SwiftUI

enum PanelGeometryDefaults {
    static let panelWidth = 600.0
    static let panelHeight = 560.0
    /// Content width; NotchShape adds a 7pt decorative wing on each side.
    static let notchWidth = 182.0
    static let notchHeight = 26.0

    private static let migrationVersionKey = "panelGeometryDefaultsVersion"
    private static let currentMigrationVersion = 2
    private static let legacyNotchWidths = [190.0, 240.0, 260.0]
    private static let legacyNotchHeights = [30.0, 36.0]

    /// Migrate only values that still equal the previous defaults. Custom sizes
    /// remain untouched; missing keys naturally pick up the new fallbacks.
    static func migrate(_ defaults: UserDefaults) {
        guard defaults.integer(forKey: migrationVersionKey) < currentMigrationVersion else { return }
        if let stored = defaults.object(forKey: "notchWidth") as? NSNumber,
           legacyNotchWidths.contains(stored.doubleValue) {
            defaults.set(notchWidth, forKey: "notchWidth")
        }
        if let stored = defaults.object(forKey: "notchHeight") as? NSNumber,
           legacyNotchHeights.contains(stored.doubleValue) {
            defaults.set(notchHeight, forKey: "notchHeight")
        }
        defaults.set(currentMigrationVersion, forKey: migrationVersionKey)
    }
}

/// Central, UserDefaults-backed preferences.
/// Panel geometry defaults are tuned for a comfortable footprint.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private init() {
        PanelGeometryDefaults.migrate(.standard)
    }

    private func d<T>(_ key: String, _ fallback: T) -> T {
        UserDefaults.standard.object(forKey: key) as? T ?? fallback
    }
    private func set(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
        objectWillChange.send()
    }

    // MARK: Display — panel geometry
    var panelWidth: Double { get { d("panelWidth", PanelGeometryDefaults.panelWidth) } set { set("panelWidth", newValue) } }
    var panelHeight: Double { get { d("panelHeight", PanelGeometryDefaults.panelHeight) } set { set("panelHeight", newValue) } }
    var notchWidth: Double { get { d("notchWidth", PanelGeometryDefaults.notchWidth) } set { set("notchWidth", newValue) } }
    var notchHeight: Double { get { d("notchHeight", PanelGeometryDefaults.notchHeight) } set { set("notchHeight", newValue) } }
    var displayScreenID: String { get { d("displayScreenID", "primary") } set { set("displayScreenID", newValue) } }
    var collapsedStyle: CollapsedStyle {
        get { CollapsedStyle(rawValue: d("collapsedStyle", CollapsedStyle.compact.rawValue)) ?? .compact }
        set { set("collapsedStyle", newValue.rawValue) }
    }

    // MARK: Display — session card fields
    var showModel: Bool { get { d("showModel", true) } set { set("showModel", newValue) } }
    var showWorktree: Bool { get { d("showWorktree", true) } set { set("showWorktree", newValue) } }
    var showAgentDetail: Bool { get { d("showAgentDetail", true) } set { set("showAgentDetail", newValue) } }
    var showSubagents: Bool { get { d("showSubagents", true) } set { set("showSubagents", newValue) } }
    var showUsage: Bool { get { d("showUsage", true) } set { set("showUsage", newValue) } }

    // MARK: Behaviour — expand / collapse
    var expandOnHover: Bool { get { d("expandOnHover", true) } set { set("expandOnHover", newValue) } }
    var autoCollapseOnLeave: Bool { get { d("autoCollapseOnLeave", true) } set { set("autoCollapseOnLeave", newValue) } }
    var expandOnComplete: Bool { get { d("expandOnComplete", true) } set { set("expandOnComplete", newValue) } }
    var collapseDwell: Double { get { d("collapseDwell", 0.4) } set { set("collapseDwell", newValue) } }
    var completionDwell: Double { get { d("completionDwell", 4.0) } set { set("completionDwell", newValue) } }
    var hoverExpandDelay: Double { get { d("hoverExpandDelay", 0.15) } set { set("hoverExpandDelay", newValue) } }
    var clickSessionToJump: Bool { get { d("clickSessionToJump", true) } set { set("clickSessionToJump", newValue) } }
    var suppressCompletionPopupWhenAgentFrontmost: Bool { get { d("suppressCompletionPopupWhenAgentFrontmost", true) } set { set("suppressCompletionPopupWhenAgentFrontmost", newValue) } }

    // MARK: Behaviour — visibility
    var hideInFullscreen: Bool { get { d("hideInFullscreen", false) } set { set("hideInFullscreen", newValue) } }
    /// Hide the whole panel (not just collapse) when no session is live. This
    /// only hides the display; it never removes a session.
    var autoHideWhenIdle: Bool { get { d("autoHideWhenIdle", false) } set { set("autoHideWhenIdle", newValue) } }
    /// A click outside the panel immediately dismisses a completion/warning
    /// reminder, ignoring its remaining dwell. Approval cards are unaffected.
    var dismissOnOutsideClick: Bool { get { d("dismissOnOutsideClick", true) } set { set("dismissOnOutsideClick", newValue) } }
    var idleCleanupHours: Double { get { d("idleCleanupHours", 2) } set { set("idleCleanupHours", newValue) } }

    // MARK: Notifications and noise control
    var systemNotificationsEnabled: Bool { get { d("systemNotificationsEnabled", false) } set { set("systemNotificationsEnabled", newValue) } }
    var notifyApprovals: Bool { get { d("notifyApprovals", true) } set { set("notifyApprovals", newValue) } }
    var notifyQuestions: Bool { get { d("notifyQuestions", true) } set { set("notifyQuestions", newValue) } }
    var notifySubagentCompletions: Bool { get { d("notifySubagentCompletions", false) } set { set("notifySubagentCompletions", newValue) } }
    /// When child agents (subagents / Agent Team) should raise a completion
    /// notice. Migrates the legacy `notifySubagentCompletions` boolean once.
    var childNotifyTiming: ChildNotifyTiming {
        get {
            if let raw = UserDefaults.standard.string(forKey: "childNotifyTiming"),
               let t = ChildNotifyTiming(rawValue: raw) { return t }
            return notifySubagentCompletions ? .everyCompletion : .off
        }
        set { set("childNotifyTiming", newValue.rawValue) }
    }
    var notifyCompletions: Bool { get { d("notifyCompletions", true) } set { set("notifyCompletions", newValue) } }
    var notifyFailures: Bool { get { d("notifyFailures", true) } set { set("notifyFailures", newValue) } }
    var completionNotificationCooldown: Double { get { d("completionNotificationCooldown", 3) } set { set("completionNotificationCooldown", newValue) } }
    var suppressNotificationWhenAgentFrontmost: Bool { get { d("suppressNotificationWhenAgentFrontmost", true) } set { set("suppressNotificationWhenAgentFrontmost", newValue) } }

    func noticeEnabled(_ kind: AtollNoticeKind) -> Bool {
        switch kind {
        case .approval: return notifyApprovals
        case .question: return notifyQuestions
        case .subagentCompletion: return childNotifyTiming != .off
        case .completion: return notifyCompletions
        case .failure: return notifyFailures
        }
    }

    // MARK: Approval routing
    func approvalRoute(for source: String) -> ApprovalRoute {
        guard let raw = UserDefaults.standard.string(forKey: "approvalRoute.\(source)"),
              let route = ApprovalRoute(rawValue: raw) else { return .smart }
        return route
    }

    func setApprovalRoute(_ route: ApprovalRoute, for source: String) {
        set("approvalRoute.\(source)", route.rawValue)
    }
}
