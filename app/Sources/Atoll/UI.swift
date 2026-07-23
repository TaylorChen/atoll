import SwiftUI

/// Reports the natural height of the panel content so the window can size to
/// fit (and only scroll past a maximum).
struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct SessionListView: View {
    @ObservedObject var store: SessionStore
    var maxHeight: CGFloat = 480
    var onHeight: (CGFloat) -> Void = { _ in }
    @State private var showAll = false
    @State private var natural: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if store.pendingApprovalCount >= 2 {
                    HStack(spacing: 8) {
                        Text("🔔 \(store.pendingApprovalCount) 个待审批")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button("全部拒绝") { store.resolveAllApprovals(allow: false) }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.red)
                        Button("全部允许") { store.resolveAllApprovals(allow: true) }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 4)
                }
                ForEach(store.pending) { req in
                    PendingCard(store: store, req: req)
                }
                if store.sorted.isEmpty && store.pending.isEmpty {
                    VStack(spacing: 4) {
                        Text("环礁等待中").font(.headline).foregroundStyle(Theme.textPrimary)
                        Text("重启终端或开启一个新会话").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
                }
                Ticker {
                    let visible = showAll ? store.sorted : Array(store.sorted.prefix(3))
                    ForEach(visible) { session in
                        SessionCard(store: store, session: session)
                    }
                    if !showAll && store.sorted.count > 3 {
                        Button("显示全部 \(store.sorted.count) 个会话") { showAll = true }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 4)
                    }
                }
            }
            .padding(10)
            .background(GeometryReader { g in
                Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
            })
        }
        .frame(height: min(natural, maxHeight))
        .scrollDisabled(natural <= maxHeight)
        .background(Theme.bg)
        .onPreferenceChange(ContentHeightKey.self) { h in
            natural = h
            onHeight(min(h, maxHeight))
        }
    }
}

