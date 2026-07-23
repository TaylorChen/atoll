import Foundation

/// A named, explainable reason a session is hidden from the panel. Replaces the
/// old opaque `hiddenDirs` / `hiddenPromptPrefixes` / background-signature checks
/// so the user can see *why* a session is filtered and turn any single rule off.
struct FilterRule: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case directory        // matches the session cwd
        case promptPrefix     // matches the first prompt
        case signature        // built-in background-task fingerprint (first prompt)

        var label: String {
            switch self {
            case .directory: return "目录"
            case .promptPrefix: return "首条提示词"
            case .signature: return "后台签名"
            }
        }
    }

    enum Match: String, Codable {
        case prefix           // hay starts with value
        case contains         // hay contains value (case-insensitive)

        var label: String { self == .prefix ? "前缀" : "包含" }
    }

    var id: String
    var name: String
    var kind: Kind
    var match: Match
    var value: String
    var extraValues: [String] = []   // built-ins group several fingerprints under one toggle
    var reason: String
    var enabled: Bool
    var builtin: Bool

    /// Whether this rule hides the given session. An empty rule never matches
    /// (defensive: a blank value must not silently hide everything).
    func matches(_ session: AgentSession) -> Bool {
        guard enabled else { return false }
        let hay = kind == .directory ? session.cwd : session.firstPrompt
        let needles = ([value] + extraValues).filter { !$0.isEmpty }
        guard !needles.isEmpty else { return false }
        switch match {
        case .prefix:   return needles.contains { hay.hasPrefix($0) }
        case .contains: return needles.contains { hay.localizedCaseInsensitiveContains($0) }
        }
    }
}

extension FilterRule {
    /// Built-in background-task rules, each independently toggleable with a stable
    /// id, name and reason. Grouped so the user sees a handful of clear switches
    /// rather than twenty raw signatures.
    static let builtinGroups: [FilterRule] = [
        FilterRule(id: "builtin.memory", name: "记忆写入 / Chronicle", kind: .signature,
                   match: .contains, value: "## Memory Writing Agent",
                   extraValues: ["Memory Writer", "Memory Consolidation", "Codex Chronicle",
                                 "Chronicle Memory Summary", "Claude-Mem", "claude-mem"],
                   reason: "记忆整理类后台会话", enabled: true, builtin: true),
        FilterRule(id: "builtin.review", name: "Guardian / AutoReview", kind: .signature,
                   match: .contains, value: "Guardian",
                   extraValues: ["AutoReview", "Auto Review"],
                   reason: "自动审阅类后台会话", enabled: true, builtin: true),
        FilterRule(id: "builtin.title", name: "会话标题生成", kind: .signature,
                   match: .contains, value: "title generation",
                   extraValues: ["Craft Agent", "Generate a short title"],
                   reason: "标题生成类后台会话", enabled: true, builtin: true),
        FilterRule(id: "builtin.probe", name: "健康探测", kind: .signature,
                   match: .contains, value: "ClaudeProbe",
                   extraValues: ["health check"],
                   reason: "健康检查探测会话", enabled: true, builtin: true),
    ]
}

/// Persisted shape: user rules verbatim + per-built-in enabled overrides. The
/// built-in definitions themselves live in code so upgrades can extend them.
struct FilterRuleState: Codable {
    var userRules: [FilterRule] = []
    var builtinEnabled: [String: Bool] = [:]
}

enum FilterRuleStore {
    static let key = "filterRules.v1"

    struct LoadResult {
        var rules: [FilterRule]
        var warning: String?
    }

    /// Compose the effective rule list (built-ins with overrides applied, then
    /// user rules). Migrates the legacy keys on first run. A corrupt store is
    /// surfaced as a warning and falls back to built-ins only — never silently
    /// to "no rules at all".
    static func load(defaults: UserDefaults = .standard) -> LoadResult {
        if let data = defaults.data(forKey: key) {
            do {
                let state = try JSONDecoder().decode(FilterRuleState.self, from: data)
                return LoadResult(rules: compose(state: state), warning: nil)
            } catch {
                NSLog("FilterRuleStore decode failed: \(error)")
                return LoadResult(rules: compose(state: FilterRuleState()),
                                  warning: "过滤规则存储损坏，已回退为内置规则；自定义规则未生效。")
            }
        }
        // First run (or pre-migration): build from the legacy keys.
        let migrated = migrateLegacy(defaults: defaults)
        save(migrated, defaults: defaults)
        return LoadResult(rules: compose(state: migrated), warning: nil)
    }

    static func save(_ state: FilterRuleState, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: key)
        }
    }

    /// Extract the persistable state back out of an effective rule list.
    static func state(from rules: [FilterRule]) -> FilterRuleState {
        var s = FilterRuleState()
        s.userRules = rules.filter { !$0.builtin }
        for r in rules where r.builtin { s.builtinEnabled[r.id] = r.enabled }
        return s
    }

    private static func compose(state: FilterRuleState) -> [FilterRule] {
        let builtins = builtinGroupsApplying(state.builtinEnabled)
        // Drop duplicate user rules (same kind+match+value).
        var seen = Set<String>()
        let user = state.userRules.filter { r in
            let sig = "\(r.kind.rawValue)|\(r.match.rawValue)|\(r.value)"
            return seen.insert(sig).inserted
        }
        return builtins + user
    }

    private static func builtinGroupsApplying(_ overrides: [String: Bool]) -> [FilterRule] {
        FilterRule.builtinGroups.map { rule in
            var r = rule
            if let on = overrides[rule.id] { r.enabled = on }
            return r
        }
    }

    private static func migrateLegacy(defaults: UserDefaults) -> FilterRuleState {
        var state = FilterRuleState()
        let dirs = defaults.stringArray(forKey: "hiddenDirs") ?? []
        let prefixes = defaults.stringArray(forKey: "hiddenPromptPrefixes") ?? []
        for d in dirs where !d.isEmpty {
            state.userRules.append(FilterRule(
                id: "user.dir.\(UUID().uuidString)", name: (d as NSString).lastPathComponent,
                kind: .directory, match: .prefix, value: d,
                reason: "从旧「隐藏目录」迁移", enabled: true, builtin: false))
        }
        for p in prefixes where !p.isEmpty {
            state.userRules.append(FilterRule(
                id: "user.prompt.\(UUID().uuidString)", name: String(p.prefix(20)),
                kind: .promptPrefix, match: .prefix, value: p,
                reason: "从旧「隐藏提示词」迁移", enabled: true, builtin: false))
        }
        // Legacy master switch for background tasks (default on).
        let bgOn = defaults.object(forKey: "filterBackgroundTasks") as? Bool ?? true
        if !bgOn {
            for b in FilterRule.builtinGroups { state.builtinEnabled[b.id] = false }
        }
        return state
    }
}
