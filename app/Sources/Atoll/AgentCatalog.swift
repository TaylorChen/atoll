import SwiftUI

/// Declarative description of one supported agent. Consolidates metadata that
/// used to be scattered across ~8 call sites (color, display name, approval
/// capability, trust gating, frontmost-app keywords), so adding an agent is one
/// record instead of touching many files.
///
/// Behavioral divergence (payload parsing, response encoding) is intentionally
/// NOT here — those live in `Normalizer` / the per-source codecs, because agents
/// genuinely differ there and a table can't capture it cleanly.
struct AgentDescriptor {
    let id: String
    let displayName: String
    let color: Color
    /// Whether the agent can broker approval requests through Atoll. Monitoring
    /// is implicit for every agent; approval is the capability that varies.
    let canApprove: Bool
    /// Sandboxed desktop apps (Codex Desktop / QoderWork) gate hooks by identity
    /// and may silently skip untrusted hooks until trusted in-app.
    let trustGated: Bool
    /// Substrings that identify the agent's own app as frontmost (for the
    /// "follow focus" approval routing). Empty = CLI-only, no owning app.
    let frontmostKeywords: [String]
    /// A known-limitation note shown in Settings (e.g. an app that doesn't
    /// execute hooks yet). nil when the agent works normally.
    var note: String? = nil
}

enum AgentCatalog {
    /// Order here is the display order in Settings ▸ Integrations.
    static let all: [AgentDescriptor] = [
        AgentDescriptor(id: "claude", displayName: "Claude Code", color: .orange,
                        canApprove: true, trustGated: false, frontmostKeywords: ["claude"]),
        AgentDescriptor(id: "codex", displayName: "Codex",
                        color: Color(red: 0.35, green: 0.55, blue: 1.0),
                        canApprove: true, trustGated: true, frontmostKeywords: ["chatgpt", "codex"]),
        AgentDescriptor(id: "cursor", displayName: "Cursor Agent",
                        color: Color(red: 0.55, green: 0.85, blue: 0.45),
                        canApprove: false, trustGated: false, frontmostKeywords: ["cursor"]),
        AgentDescriptor(id: "gemini", displayName: "Gemini CLI",
                        color: Color(red: 0.30, green: 0.85, blue: 0.85),
                        canApprove: false, trustGated: false, frontmostKeywords: ["gemini"]),
        // QoderWork (desktop ~0.9.12) parses a hooks config but does not execute
        // hook commands — verified with a plain-shell canary that never fired
        // after a full restart. Effectively unavailable until it wires execution.
        AgentDescriptor(id: "qoder", displayName: "Qoder",
                        color: Color(red: 0.65, green: 0.45, blue: 1.0),
                        canApprove: false, trustGated: true, frontmostKeywords: ["qoder"],
                        note: "QoderWork 当前版本不执行外部 hooks，暂无法接入监控（等待其后续版本支持）。"),
        AgentDescriptor(id: "qwen", displayName: "Qwen Code",
                        color: Color(red: 0.75, green: 0.52, blue: 0.98),
                        canApprove: true, trustGated: false, frontmostKeywords: []),
        AgentDescriptor(id: "factory", displayName: "Factory",
                        color: Color(red: 0.43, green: 0.62, blue: 1.0),
                        canApprove: true, trustGated: false, frontmostKeywords: []),
        AgentDescriptor(id: "codebuddy", displayName: "CodeBuddy",
                        color: Color(red: 0.98, green: 0.65, blue: 0.65),
                        canApprove: true, trustGated: false, frontmostKeywords: []),
        AgentDescriptor(id: "kimi", displayName: "Kimi CLI",
                        color: Color(red: 0.25, green: 0.75, blue: 0.62),
                        canApprove: false, trustGated: false, frontmostKeywords: []),
        AgentDescriptor(id: "opencode", displayName: "OpenCode",
                        color: Color(red: 0.20, green: 0.80, blue: 0.72),
                        canApprove: true, trustGated: false, frontmostKeywords: []),
    ]

    private static let byID: [String: AgentDescriptor] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func descriptor(_ id: String) -> AgentDescriptor? { byID[id] }

    static let ids: [String] = all.map(\.id)

    static func displayName(_ id: String) -> String { byID[id]?.displayName ?? id }

    static func color(_ id: String) -> Color { byID[id]?.color ?? Color(white: 0.6) }

    static func canApprove(_ id: String) -> Bool { byID[id]?.canApprove ?? false }

    static func trustGated(_ id: String) -> Bool { byID[id]?.trustGated ?? false }

    static func frontmostKeywords(_ id: String) -> [String] { byID[id]?.frontmostKeywords ?? [] }

    static func note(_ id: String) -> String? { byID[id]?.note }

    /// Sources that can broker approvals — drives both the gateway's held-request
    /// parsing set and the Settings approval-routing picker.
    static let approveCapableIDs: Set<String> = Set(all.filter(\.canApprove).map(\.id))
}