struct SessionCard: View {
    let store: SessionStore
    let session: AgentSession
    @State private var showChat = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                AgentBuddy(source: session.source, state: session.state, size: 12)
                Text(session.projectName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if session.displayTitle != session.projectName {
                    Text("· \(session.displayTitle)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if hovering, !store.hasPendingInteraction(sessionID: session.id) {
                    Button {
                        store.removeSession(id: session.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("从 Atoll 移除")
                }
            }
            HStack(spacing: 5) {
                tag(session.source.capitalized, color: Theme.agentColor(session.source), filled: true)
                if store.isBypassed(session.id) {
                    tag("⚡ 自动批准", color: Theme.accent)
                }
                if session.observedInCodexDesktop {
                    tag("ChatGPT", color: Theme.textTertiary)
                }
                if !session.remoteHost.isEmpty { tag("🖧 \(session.remoteHost)", color: Theme.textTertiary) }
                if Settings.shared.showWorktree, let wt = session.worktreeName { tag("⑂ \(wt)", color: Theme.textTertiary) }
                if Settings.shared.showModel, !session.model.isEmpty { tag(session.model, color: Theme.textTertiary) }
                tag(elapsed, color: Theme.textTertiary)
                Spacer()
                stateBadge
            }
            if Settings.shared.showAgentDetail, !session.currentTool.isEmpty {
                toolLine(verb: String(session.currentTool.prefix(while: { $0 != " " })),
                         rest: String(session.currentTool.drop(while: { $0 != " " })))
            }
            if !session.lastPrompt.isEmpty, session.lastPrompt != session.displayTitle {
                HStack(alignment: .top, spacing: 4) {
                    Text("你：").foregroundStyle(Theme.textSecondary)
                    Text(session.lastPrompt)
                        .font(.system(size: 11)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                }
            }
            if !session.lastReply.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Text("AI：").foregroundStyle(Theme.accent)
                    Text(session.lastReply)
                        .font(.system(size: 11)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                }
            }
            if Settings.shared.showSubagents, session.subagentsRunning > 0 || session.subagentsDone > 0 {
                Text("子 Agent：\(session.subagentsRunning) 运行中 / \(session.subagentsDone) 完成")
                    .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
            }
            if session.hasTasks {
                HStack(spacing: 6) {
                    Text("任务")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.textTertiary)
                    Text("✓\(session.tasksDone)").font(.system(size: 10)).foregroundStyle(.green)
                    if session.tasksInProgress > 0 {
                        Text("▸\(session.tasksInProgress)").font(.system(size: 10)).foregroundStyle(Theme.accent)
                    }
                    Text("○\(session.tasksPending)").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                    ProgressView(value: Double(session.tasksDone),
                                 total: Double(max(1, session.tasksDone + session.tasksInProgress + session.tasksPending)))
                        .frame(width: 60).tint(.green)
                }
            }
            ForEach(session.toolLog.suffix(4)) { ev in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(ev.failed ? "✗" : "·")
                            .foregroundStyle(ev.failed ? .red : Theme.textTertiary)
                        Text(ev.toolName).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.accent.opacity(0.8))
                        Text(ev.detail).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    if !ev.result.isEmpty {
                        Text("└ \(ev.result)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary).lineLimit(1)
                            .padding(.leading, 10)
                    }
                }
            }
            if showChat {
                chatExcerpt
            }
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Theme.accent, lineWidth: store.selectedSessionID == session.id ? 1.5 : 0))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if Settings.shared.clickSessionToJump { JumpEngine.jump(to: session) }
        }
        .contextMenu {
            Button(showChat ? "收起对话" : "查看对话") { showChat.toggle() }
            Button("跳转到终端") { JumpEngine.jump(to: session) }
            Divider()
            if store.hasPendingInteraction(sessionID: session.id) {
                Button("待处理请求不可移除") {}
                    .disabled(true)
            } else {
                Button(role: .destructive) {
                    store.removeSession(id: session.id)
                } label: {
                    Label("从 Atoll 移除", systemImage: "trash")
                }
            }
            Divider()
            if store.isBypassed(session.id) {
                Button("关闭本会话自动批准") { store.setBypass(session.id, false) }
            } else {
                Button("开启本会话自动批准") { store.setBypass(session.id, true) }
            }
            Divider()
            Button("隐藏此目录的会话") { store.hideDir(session.cwd) }
            if !session.firstPrompt.isEmpty {
                Button("隐藏以此提示词开头的会话") { store.hidePromptPrefix(session.firstPrompt) }
            }
        }
    }

    /// Chat history excerpt, read lazily from the transcript.
    private var chatExcerpt: some View {
        VStack(alignment: .leading, spacing: 3) {
            let messages = Normalizer.recentMessages(transcriptPath: session.transcriptPath)
            if messages.isEmpty {
                Text("暂无对话记录").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            }
            ForEach(Array(messages.enumerated()), id: \.offset) { _, m in
                HStack(alignment: .top, spacing: 4) {
                    Text(m.role == "user" ? "你" : "AI")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(m.role == "user" ? Theme.textSecondary : Theme.accent)
                        .frame(width: 16, alignment: .trailing)
                    Text(m.text)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(4)
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
    }

    private func toolLine(verb: String, rest: String) -> some View {
        HStack(spacing: 4) {
            Text(verb).font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.accent)
            Text(rest).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textPrimary).lineLimit(1)
        }
    }

    private func tag(_ text: String, color: Color, filled: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 9, weight: filled ? .semibold : .medium))
            .foregroundStyle(filled ? .black : Theme.textSecondary)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(filled ? color : Theme.card.opacity(0.01), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: filled ? 0 : 0.5))
    }

    private var stateBadge: some View {
        Text(session.state.label)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(stateColor.opacity(0.22), in: Capsule())
            .foregroundStyle(stateColor)
    }

    private var stateColor: Color {
        switch session.state {
        case .thinking, .compacting: return .blue
        case .runningTool: return Theme.accent
        case .waitingApproval, .waitingAnswer, .needsAttention: return .red
        case .done: return .green
        case .ended: return .gray
        }
    }

    private var elapsed: String {
        let secs = Int(Date().timeIntervalSince(session.startedAt))
        if secs < 60 { return "<1m" }
        if secs < 3600 { return "\(secs / 60)m" }
        return "\(secs / 3600)h\((secs % 3600) / 60)m"
    }
}

/// Re-renders children every second so elapsed labels tick.
struct Ticker<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in content() }
    }
}
