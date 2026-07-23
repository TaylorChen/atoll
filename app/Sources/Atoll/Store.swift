import Foundation
import Combine

// MARK: - Models

enum SessionState: String, Codable {
    case thinking          // 思考中（收到 prompt / stop 之间无工具活动）
    case runningTool       // 执行工具
    case compacting        // 压缩上下文
    case waitingApproval   // 等待审批（P2）
    case waitingAnswer     // 等待回答（P2）
    case done              // 本轮完成
    case ended             // 会话结束
    case needsAttention    // 需要注意（工具连续失败）

    var label: String {
        switch self {
        case .thinking: return "思考中"
        case .runningTool: return "执行工具"
        case .compacting: return "压缩中"
        case .waitingApproval: return "等待审批"
        case .waitingAnswer: return "等待回答"
        case .done: return "完成"
        case .ended: return "已结束"
        case .needsAttention: return "需要注意"
        }
    }
}

struct ToolEvent: Codable, Identifiable {
    let id: UUID
    let time: Date
    let verb: String      // 读取中 / 编辑中 / 运行中…
    let toolName: String
    let detail: String    // file path / command 摘要
    var result: String = ""   // "3 passed" / "1.2 KB" — from tool_response
    var failed: Bool = false
}

struct AgentSession: Codable, Identifiable {
    let id: String            // sessionKey
    let source: String        // claude / codex / gemini
    var cwd: String
    var tty: String
    var state: SessionState
    var firstPrompt: String = ""
    var lastPrompt: String = ""   // latest user turn, kept separate from the stable session title
    var model: String = ""
    var startedAt: Date
    var lastActivity: Date
    var currentTool: String = ""
    var lastReply: String = ""   // last assistant message, read from transcript on Stop
    var transcriptPath: String = ""
    var toolLog: [ToolEvent] = []
    var subagentsRunning: Int = 0
    var subagentsDone: Int = 0
    var firedAllFinished: Bool = false   // guards the once-only "all subagents done" notice
    var consecutiveFailures: Int = 0
    var tasksDone: Int = 0
    var tasksInProgress: Int = 0
    var tasksPending: Int = 0

    var aiTitle: String = ""   // Claude Code's AI-generated session name
    var observedInCodexDesktop: Bool = false   // same Codex thread also seen through app-server
    var remoteHost: String = ""   // non-empty when the session runs on a remote host

    var projectName: String {
        (cwd as NSString).lastPathComponent
    }

    /// Best available label: AI title > first prompt > project name.
    var displayTitle: String {
        if !aiTitle.isEmpty { return aiTitle }
        if !firstPrompt.isEmpty { return firstPrompt }
        return projectName
    }

    var hasTasks: Bool { tasksDone + tasksInProgress + tasksPending > 0 }

    /// Git worktree/branch dir shown when cwd sits under a `.worktrees`/`worktree` path.
    var worktreeName: String? {
        let parts = (cwd as NSString).pathComponents
        if let idx = parts.lastIndex(where: { $0 == "worktrees" || $0 == ".worktrees" || $0 == "wt" }),
           idx + 1 < parts.count {
            return parts[idx + 1]
        }
        return nil
    }
}

