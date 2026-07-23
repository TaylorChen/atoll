import Foundation

/// What asked the panel to collapse. All three share one decision so ESC,
/// outside-click and the completion reminder timeout can never disagree.
enum CollapseTrigger {
    case escKey
    case outsideClick
    case reminderTimeout
}

enum PanelDismissPolicy {
    /// Whether a collapse trigger should actually collapse the panel.
    ///
    /// - A pending interaction (approval / question / plan) always keeps the
    ///   panel open — ESC, a click outside, or a timeout must never hide a card.
    /// - A user-opened panel (hotkey/menu) is not closed by a *completion
    ///   reminder* timing out; only ESC or an explicit outside click closes it.
    /// - Hovering also holds a reminder open.
    static func shouldCollapse(trigger: CollapseTrigger, pendingPresent: Bool,
                               userOpened: Bool, hovering: Bool) -> Bool {
        if pendingPresent { return false }
        switch trigger {
        case .escKey, .outsideClick:
            return true
        case .reminderTimeout:
            return !userOpened && !hovering
        }
    }
}

enum PanelVisibilityPolicy {
    /// Whether the whole panel should hide itself when idle. A pending request,
    /// an expanded/hovered panel, or any live session all keep it visible — this
    /// only hides the collapsed pill when there is genuinely nothing happening.
    /// Hiding the panel is not the same as removing a session.
    static func shouldHideWhenIdle(enabled: Bool, hasLiveSession: Bool,
                                   pendingPresent: Bool, expanded: Bool,
                                   hovering: Bool) -> Bool {
        guard enabled, !pendingPresent, !expanded, !hovering else { return false }
        return !hasLiveSession
    }
}
