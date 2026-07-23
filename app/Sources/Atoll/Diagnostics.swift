import Foundation

/// A capped, in-memory ring of recent structured errors for the diagnostic
/// report. Home-directory paths are redacted on the way in, and the buffer is
/// bounded in both count and age so it can never grow without limit.
@MainActor
enum DiagnosticsLog {
    struct Entry: Equatable {
        let time: Date
        let category: String
        let message: String
    }

    static let maxEntries = 50
    static let maxAge: TimeInterval = 24 * 3600

    private static var entries: [Entry] = []

    static func record(_ category: String, _ message: String, now: Date = Date()) {
        entries.append(Entry(time: now, category: category,
                             message: Diagnostics.redactUserPath(message)))
        prune(now: now)
    }

    static func recent(now: Date = Date()) -> [Entry] {
        prune(now: now)
        return entries
    }

    static func clear() { entries.removeAll() }

    private static func prune(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.time) > maxAge }
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
    }
}

/// Builds a redacted, local-only diagnostic report. It deliberately excludes
/// prompts, replies, tool commands, file contents, tokens and third-party config
/// bodies — only diagnostic fields, with user paths collapsed to `~`.
enum Diagnostics {
    /// Replace the user's home directory prefix with `~` wherever it appears, so
    /// absolute username paths never leak.
    static func redactUserPath(_ s: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty else { return s }
        var out = s.replacingOccurrences(of: home, with: "~")
        // Also collapse "/Users/<name>" for paths that aren't the current home.
        if let re = try? NSRegularExpression(pattern: "/Users/[^/\\s\"]+") {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                              withTemplate: "/Users/<user>")
        }
        return out
    }

    struct IntegrationDiag {
        let id: String
        let installed: Bool
        let enabled: Bool
        let healthy: Bool
        let bridgePresent: Bool
        let missingHooks: Int
        let error: String
    }

    /// Pure builder — takes already-gathered facts so it can be unit-tested with
    /// sensitive fixtures. Never receives tokens or config bodies.
    static func report(appVersion: String, osVersion: String,
                       integrations: [IntegrationDiag],
                       gatewayListening: Bool, gatewayPort: Int?,
                       settingsSummary: [String: Any],
                       recentErrors: [DiagnosticsLog.Entry]) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        return [
            "atollVersion": appVersion,
            "macOS": osVersion,
            "generatedAt": iso.string(from: Date()),
            "gateway": ["listening": gatewayListening, "port": gatewayPort as Any],
            "integrations": integrations.map {
                [
                    "id": $0.id, "installed": $0.installed, "enabled": $0.enabled,
                    "healthy": $0.healthy, "bridgePresent": $0.bridgePresent,
                    "missingHooks": $0.missingHooks,
                    "error": redactUserPath($0.error),
                ]
            },
            "settings": settingsSummary,
            "recentErrors": recentErrors.map {
                ["time": iso.string(from: $0.time), "category": $0.category,
                 "message": $0.message]   // already redacted on record
            },
        ]
    }

    static func serialize(_ report: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: report,
                                     options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// Gather live facts into a redacted report. Runs on the main actor because
    /// it reads Settings and the hooks manager.
    @MainActor
    static func collect(hooks: HooksManager) -> [String: Any] {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let port = gatewayPort()
        let integrations = hooks.clis.map {
            IntegrationDiag(id: $0.id, installed: $0.installed, enabled: $0.enabled,
                            healthy: $0.healthy, bridgePresent: $0.bridgePresent,
                            missingHooks: $0.missingHooks, error: $0.error)
        }
        let s = Settings.shared
        let summary: [String: Any] = [
            "panelWidth": s.panelWidth, "panelHeight": s.panelHeight,
            "notchWidth": s.notchWidth, "notchHeight": s.notchHeight,
            "expandOnHover": s.expandOnHover, "autoHideWhenIdle": s.autoHideWhenIdle,
            "hideInFullscreen": s.hideInFullscreen,
            "childNotifyTiming": s.childNotifyTiming.rawValue,
            "quietHoursEnabled": QuietPolicy.quietHoursEnabled,
            "systemNotifications": s.systemNotificationsEnabled,
        ]
        return report(appVersion: appVersion,
                      osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                      integrations: integrations,
                      gatewayListening: port != nil, gatewayPort: port,
                      settingsSummary: summary,
                      recentErrors: DiagnosticsLog.recent())
    }

    /// The gateway port, read from the endpoint file — the token in that file is
    /// deliberately ignored so it never reaches the report.
    static func gatewayPort() -> Int? {
        let path = NSString(string: "~/.atoll/run/endpoint").expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("ATOLL_PORT=") {
            return Int(line.dropFirst("ATOLL_PORT=".count))
        }
        return nil
    }
}