// MARK: - Store

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [String: AgentSession] = [:]
    @Published private(set) var pending: [PendingRequest] = []
    @Published var warning: String = ""
    @Published var notchExpanded: Bool = false
    @Published var notchHovering: Bool = false
    /// The session highlighted by the keyboard switcher (⌥⇧J/K), if any.
    @Published var selectedSessionID: String?

    /// Called with (pendingID, responseBody) when the user decides; wired to the gateway.
    var resolver: ((String, Data) -> Void)?

    private var snapshotSaver: AnyCancellable?
    private let snapshotDirectory: URL

    /// `snapshotDirectory` is injectable so tests stay hermetic; production uses
    /// the default `~/.atoll`.
    init(snapshotDirectory: URL = SessionSnapshot.defaultDirectory) {
        self.snapshotDirectory = snapshotDirectory
        loadFilterRules()
        // Restore the display snapshot so a restart shows recent cards before any
        // new event arrives. Pending/bypass/always-allow are intentionally NOT
        // restored — only presentation data.
        let restored = SessionSnapshot.load(from: snapshotDirectory)
        for s in restored.sessions { sessions[s.id] = s }
        if let w = restored.warning { warning = w; DiagnosticsLog.record("snapshot", w) }
        // Persist display state on change, debounced so bursts of tool events
        // don't thrash the disk.
        snapshotSaver = $sessions
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [snapshotDirectory] snapshot in
                SessionSnapshot.save(Array(snapshot.values), to: snapshotDirectory)
            }
    }

    /// "始终允许" rules, kept app-side because the CLI ignores hook-supplied
    /// updatedPermissions (verified): sessionKey → rule keys like "Bash:echo".
    private var autoAllowRules: [String: Set<String>] = [:]
    /// Sessions the user put in "自动批准" mode: every incoming permission
    /// request for the session is allowed without a card, until toggled off.
    /// Session-scoped and in-memory only (never persisted).
    @Published private(set) var bypassSessions: Set<String> = []
    /// Removed presentation records retained only to distinguish Codex polling
    /// snapshots from real activity. They are never persisted or exposed.
    private var dismissedSessions: [String: AgentSession] = [:]

    private func ruleKey(_ p: PendingRequest) -> String {
        if p.toolName == "Bash", let word = p.bashCommand.split(separator: " ").first {
            return "Bash:\(word)"
        }
        return p.toolName
    }

    func autoAllows(_ p: PendingRequest) -> Bool {
        guard p.kind == .approval else { return false }
        if bypassSessions.contains(p.sessionKey) { return true }
        return autoAllowRules[p.sessionKey]?.contains(ruleKey(p)) ?? false
    }

    func isBypassed(_ sessionKey: String) -> Bool { bypassSessions.contains(sessionKey) }

    /// Toggle "自动批准" for a session. Turning it on also clears any pending
    /// approval cards for that session (they're implicitly allowed now).
    func setBypass(_ sessionKey: String, _ on: Bool) {
        if on {
            bypassSessions.insert(sessionKey)
            for req in pending where req.sessionKey == sessionKey && req.kind == .approval {
                decide(req.id, .allow)
            }
        } else {
            bypassSessions.remove(sessionKey)
        }
    }

    /// Resolve every pending *approval* at once (VI's 全部允许/全部拒绝).
    /// Questions and plans are left untouched — they need explicit answers.
    func resolveAllApprovals(allow: Bool) {
        for id in pending.filter({ $0.kind == .approval }).map(\.id) {
            decide(id, allow ? .allow : .deny(reason: "用户在 Atoll 批量拒绝"))
        }
    }

    var pendingApprovalCount: Int { pending.filter { $0.kind == .approval }.count }

    /// Named, explainable filter rules (built-ins + user rules). The effective
    /// list; persistence and legacy migration live in `FilterRuleStore`.
    @Published private(set) var filterRules: [FilterRule] = []

    private func loadFilterRules() {
        let result = FilterRuleStore.load()
        filterRules = result.rules
        if let w = result.warning { warning = w; DiagnosticsLog.record("filter", w) }
    }

    private func persistFilterRules() {
        FilterRuleStore.save(FilterRuleStore.state(from: filterRules))
    }

    /// The first rule hiding this session, if any — powers the "why is this
    /// hidden" explanation in Settings.
    func firstMatchingRule(_ session: AgentSession) -> FilterRule? {
        filterRules.first { $0.matches(session) }
    }

    /// Sessions currently hidden by a rule, paired with the rule that hid them.
    var hiddenSessionsWithRule: [(session: AgentSession, rule: FilterRule)] {
        sessions.values.compactMap { s in
            firstMatchingRule(s).map { (s, $0) }
        }.sorted { $0.session.lastActivity > $1.session.lastActivity }
    }

    /// Live hit count for a rule against the current sessions — shown before the
    /// user commits a change so they can see what a rule affects.
    func hitCount(for rule: FilterRule) -> Int {
        sessions.values.filter { rule.matches($0) }.count
    }

    func setRuleEnabled(_ id: String, _ enabled: Bool) {
        guard let i = filterRules.firstIndex(where: { $0.id == id }) else { return }
        filterRules[i].enabled = enabled
        persistFilterRules()
    }

    func addRule(_ rule: FilterRule) {
        // Skip an exact duplicate (same kind+match+value) to keep the list clean.
        let dup = filterRules.contains {
            $0.kind == rule.kind && $0.match == rule.match && $0.value == rule.value
        }
        guard !dup, !rule.value.isEmpty else { return }
        filterRules.append(rule)
        persistFilterRules()
    }

    func removeRule(_ id: String) {
        filterRules.removeAll { $0.id == id && !$0.builtin }
        persistFilterRules()
    }

    /// Master toggle kept for the menu-bar item: reads/sets all built-in rules.
    var filterBackgroundTasks: Bool {
        get { filterRules.contains { $0.builtin && $0.enabled } }
        set {
            for i in filterRules.indices where filterRules[i].builtin {
                filterRules[i].enabled = newValue
            }
            persistFilterRules()
        }
    }

    func hideDir(_ cwd: String) {
        guard !cwd.isEmpty else { return }
        addRule(FilterRule(id: "user.dir.\(UUID().uuidString)",
                           name: (cwd as NSString).lastPathComponent,
                           kind: .directory, match: .prefix, value: cwd,
                           reason: "用户隐藏此目录", enabled: true, builtin: false))
    }

    func hidePromptPrefix(_ prompt: String) {
        let prefix = String(prompt.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return }
        addRule(FilterRule(id: "user.prompt.\(UUID().uuidString)",
                           name: String(prefix.prefix(20)),
                           kind: .promptPrefix, match: .prefix, value: prefix,
                           reason: "用户隐藏此提示词开头的会话", enabled: true, builtin: false))
    }

    func resetHiddenDirs() {
        filterRules.removeAll { !$0.builtin }
        persistFilterRules()
    }

    /// Sources we've EVER received an event from — persisted, so a trust-gated
    /// desktop CLI that authorized once stays "已激活" across app restarts.
    @Published private(set) var seenSources: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "seenSources") ?? [])

    func noteSourceSeen(_ source: String) {
        if !seenSources.contains(source) {
            seenSources.insert(source)
            UserDefaults.standard.set(Array(seenSources), forKey: "seenSources")
        }
    }

    // MARK: - Codex Desktop (app-server JSON-RPC channel, no hooks)

    func upsertCodexDesktopSession(id: String, cwd: String, title: String,
                                   reviveDismissed: Bool = false) {
        let key = id
        if dismissedSessions[key] != nil, !reviveDismissed { return }
        var s = sessions[key] ?? dismissedSessions.removeValue(forKey: key)
            ?? AgentSession(id: key, source: "codex", cwd: cwd, tty: "",
                            state: .thinking, startedAt: Date(), lastActivity: Date())
        s.lastActivity = Date()
        if !cwd.isEmpty { s.cwd = cwd }
        if !title.isEmpty { s.aiTitle = title }
        s.observedInCodexDesktop = true
        sessions[key] = s
        noteSourceSeen("codex")
    }

    func setCodexDesktopState(id: String, _ state: SessionState,
                              reviveDismissed: Bool = false) {
        let key = id
        if dismissedSessions[key] != nil, !reviveDismissed { return }
        guard var s = sessions[key] ?? dismissedSessions.removeValue(forKey: key) else { return }
        if s.state == .done && state == .done { return }
        if state == .done && s.state != .done {
            AtollNotifier.shared.notify(.completion, source: s.source,
                                        project: s.projectName, detail: s.firstPrompt)
        }
        s.state = state
        s.lastActivity = Date()
        sessions[key] = s
    }

    func updateCodexDesktopTitle(id: String, title: String) {
        let key = id
        guard var s = sessions[key], !title.isEmpty else { return }
        s.aiTitle = title
        sessions[key] = s
    }

    /// Merge AI-generated session titles (from the statusLine bridge) into sessions.
    func applyTitles(_ names: [String: String]) {
        for (id, name) in names where sessions[id] != nil && sessions[id]?.aiTitle != name {
            sessions[id]?.aiTitle = name
        }
    }

    var sorted: [AgentSession] {
        sessions.values
            .filter { s in !filterRules.contains { $0.matches(s) } }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Completed sessions that can be safely removed from the local panel.
    /// A pending interaction always wins over cleanup, even if the session state
    /// is stale, so the user never loses the only visible approval surface.
    var removableCompletedSessionCount: Int {
        sorted.filter { session in
            (session.state == .done || session.state == .ended)
                && !hasPendingInteraction(sessionID: session.id)
        }.count
    }

    func hasPendingInteraction(sessionID: String) -> Bool {
        pending.contains { $0.sessionKey == sessionID }
    }

    /// A visible session needs attention (repeated tool failures). Drives the
    /// always-on attention dot — never gated by quiet hours or muted sound, so a
    /// failure that happened silently still leaves a trace on the collapsed pill.
    var hasAttentionState: Bool {
        sorted.contains { $0.state == .needsAttention }
    }

    /// A visible session is doing or awaiting something — anything but done/ended.
    /// Drives idle auto-hide (which only hides display, never removes a session).
    var hasLiveSession: Bool {
        sorted.contains { $0.state != .done && $0.state != .ended }
    }

    /// True while the panel is open because the user explicitly opened it
    /// (hotkey/menu), so a completion reminder timing out won't close it.
    var notchUserOpened = false

    /// Remove only Atoll's in-memory presentation. This does not terminate or
    /// mutate the underlying agent task. An active session naturally reappears
    /// when its next event arrives through `apply`/the Codex app-server channel.
    @discardableResult
    func removeSession(id: String) -> Bool {
        guard !hasPendingInteraction(sessionID: id), let removed = sessions.removeValue(forKey: id) else {
            return false
        }
        dismissedSessions[id] = removed
        autoAllowRules.removeValue(forKey: id)
        bypassSessions.remove(id)
        return true
    }

    /// Bulk hygiene mirrors the panel action: remove finished presentation
    /// records, preserve active work, and never orphan a pending interaction.
    @discardableResult
    func removeCompletedSessions() -> Int {
        let ids = sorted.compactMap { session -> String? in
            guard session.state == .done || session.state == .ended,
                  !hasPendingInteraction(sessionID: session.id) else { return nil }
            return session.id
        }
        for id in ids {
            if let removed = sessions.removeValue(forKey: id) {
                dismissedSessions[id] = removed
            }
            autoAllowRules.removeValue(forKey: id)
        }
        return ids.count
    }

    func addPending(_ req: PendingRequest) {
        pending.append(req)
        let session = sessions[req.sessionKey]
        AtollNotifier.shared.notify(req.kind == .question ? .question : .approval,
                                    source: req.source,
                                    project: session?.projectName ?? req.source,
                                    detail: req.toolName)
        if var s = sessions[req.sessionKey] {
            s.state = (req.kind == .question) ? .waitingAnswer : .waitingApproval
            s.lastActivity = Date()
            sessions[req.sessionKey] = s
        }
    }

    /// Remove a pending card whose connection died (CLI interrupted / hook timeout).
    func dropPending(id: String) {
        pending.removeAll { $0.id == id }
    }

    /// Completion pop: expand the panel for a short dwell, then collapse
    /// unless the user hovered in or an approval arrived meanwhile. Whether to
    /// pop at all is already decided upstream (NoticeDecision.autoExpand, which
    /// accounts for quiet hours and the expand-on-complete setting).
    private func popForCompletion() {
        notchExpanded = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Settings.shared.completionDwell) { [weak self] in
            guard let self else { return }
            if PanelDismissPolicy.shouldCollapse(trigger: .reminderTimeout,
                                                 pendingPresent: !self.pending.isEmpty,
                                                 userOpened: self.notchUserOpened,
                                                 hovering: self.notchHovering) {
                self.notchExpanded = false
            }
        }
    }

    /// Drop long-ended sessions so the panel stays tidy.
    func cleanupIdle() {
        let now = Date()
        let idle = Settings.shared.idleCleanupHours * 3600
        sessions = sessions.filter { _, s in
            switch s.state {
            case .ended: return now.timeIntervalSince(s.lastActivity) < min(1800, idle)
            default: return now.timeIntervalSince(s.lastActivity) < idle
            }
        }
    }

    func decide(_ id: String, _ decision: Decision) {
        guard let req = pending.first(where: { $0.id == id }) else { return }
        if case .alwaysAllow = decision {
            autoAllowRules[req.sessionKey, default: []].insert(ruleKey(req))
        }
        resolver?(id, HookDecisionCodec.encode(decision, for: req))
        pending.removeAll { $0.id == id }
        if var s = sessions[req.sessionKey] {
            s.state = .thinking
            s.lastActivity = Date()
            sessions[req.sessionKey] = s
        }
    }

    func apply(_ event: NormalizedEvent) {
        clearPendingResolvedOutsideAtoll(by: event)
        dismissedSessions.removeValue(forKey: event.sessionKey)
        var s = sessions[event.sessionKey] ?? AgentSession(
            id: event.sessionKey,
            source: event.source,
            cwd: event.cwd,
            tty: event.tty,
            state: .thinking,
            startedAt: Date(),
            lastActivity: Date()
        )
        s.lastActivity = Date()
        if !event.cwd.isEmpty { s.cwd = event.cwd }
        if !event.tty.isEmpty { s.tty = event.tty }
        if !event.model.isEmpty { s.model = event.model }
        if !event.transcriptPath.isEmpty {
            s.transcriptPath = event.transcriptPath
            if s.lastPrompt.isEmpty || s.lastReply.isEmpty {
                let messages = Normalizer.recentMessages(transcriptPath: event.transcriptPath, limit: 40)
                if s.lastPrompt.isEmpty,
                   let prompt = messages.last(where: { $0.role == "user" })?.text {
                    s.lastPrompt = prompt
                }
                if s.lastReply.isEmpty,
                   let reply = messages.last(where: { $0.role == "assistant" })?.text {
                    s.lastReply = reply
                }
            }
        }
        if !event.host.isEmpty { s.remoteHost = event.host }

        switch event.kind {
        case .sessionStart:
            s.state = .thinking
        case .prompt:
            if s.firstPrompt.isEmpty { s.firstPrompt = event.detail }
            if !event.detail.isEmpty { s.lastPrompt = event.detail }
            if s.state == .done || s.state == .ended { s.toolLog.removeAll() }
            s.state = .thinking
            s.currentTool = ""
        case .toolUse:
            s.state = .runningTool
            s.currentTool = "\(event.verb) \(event.detail)"
            s.toolLog.append(ToolEvent(id: UUID(), time: Date(), verb: event.verb, toolName: event.toolName, detail: event.detail))
            if s.toolLog.count > 50 { s.toolLog.removeFirst(s.toolLog.count - 50) }
            if let t = event.todos {
                s.tasksDone = t.done; s.tasksInProgress = t.inProgress; s.tasksPending = t.pending
            }
        case .toolResult:
            s.state = .thinking
            s.currentTool = ""
            s.consecutiveFailures = 0
            // Attach the result summary to the matching in-flight tool entry.
            if !event.detail.isEmpty,
               let idx = s.toolLog.lastIndex(where: { $0.result.isEmpty && !$0.failed
                   && (event.toolName.isEmpty || $0.toolName == event.toolName) }) {
                s.toolLog[idx].result = event.detail
            }
        case .toolFailure:
            s.state = .thinking
            s.currentTool = ""
            s.consecutiveFailures += 1
            if var last = s.toolLog.last {
                last.failed = true
                s.toolLog[s.toolLog.count - 1] = last
            }
            if s.consecutiveFailures >= 3 {
                if s.state != .needsAttention {
                    AtollNotifier.shared.notify(.failure, source: s.source,
                                                project: s.projectName, detail: event.toolName)
                }
                s.state = .needsAttention
            }
        case .compactStart:
            s.state = .compacting
        case .stop:
            let decision = AtollNotifier.shared.notify(.completion, source: s.source,
                                                       project: s.projectName, detail: event.detail)
            let shouldPop = s.state != .done
                && decision.autoExpand
                && !(Settings.shared.suppressCompletionPopupWhenAgentFrontmost
                     && AtollNotifier.shared.sourceIsFrontmost(s.source))
            s.state = .done
            s.currentTool = ""
            if !event.detail.isEmpty { s.lastReply = event.detail }
            // Signature notch behaviour: agent finished → pop open briefly.
            if shouldPop { popForCompletion() }
        case .stopFailure:
            AtollNotifier.shared.notify(.failure, source: s.source,
                                        project: s.projectName, detail: event.detail)
            s.state = .needsAttention
        case .subagentStart:
            s.subagentsRunning += 1
            s.firedAllFinished = false   // a new fan-out re-arms the all-finished notice
        case .subagentStop:
            s.subagentsRunning = max(0, s.subagentsRunning - 1)
            s.subagentsDone += 1
            let decision = ChildNotifyPolicy.onSubagentStop(
                timing: Settings.shared.childNotifyTiming,
                runningAfter: s.subagentsRunning,
                alreadyFiredAllFinished: s.firedAllFinished)
            s.firedAllFinished = decision.firedAllFinished
            if decision.notify {
                AtollNotifier.shared.notify(.subagentCompletion, source: s.source,
                                            project: s.projectName,
                                            detail: "已完成 \(s.subagentsDone) 个子 Agent")
            }
        case .sessionEnd:
            s.state = .ended
            s.currentTool = ""
        case .other:
            break
        }
        sessions[event.sessionKey] = s
    }

    /// Reconcile cards when the same request was completed in the agent/terminal.
    /// A matching tool event proves that specific request advanced; a terminal
    /// turn ending proves every interactive request for the session is obsolete.
    private func clearPendingResolvedOutsideAtoll(by event: NormalizedEvent) {
        let resolved = pending.filter { req in
            guard req.sessionKey == event.sessionKey else { return false }
            switch event.kind {
            case .toolUse:
                // PermissionRequest precedes PreToolUse. Questions use a parallel
                // PreToolUse hook, so clearing those here would hide a live card.
                guard req.kind == .approval else { return false }
                if !req.toolUseID.isEmpty, !event.toolUseID.isEmpty {
                    return req.toolUseID == event.toolUseID
                }
                return req.toolName == event.toolName
            case .toolResult, .toolFailure:
                if !req.toolUseID.isEmpty, !event.toolUseID.isEmpty {
                    return req.toolUseID == event.toolUseID
                }
                return !event.toolName.isEmpty && req.toolName == event.toolName
            case .stop, .stopFailure, .sessionEnd:
                return true
            default:
                return false
            }
        }
        guard !resolved.isEmpty else { return }

        let ids = Set(resolved.map(\.id))
        for req in resolved {
            resolver?(req.id, Data())   // empty response = Atoll made no decision
        }
        pending.removeAll { ids.contains($0.id) }
    }

    func debugJSON() -> Data {
        struct Dump: Codable {
            let sessions: [AgentSession]
            let pending: [PendingRequest]
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(Dump(sessions: sorted, pending: pending))) ?? Data("{}".utf8)
    }
}

