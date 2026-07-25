import Foundation

/// Reads the rate-limit cache written by the Atoll statusLine bridge.
/// Claude Code pipes rate_limits into statusLine on every message; the bridge
/// caches the JSON and the app polls it.
struct UsageSnapshot {
    var fiveHourPercent: Double?
    var sevenDayPercent: Double?
    var fiveHourResetsAt: Date?
    var sevenDayResetsAt: Date?
    var contextPercent: Double?
    var updatedAt: Date?

    var isEmpty: Bool {
        fiveHourPercent == nil && sevenDayPercent == nil && contextPercent == nil
    }

    /// The cache is fed by Claude Code on every message. If nothing has written
    /// it for a while the numbers are no longer live and must be shown as stale
    /// rather than as a current value.
    static let staleThreshold: TimeInterval = 15 * 60

    func isStale(now: Date = Date()) -> Bool {
        guard let updatedAt else { return true }
        return now.timeIntervalSince(updatedAt) > Self.staleThreshold
    }
}

/// Product-facing connection state of the usage statusLine bridge.
enum UsageStatus: Equatable {
    case notConnected      // bridge not wrapped into statusLine
    case connected         // wrapped and delivering fresh data
    case stale             // wrapped, but the cached numbers have aged out
    case configError       // statusLine config unreadable, or jq missing
    case disconnected      // was connected, now explicitly removed

    var label: String {
        switch self {
        case .notConnected: return "未连接"
        case .connected: return "已连接"
        case .stale: return "数据过期"
        case .configError: return "配置异常"
        case .disconnected: return "已断开"
        }
    }
}

enum UsageStatusPolicy {
    /// Map the raw facts to a single explainable status. A config error (bad
    /// JSON or missing jq) wins so the user fixes the real blocker first.
    static func status(connected: Bool, jqPresent: Bool, configError: Bool,
                       hasData: Bool, isStale: Bool) -> UsageStatus {
        if configError || !jqPresent { return .configError }
        guard connected else { return .notConnected }
        if !hasData { return .connected }   // freshly connected, no message yet
        return isStale ? .stale : .connected
    }
}

@MainActor
final class UsageReader: ObservableObject {
    @Published var snapshot = UsageSnapshot()
    /// Claude Code's AI-generated session titles, keyed by session id.
    @Published var sessionNames: [String: String] = [:]
    private let path = NSString(string: "~/.atoll/cache/usage.json").expandingTildeInPath
    private let namesPath = NSString(string: "~/.atoll/cache/session-names.json").expandingTildeInPath
    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Tuning.usageRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refreshNames() {
        guard let data = FileManager.default.contents(atPath: namesPath),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return }
        sessionNames = obj
    }

    private func refresh() {
        refreshNames()
        if let s = UsageSnapshot.load(path: path) { snapshot = s }
    }
}

extension UsageSnapshot {
    static let defaultPath = NSString(string: "~/.atoll/cache/usage.json").expandingTildeInPath

    /// Parse the cache written by the statusLine bridge. Returns nil when the
    /// file is missing or unreadable — a corrupt cache never crashes the reader.
    static func load(path: String = defaultPath) -> UsageSnapshot? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        func pct(_ key: String) -> Double? {
            (obj[key] as? [String: Any])?["used_percentage"] as? Double
        }
        func reset(_ key: String) -> Date? {
            guard let secs = (obj[key] as? [String: Any])?["resets_at"] as? Double else { return nil }
            return Date(timeIntervalSince1970: secs)
        }
        var s = UsageSnapshot()
        s.fiveHourPercent = pct("five_hour")
        s.sevenDayPercent = pct("seven_day")
        s.fiveHourResetsAt = reset("five_hour")
        s.sevenDayResetsAt = reset("seven_day")
        s.contextPercent = obj["context"] as? Double
        if let at = obj["at"] as? Double { s.updatedAt = Date(timeIntervalSince1970: at) }
        return s
    }
}
