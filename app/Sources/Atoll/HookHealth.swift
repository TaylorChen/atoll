import SwiftUI

/// One verdict for an integration's hook health, so the Settings display is
/// driven by a single tested policy instead of scattered ad-hoc conditions.
/// `awaitingEvents` distinguishes trust-gated desktop apps (which may silently
/// skip untrusted hooks) from CLIs that just need a session restart.
enum HookHealth: Equatable {
    case notDetected              // the agent's CLI/app isn't installed
    case leftoverConfig           // Atoll config present but the integration is off
    case notEnabled               // not installed and not enabled
    case configInvalid            // config file can't be parsed
    case bridgeMissing            // hooks present but the Atoll bridge binary is gone
    case hooksMissing(Int)        // some required hook entries are absent
    case awaitingEvents(trustGated: Bool)  // healthy, but no event has arrived yet
    case connected                // healthy and events are flowing
}

enum HookHealthPolicy {
    /// Collapse the raw diagnostic fields into one verdict. Order matters: the
    /// most actionable blocker wins so the user fixes the real problem first.
    static func verdict(cliPresent: Bool, enabled: Bool, installed: Bool, healthy: Bool,
                        error: String, missingHooks: Int, seen: Bool,
                        trustGated: Bool) -> HookHealth {
        if !cliPresent { return .notDetected }
        if !enabled { return installed ? .leftoverConfig : .notEnabled }
        if error.hasPrefix("config-invalid:") { return .configInvalid }
        if error == "bridge-missing" { return .bridgeMissing }
        if missingHooks > 0 { return .hooksMissing(missingHooks) }
        if !healthy { return .configInvalid }
        return seen ? .connected : .awaitingEvents(trustGated: trustGated)
    }
}

extension HookHealth {
    var label: String {
        switch self {
        case .notDetected: return "未检测到"
        case .leftoverConfig: return "检测到残留配置"
        case .notEnabled: return "未启用"
        case .configInvalid: return "配置异常"
        case .bridgeMissing: return "bridge 缺失"
        case .hooksMissing: return "配置不完整"
        case .awaitingEvents: return "已配置"
        case .connected: return "已连接"
        }
    }

    var color: Color {
        switch self {
        case .connected: return .green
        case .configInvalid, .bridgeMissing, .hooksMissing: return .red
        case .awaitingEvents: return .orange
        default: return .secondary
        }
    }

    /// A one-line, actionable hint (empty when nothing to say).
    var hint: String {
        switch self {
        case .configInvalid: return "配置文件无法解析，请修复原文件后重新检测"
        case .bridgeMissing: return "Atoll bridge 缺失，需要重新安装或修复"
        case let .hooksMissing(n): return "Hook 配置不完整，缺少 \(n) 项"
        case let .awaitingEvents(trustGated):
            return trustGated
                ? "配置完整但还没收到事件 — 桌面应用需在应用内信任 Atoll，或重启该应用的会话"
                : "配置完整，重启该 Agent 的会话即可连接"
        default: return ""
        }
    }
}