// MARK: - Normalization

enum EventKind {
    case sessionStart, prompt, toolUse, toolResult, toolFailure
    case compactStart, stop, stopFailure, subagentStart, subagentStop, sessionEnd, other
}

struct NormalizedEvent {
    var source: String
    let sessionKey: String
    let kind: EventKind
    let cwd: String
    let tty: String
    var model: String = ""
    var toolName: String = ""
    var verb: String = ""
    var detail: String = ""
    var transcriptPath: String = ""
    var todos: (done: Int, inProgress: Int, pending: Int)?
    var host: String = ""
    var toolUseID: String = ""
}

enum Normalizer {
    static func normalize(source: String, form: [String: String]) -> NormalizedEvent? {
        var event: NormalizedEvent?
        switch source {
        case "claude": event = claude(form: form)
        case "codex", "qoder", "qwen", "factory", "codebuddy", "kimi":
            event = claudeClone(source: source, form: form)
        case "gemini": event = gemini(form: form)
        case "cursor": event = cursor(form: form)
        case "opencode": event = claudeClone(source: source, form: form)
        default:
            logUnparsed(source: source, form: form)
            return nil
        }
        event?.host = form["host"] ?? ""   // set by the SSH remote bridge
        return event
    }

    /// Claude-compatible agents reuse the parser but retain their source ID.
    static func claudeClone(source: String, form: [String: String]) -> NormalizedEvent? {
        guard var ev = claude(form: form) else {
            logUnparsed(source: source, form: form)
            return nil
        }
        ev.source = source
        return ev
    }

