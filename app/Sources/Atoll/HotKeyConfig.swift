import Carbon.HIToolbox
import Foundation

extension Notification.Name {
    /// Posted after the hotkey configuration changes so HotKeys re-registers.
    static let atollHotkeysChanged = Notification.Name("atollHotkeysChanged")
}

/// Shared, observable registration outcome so Settings can surface which
/// shortcuts the system refused to register (e.g. a combo another app owns),
/// without holding a reference to the HotKeys instance.
@MainActor
final class HotKeyStatus: ObservableObject {
    static let shared = HotKeyStatus()
    @Published var registrationFailures: Set<HotKeyAction> = []
}

/// Every keyboard action Atoll can bind. Replaces the three hard-coded Carbon
/// hotkeys with a configurable registry.
enum HotKeyAction: String, CaseIterable, Identifiable {
    case togglePanel
    case collapse
    case cycleForward
    case cycleBackward
    case approve
    case deny
    case alwaysAllow
    case autoApprove
    case jump

    var id: String { rawValue }

    var label: String {
        switch self {
        case .togglePanel: return "展开 / 收起面板"
        case .collapse: return "收起面板"
        case .cycleForward: return "切换到下一个会话"
        case .cycleBackward: return "切换到上一个会话"
        case .approve: return "允许一次"
        case .deny: return "拒绝"
        case .alwaysAllow: return "始终允许"
        case .autoApprove: return "本会话自动批准"
        case .jump: return "跳转到选中会话的终端"
        }
    }

    /// Whether the action only makes sense with a pending approval — used to
    /// guard against no-op firing.
    var needsPendingApproval: Bool {
        switch self {
        case .approve, .deny, .alwaysAllow, .autoApprove: return true
        default: return false
        }
    }

    var defaultKeyCode: UInt32 {
        switch self {
        case .togglePanel: return UInt32(kVK_ANSI_P)
        case .collapse: return UInt32(kVK_ANSI_C)
        case .cycleForward: return UInt32(kVK_ANSI_J)
        case .cycleBackward: return UInt32(kVK_ANSI_K)
        case .approve: return UInt32(kVK_ANSI_A)
        case .deny: return UInt32(kVK_ANSI_D)
        case .alwaysAllow: return UInt32(kVK_ANSI_S)
        case .autoApprove: return UInt32(kVK_ANSI_B)
        case .jump: return UInt32(kVK_ANSI_G)
        }
    }
}

/// A chosen modifier combination, offered as a small set of safe presets so a
/// user can move all Atoll shortcuts off a clashing combo at once.
enum HotKeyModifier: String, CaseIterable, Identifiable {
    case optionShift
    case controlOption
    case commandShift
    case controlCommand

    var id: String { rawValue }

    var label: String {
        switch self {
        case .optionShift: return "⌥⇧ Option+Shift"
        case .controlOption: return "⌃⌥ Control+Option"
        case .commandShift: return "⌘⇧ Command+Shift"
        case .controlCommand: return "⌃⌘ Control+Command"
        }
    }

    var carbonFlags: UInt32 {
        switch self {
        case .optionShift: return UInt32(optionKey | shiftKey)
        case .controlOption: return UInt32(controlKey | optionKey)
        case .commandShift: return UInt32(cmdKey | shiftKey)
        case .controlCommand: return UInt32(controlKey | cmdKey)
        }
    }
}

@MainActor
enum HotKeyConfig {
    /// Master switch: unregister everything but keep the bindings so the user can
    /// re-enable without reconfiguring.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "hotkeysEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "hotkeysEnabled") }
    }

    static var modifier: HotKeyModifier {
        get { HotKeyModifier(rawValue: UserDefaults.standard.string(forKey: "hotkeyModifier") ?? "")
              ?? .optionShift }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "hotkeyModifier") }
    }

    static func keyCode(for action: HotKeyAction) -> UInt32 {
        let key = "hotkey.\(action.rawValue)"
        if let v = UserDefaults.standard.object(forKey: key) as? Int, v > 0 { return UInt32(v) }
        return action.defaultKeyCode
    }

    static func setKeyCode(_ code: UInt32, for action: HotKeyAction) {
        UserDefaults.standard.set(Int(code), forKey: "hotkey.\(action.rawValue)")
    }

    static func resetToDefaults() {
        for action in HotKeyAction.allCases {
            UserDefaults.standard.removeObject(forKey: "hotkey.\(action.rawValue)")
        }
    }

    /// A–Z letter keys, offered for rebinding each action.
    static let letterKeys: [(label: String, code: UInt32)] = [
        ("A", UInt32(kVK_ANSI_A)), ("B", UInt32(kVK_ANSI_B)), ("C", UInt32(kVK_ANSI_C)),
        ("D", UInt32(kVK_ANSI_D)), ("E", UInt32(kVK_ANSI_E)), ("F", UInt32(kVK_ANSI_F)),
        ("G", UInt32(kVK_ANSI_G)), ("H", UInt32(kVK_ANSI_H)), ("I", UInt32(kVK_ANSI_I)),
        ("J", UInt32(kVK_ANSI_J)), ("K", UInt32(kVK_ANSI_K)), ("L", UInt32(kVK_ANSI_L)),
        ("M", UInt32(kVK_ANSI_M)), ("N", UInt32(kVK_ANSI_N)), ("O", UInt32(kVK_ANSI_O)),
        ("P", UInt32(kVK_ANSI_P)), ("Q", UInt32(kVK_ANSI_Q)), ("R", UInt32(kVK_ANSI_R)),
        ("S", UInt32(kVK_ANSI_S)), ("T", UInt32(kVK_ANSI_T)), ("U", UInt32(kVK_ANSI_U)),
        ("V", UInt32(kVK_ANSI_V)), ("W", UInt32(kVK_ANSI_W)), ("X", UInt32(kVK_ANSI_X)),
        ("Y", UInt32(kVK_ANSI_Y)), ("Z", UInt32(kVK_ANSI_Z)),
    ]

    static func label(for code: UInt32) -> String {
        letterKeys.first { $0.code == code }?.label ?? "?"
    }

    static func bindings() -> [(action: HotKeyAction, keyCode: UInt32)] {
        HotKeyAction.allCases.map { ($0, keyCode(for: $0)) }
    }

    /// Actions whose key code collides with another action's — surfaced so a
    /// duplicate binding is visible rather than silently shadowing.
    static func conflicts() -> Set<HotKeyAction> {
        HotKeyPolicy.conflicts(in: bindings())
    }
}

/// Pure hotkey policy, split out for tests.
enum HotKeyPolicy {
    static func conflicts(in bindings: [(action: HotKeyAction, keyCode: UInt32)]) -> Set<HotKeyAction> {
        var byCode: [UInt32: [HotKeyAction]] = [:]
        for b in bindings { byCode[b.keyCode, default: []].append(b.action) }
        return Set(byCode.values.filter { $0.count > 1 }.flatMap { $0 })
    }
}

/// Pure session-switcher cycling, matching the panel's ordering. The caller
/// passes the already-sorted, already-filtered id list so the switcher can never
/// select a hidden session.
enum SessionSwitcher {
    /// The id to select when stepping from `current`. Wraps around; starting
    /// from nil selects the first (forward) or last (backward). Empty → nil.
    static func step(ids: [String], current: String?, forward: Bool) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let idx = ids.firstIndex(of: current) else {
            return forward ? ids.first : ids.last
        }
        let next = forward ? idx + 1 : idx - 1
        return ids[(next % ids.count + ids.count) % ids.count]
    }
}
