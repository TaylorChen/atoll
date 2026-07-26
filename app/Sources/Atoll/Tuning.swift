import Foundation

/// Internal timing knobs, centralized so the app's behavioral cadence is
/// readable and tunable in one place. User-facing timings (hover/collapse/
/// completion dwell) live in `Settings`, not here.
enum Tuning {
    /// App: prune long-idle sessions on this cadence.
    static let idleCleanupInterval: TimeInterval = 300
    /// App: push AI-generated session titles from the usage bridge.
    static let titlePushInterval: TimeInterval = 10
    /// App: delay before auto-opening Settings when launched with the env flag.
    static let settingsOpenDelay: TimeInterval = 0.8

    /// Usage: re-read the rate-limit cache on this cadence.
    static let usageRefreshInterval: TimeInterval = 15

    /// NotchPanel: cursor-geometry hover poll (replaces flickery SwiftUI onHover).
    static let hoverPollInterval: TimeInterval = 0.15
    /// NotchPanel: short, damped width-and-height transition.
    static let panelAnimation: TimeInterval = 0.28

    /// Gateway: hold a card back this long before surfacing it, so auto-resolved
    /// (auto/bypass) requests close without flicker.
    static let approvalGraceDelay: TimeInterval = 0.35

    /// CodexAppServer: surface Desktop threads updated within this window.
    static let codexRecentWindow: TimeInterval = 300
}