    /// Cursor Agent: flat camelCase hooks with a Cursor-specific payload.
    /// Defensive parsing — unknown shapes are logged for later refinement.
    static func cursor(form: [String: String]) -> NormalizedEvent? {
        guard let payloadStr = form["payload"],
              let data = payloadStr.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { logUnparsed(source: "cursor", form: form); return nil }

        let eventName = (payload["hook_event_name"] as? String) ?? (payload["event"] as? String) ?? ""
        let sessionKey = (payload["conversation_id"] as? String)
            ?? (payload["generation_id"] as? String)
            ?? (payload["session_id"] as? String) ?? ""
        guard !sessionKey.isEmpty else { logUnparsed(source: "cursor", form: form); return nil }
        let roots = payload["workspace_roots"] as? [String]
        let cwd = roots?.first ?? (payload["cwd"] as? String) ?? form["cwd"] ?? ""
        let tty = form["tty"] ?? ""

        func short(_ s: String?, _ n: Int = 80) -> String {
            guard let s else { return "" }
            let home = NSHomeDirectory()
            let v = s.hasPrefix(home) ? "~" + s.dropFirst(home.count) : s
            return String(v.prefix(n))
        }

        var kind: EventKind = .other
        var verb = "", detail = "", toolName = ""
        switch eventName {
        case "beforeSubmitPrompt":
            kind = .prompt; detail = String((payload["prompt"] as? String ?? "").prefix(120))
        case "preToolUse", "beforeShellExecution":
            kind = .toolUse; toolName = payload["tool_name"] as? String ?? "Shell"
            verb = "运行中"; detail = short(payload["command"] as? String ?? (payload["tool_input"] as? [String: Any])?["command"] as? String)
        case "beforeReadFile":
            kind = .toolUse; toolName = "Read"; verb = "读取中"; detail = short(payload["file_path"] as? String)
        case "afterFileEdit":
            kind = .toolResult; toolName = "Edit"; detail = short(payload["file_path"] as? String)
        case "afterShellExecution":
            kind = .toolResult; toolName = "Shell"
        case "postToolUse", "afterMCPExecution":
            kind = .toolResult
        case "postToolUseFailure":
            kind = .toolFailure
        case "stop", "afterAgentResponse":
            kind = .stop
        case "subagentStart": kind = .subagentStart
        case "subagentStop": kind = .subagentStop
        default:
            logUnparsed(source: "cursor", form: form)
        }
        return NormalizedEvent(source: "cursor", sessionKey: sessionKey, kind: kind,
                               cwd: cwd, tty: tty, toolName: toolName, verb: verb, detail: detail)
    }

