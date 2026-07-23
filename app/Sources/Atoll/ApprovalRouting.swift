import AppKit

enum ApprovalRoute: String, CaseIterable, Identifiable {
    case smart
    case atoll
    case native

    var id: String { rawValue }

    var label: String {
        switch self {
        case .smart: return "跟随焦点"
        case .atoll: return "Atoll"
        case .native: return "原生"
        }
    }
}

/// Chooses one approval surface before the hook connection is held. The pure
/// overload keeps the routing policy testable; the AppKit overload only gathers
/// current foreground context.
enum ApprovalRouter {
    @MainActor
    static func effectiveRoute(for pending: PendingRequest, store: SessionStore) -> ApprovalRoute {
        let configured = Settings.shared.approvalRoute(for: pending.source)
        let frontmost = NSWorkspace.shared.frontmostApplication
        let route = effectiveRoute(
            configured: configured,
            source: pending.source,
            sessionHasTTY: !(store.sessions[pending.sessionKey]?.tty ?? "").isEmpty,
            frontmostBundleID: frontmost?.bundleIdentifier ?? "",
            frontmostName: frontmost?.localizedName ?? ""
        )
        NSLog("ApprovalRouter source=\(pending.source) configured=\(configured.rawValue) effective=\(route.rawValue) frontmost=\(frontmost?.localizedName ?? "unknown")")
        return route
    }

    static func effectiveRoute(configured: ApprovalRoute, source: String,
                               sessionHasTTY: Bool, frontmostBundleID: String,
                               frontmostName: String) -> ApprovalRoute {
        guard configured == .smart else { return configured }
        return isAgentSurfaceFrontmost(source: source, sessionHasTTY: sessionHasTTY,
                                       bundleID: frontmostBundleID, name: frontmostName)
            ? .native : .atoll
    }

    private static func isAgentSurfaceFrontmost(source: String, sessionHasTTY: Bool,
                                                bundleID: String, name: String) -> Bool {
        let app = "\(bundleID) \(name)".lowercased()
        if app.contains("app.atoll.macos") { return false }

        if isSourceAppFrontmost(source: source, bundleID: bundleID, name: name) { return true }

        guard sessionHasTTY else { return false }
        let terminalSurfaces = [
            "terminal", "iterm", "warp", "ghostty", "kitty", "wezterm",
            "alacritty", "tabby", "cmux", "visual studio code", "vscode", "cursor",
        ]
        return terminalSurfaces.contains { app.contains($0) }
    }

    static func isSourceAppFrontmost(source: String, bundleID: String, name: String) -> Bool {
        let app = "\(bundleID) \(name)".lowercased()
        if app.contains("app.atoll.macos") { return false }
        let sourceApps: [String: [String]] = [
            "codex": ["chatgpt", "codex"],
            "claude": ["claude"],
            "cursor": ["cursor"],
            "qoder": ["qoder"],
            "gemini": ["gemini"],
        ]
        return sourceApps[source]?.contains(where: { app.contains($0) }) == true
    }
}
