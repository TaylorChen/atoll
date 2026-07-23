import Foundation

/// Atomic on-disk snapshot of the session *display* state, so a restart shows
/// recent agent cards immediately instead of waiting for the next hook event.
///
/// Persists presentation only. It never stores pending requests, resolvers,
/// always-allow rules, bypass flags, or held connections — those track live
/// agent intent and must always re-derive from real events (the agent request
/// is the single source of truth).
enum SessionSnapshot {
    /// Cap the snapshot so it can't grow without bound as the app runs.
    static let maxSessions = 30
    static let maxToolLogPerSession = 20

    static var defaultDirectory: URL {
        URL(fileURLWithPath: NSString(string: "~/.atoll").expandingTildeInPath)
    }

    private static func fileURL(in dir: URL) -> URL {
        dir.appendingPathComponent("sessions.json")
    }

    // MARK: Save

    /// Trim to the most-recent sessions and atomically replace the snapshot file
    /// (temp write + rename via `.atomic`), owner read/write only.
    static func save(_ sessions: [AgentSession], to directory: URL = defaultDirectory) {
        let trimmed = sessions
            .sorted { $0.lastActivity > $1.lastActivity }
            .prefix(maxSessions)
            .map { session -> AgentSession in
                var copy = session
                if copy.toolLog.count > maxToolLogPerSession {
                    copy.toolLog = Array(copy.toolLog.suffix(maxToolLogPerSession))
                }
                return copy
            }
        do {
            let data = try JSONEncoder().encode(Array(trimmed))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = fileURL(in: directory)
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("SessionSnapshot save failed: \(error)")
        }
    }

    // MARK: Load

    struct LoadResult {
        var sessions: [AgentSession] = []
        var warning: String?
    }

    /// Restore display sessions. A corrupt snapshot is isolated (renamed aside)
    /// and surfaced as a warning rather than silently swallowed or treated as
    /// "no sessions" — the caller decides how to show it.
    static func load(from directory: URL = defaultDirectory) -> LoadResult {
        let url = fileURL(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return LoadResult() }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([AgentSession].self, from: data)
            return LoadResult(sessions: decoded.map(restore), warning: nil)
        } catch {
            NSLog("SessionSnapshot load failed, isolating corrupt file: \(error)")
            let corrupt = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: corrupt)
            try? FileManager.default.moveItem(at: url, to: corrupt)
            return LoadResult(sessions: [], warning: "会话快照损坏，已隔离为 sessions.json.corrupt")
        }
    }

    /// Downgrade any state that would imply a live pending interaction — a
    /// restored card must never look like it's holding an approval or question,
    /// because the held connection is gone. Everything else is display data.
    static func restore(_ session: AgentSession) -> AgentSession {
        var s = session
        if s.state == .waitingApproval || s.state == .waitingAnswer {
            s.state = .thinking
        }
        return s
    }
}