    /// Gemini CLI: minimal monitoring via BeforeAgent/AfterAgent.
    static func gemini(form: [String: String]) -> NormalizedEvent? {
        guard let payloadStr = form["payload"],
              let data = payloadStr.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            logUnparsed(source: "gemini", form: form)
            return nil
        }
        let cwd = payload["cwd"] as? String ?? form["cwd"] ?? ""
        let tty = form["tty"] ?? ""
        // Gemini payloads may lack a session id; derive a stable key.
        let sessionKey = (payload["session_id"] as? String)
            ?? "gemini-\(cwd)-\(tty)".hashValue.description
        let eventName = (payload["hook_event_name"] as? String)
            ?? (payload["event"] as? String) ?? ""
        var kind: EventKind = .other
        var detail = ""
        switch eventName {
        case "BeforeAgent":
            kind = .prompt
            detail = String(((payload["prompt"] as? String) ?? "").prefix(120))
        case "AfterAgent":
            kind = .stop
        default:
            logUnparsed(source: "gemini", form: form)
        }
        return NormalizedEvent(source: "gemini", sessionKey: sessionKey, kind: kind,
                               cwd: cwd, tty: tty, detail: detail)
    }

    /// Opt-in schema-drift safety net: capture unparsed payloads for adapter
    /// refinement. Off by default — enable with `defaults write Atoll debugUnparsed
    /// -bool true`. Payloads may contain prompt text, so this is user-gated and
    /// truncated, written 0600, and stays local.
    private static func logUnparsed(source: String, form: [String: String]) {
        guard UserDefaults.standard.bool(forKey: "debugUnparsed") else { return }
        let path = NSString(string: "~/.atoll/debug-unparsed.log").expandingTildeInPath
        let payload = String((form["payload"] ?? "").prefix(500))
        let line = "[\(Date())] source=\(source) payload=\(payload)\n"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(Data(line.utf8))
            try? fh.close()
        }
    }

    /// Claude Code hook payload → NormalizedEvent.
    /// Unknown event names map to .other so schema drift never crashes the pipeline.
    static func claude(form: [String: String]) -> NormalizedEvent? {
        guard let payloadStr = form["payload"],
              let payloadData = payloadStr.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any]
        else { return nil }

        let eventName = payload["hook_event_name"] as? String ?? ""
        let sessionID = payload["session_id"] as? String ?? ""
        guard !sessionID.isEmpty else { return nil }
        let cwd = payload["cwd"] as? String ?? form["cwd"] ?? ""
        let tty = form["tty"] ?? ""
        let model = ((payload["model"] as? [String: Any])?["display_name"] as? String) ?? ""
        let transcriptPath = payload["transcript_path"] as? String ?? ""
        let toolUseID = payload["tool_use_id"] as? String ?? ""

        var kind: EventKind = .other
        var toolName = ""
        var verb = ""
        var detail = ""
        var todos: (done: Int, inProgress: Int, pending: Int)?

        switch eventName {
        case "SessionStart": kind = .sessionStart
        case "UserPromptSubmit":
            kind = .prompt
            detail = String((payload["prompt"] as? String ?? "").prefix(120))
        case "PreToolUse":
            kind = .toolUse
            toolName = payload["tool_name"] as? String ?? "?"
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            (verb, detail) = describeTool(toolName, input: input)
            if toolName == "TodoWrite", let items = input["todos"] as? [[String: Any]] {
                var d = 0, ip = 0, p = 0
                for item in items {
                    switch item["status"] as? String {
                    case "completed": d += 1
                    case "in_progress": ip += 1
                    default: p += 1
                    }
                }
                todos = (d, ip, p)
            }
        case "PostToolUse":
            kind = .toolResult
            toolName = payload["tool_name"] as? String ?? ""
            detail = summarizeResult(toolName, payload["tool_response"])
        case "PostToolUseFailure": kind = .toolFailure
        case "PreCompact": kind = .compactStart
        case "Stop":
            kind = .stop
            if let path = payload["transcript_path"] as? String {
                detail = lastAssistantMessage(transcriptPath: path)
            }
        case "StopFailure": kind = .stopFailure
        case "SubagentStart": kind = .subagentStart
        case "SubagentStop": kind = .subagentStop
        case "SessionEnd": kind = .sessionEnd
        default: kind = .other
        }

        return NormalizedEvent(source: "claude", sessionKey: sessionID, kind: kind,
                               cwd: cwd, tty: tty, model: model,
                               toolName: toolName, verb: verb, detail: detail,
                               transcriptPath: transcriptPath, todos: todos,
                               toolUseID: toolUseID)
    }

    /// Recent conversation excerpt from a transcript.
    static func recentMessages(transcriptPath: String, limit: Int = 6) -> [(role: String, text: String)] {
        guard let fh = FileHandle(forReadingAtPath: transcriptPath) else { return [] }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let maxTailBytes: UInt64 = 4 * 1_024 * 1_024
        let readFrom = size > maxTailBytes ? size - maxTailBytes : 0
        try? fh.seek(toOffset: readFrom)
        guard let data = try? fh.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [(String, String)] = []
        for line in text.components(separatedBy: "\n").reversed() {
            guard out.count < limit,
                  let d = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            else { continue }
            let role: String
            let msg: [String: Any]
            if let type = obj["type"] as? String,
               type == "assistant" || type == "user",
               let message = obj["message"] as? [String: Any] {
                role = type
                msg = message
            } else if obj["type"] as? String == "response_item",
                      let payload = obj["payload"] as? [String: Any],
                      payload["type"] as? String == "message",
                      let payloadRole = payload["role"] as? String,
                      payloadRole == "assistant" || payloadRole == "user" {
                role = payloadRole
                msg = payload
            } else {
                continue
            }
            var textParts: [String] = []
            if let content = msg["content"] as? [[String: Any]] {
                for block in content where ["text", "input_text", "output_text"]
                    .contains(block["type"] as? String ?? "") {
                    if let t = block["text"] as? String { textParts.append(t) }
                }
            } else if let s = msg["content"] as? String {
                textParts.append(s)
            }
            let joined = textParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joined.isEmpty, !joined.hasPrefix("<") else { continue }  // skip tool/system noise
            out.append((role, String(joined.prefix(220))))
        }
        return out.reversed()
    }

    /// Compact tool result summary ("└ 3 passed", "1.2 KB").
    private static func summarizeResult(_ tool: String, _ response: Any?) -> String {
        func kb(_ n: Int) -> String {
            n < 1024 ? "\(n) B" : String(format: "%.1f KB", Double(n) / 1024)
        }
        if let s = response as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "" }
            let lines = trimmed.components(separatedBy: "\n")
            return lines.count > 1 ? "\(kb(trimmed.count)) · \(lines.count) 行" : String(trimmed.prefix(60))
        }
        guard let dict = response as? [String: Any] else { return "" }
        if let stdout = dict["stdout"] as? String {
            let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if let first = out.components(separatedBy: "\n").last, !first.isEmpty {
                return String(first.prefix(60))
            }
            return (dict["stderr"] as? String)?.isEmpty == false ? "stderr 有输出" : "无输出"
        }
        if let file = dict["file"] as? [String: Any], let content = file["content"] as? String {
            return "\(kb(content.count)) · \(content.components(separatedBy: "\n").count) 行"
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            return kb(data.count)
        }
        return ""
    }

    /// Tail-read the session transcript for the last assistant text message.
    private static func lastAssistantMessage(transcriptPath: String) -> String {
        guard let fh = FileHandle(forReadingAtPath: transcriptPath) else { return "" }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let readFrom = size > 131_072 ? size - 131_072 : 0
        try? fh.seek(toOffset: readFrom)
        guard let data = try? fh.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return "" }
        for line in text.components(separatedBy: "\n").reversed() {
            guard let d = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { continue }
            for block in content where block["type"] as? String == "text" {
                if let t = block["text"] as? String, !t.isEmpty {
                    return String(t.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
                }
            }
        }
        return ""
    }

    private static func describeTool(_ name: String, input: [String: Any]) -> (String, String) {
        func short(_ s: String?) -> String {
            guard let s, !s.isEmpty else { return "" }
            let home = NSHomeDirectory()
            let abbreviated = s.hasPrefix(home) ? "~" + s.dropFirst(home.count) : s
            return String(abbreviated.prefix(80))
        }
        switch name {
        case "Read": return ("读取中", short(input["file_path"] as? String))
        case "Edit", "NotebookEdit": return ("编辑中", short(input["file_path"] as? String))
        case "Write": return ("写入中", short(input["file_path"] as? String))
        case "Bash": return ("运行中", short(input["command"] as? String))
        case "Grep", "Glob": return ("搜索中", short((input["pattern"] as? String) ?? (input["query"] as? String)))
        case "WebFetch", "WebSearch": return ("获取中", short((input["url"] as? String) ?? (input["query"] as? String)))
        case "Task", "Agent": return ("任务中", short(input["description"] as? String))
        case "Skill": return ("运行技能", short(input["skill"] as? String))
        default: return ("工作中", short(nil))
        }
    }
}
