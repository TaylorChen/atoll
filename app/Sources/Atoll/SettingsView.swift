import AppKit
import SwiftUI

/// Wraps the diagnostic preview text so it can drive a `.sheet(item:)`.
private struct DiagPreview: Identifiable {
    let text: String
    var id: String { text }
}

/// Atoll's Settings window — covers the
/// preferences Atoll can actually honor (display / behaviour / sound / filter).
struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var store: SessionStore
    @StateObject private var hooks = HooksManager()
    @ObservedObject private var hotkeyStatus = HotKeyStatus.shared
    @State private var diagPreview: String?
    @State private var extraDirError: String?

    var body: some View {
        TabView {
            generalTab.tabItem { Label("通用", systemImage: "gearshape") }
            integrationsTab.tabItem { Label("集成", systemImage: "puzzlepiece.extension") }
            displayTab.tabItem { Label("显示", systemImage: "rectangle.on.rectangle") }
            behaviourTab.tabItem { Label("行为", systemImage: "slider.horizontal.3") }
            notificationsTab.tabItem { Label("通知", systemImage: "bell") }
            filterTab.tabItem { Label("过滤", systemImage: "line.3.horizontal.decrease.circle") }
        }
        .frame(width: 600, height: 540)
        .onAppear { hooks.refresh() }
    }

    // MARK: 通用

    @State private var launchAtLogin = LoginItem.enabled

    private var generalTab: some View {
        Form {
            Section("启动") {
                Toggle("登录时启动", isOn: Binding(
                    get: { launchAtLogin },
                    set: { launchAtLogin = $0; LoginItem.set($0) }))
                Text("需以 /Applications 里的 Atoll.app 运行才生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            shortcutsSection
            Section("关于") {
                HStack { Text("版本"); Spacer(); Text("1.0.0").foregroundStyle(.secondary) }
                Text("Atoll — 多 Agent 灵动岛监控 / 批准。纯本地、无云端、无遥测。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Label("退出 Atoll", systemImage: "power")
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var shortcutsSection: some View {
        let conflicts = HotKeyConfig.conflicts()
        Section("全局快捷键") {
            Toggle("启用键盘快捷键", isOn: Binding(
                get: { HotKeyConfig.enabled },
                set: { HotKeyConfig.enabled = $0; hotkeysChanged() }))
            Picker("修饰键", selection: Binding(
                get: { HotKeyConfig.modifier },
                set: { HotKeyConfig.modifier = $0; hotkeysChanged() })) {
                ForEach(HotKeyModifier.allCases) { Text($0.label).tag($0) }
            }
            .disabled(!HotKeyConfig.enabled)
            ForEach(HotKeyAction.allCases) { action in
                HStack {
                    Text(action.label).font(.caption)
                    if conflicts.contains(action) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    if hotkeyStatus.registrationFailures.contains(action) {
                        Image(systemName: "xmark.octagon.fill")
                            .font(.caption2).foregroundStyle(.red)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { HotKeyConfig.keyCode(for: action) },
                        set: { HotKeyConfig.setKeyCode($0, for: action); hotkeysChanged() })) {
                        ForEach(HotKeyConfig.letterKeys, id: \.code) { Text($0.label).tag($0.code) }
                    }
                    .labelsHidden().frame(width: 70)
                    .disabled(!HotKeyConfig.enabled)
                }
            }
            if !conflicts.isEmpty {
                Label("有快捷键重复绑定，重复项不会全部生效。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if !hotkeyStatus.registrationFailures.isEmpty {
                Label("部分快捷键系统注册失败（可能被其他 App 占用），换个键位或修饰键再试。",
                      systemImage: "xmark.octagon.fill")
                    .font(.caption2).foregroundStyle(.red)
            }
            Button("恢复默认键位") { HotKeyConfig.resetToDefaults(); hotkeysChanged() }
                .controlSize(.small)
            Text("修饰键 + 上表按键触发。停用只是取消注册，键位设置会保留。⌥⇧J/K 在会话间切换、跳转键回到选中会话的终端。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func hotkeysChanged() {
        settings.objectWillChange.send()
        NotificationCenter.default.post(name: .atollHotkeysChanged, object: nil)
    }

    // MARK: 集成 (CLI Hooks)

    /// Trust-gated: sandboxed desktop apps that silently skip untrusted hooks.
    private func trustGated(_ id: String) -> Bool { ["codex", "qoder"].contains(id) }
    private func integrationStatus(_ cli: HooksManager.CLI) -> (String, Color) {
        if !cli.cliPresent { return ("未检测到", .secondary) }
        if !cli.enabled { return (cli.installed ? "检测到残留配置" : "未启用", .secondary) }
        if !cli.healthy { return ("配置异常", .red) }
        if store.seenSources.contains(cli.id) { return ("已连接", .green) }
        return ("已配置", .orange)
    }

    private func diagnosticText(_ cli: HooksManager.CLI) -> String {
        if cli.error.hasPrefix("config-invalid:") { return "配置文件无法解析，请修复原文件后重新检测" }
        if cli.error == "bridge-missing" { return "Atoll bridge 缺失，需要重新安装或修复" }
        if cli.error.hasPrefix("hooks-missing:") { return "Hook 配置不完整，缺少 \(cli.missingHooks) 项" }
        if cli.healthy && !store.seenSources.contains(cli.id) { return "配置完整，等待该 Agent 发来首个事件" }
        return cli.error
    }

    private var integrationsTab: some View {
        Form {
            Section {
                ForEach(hooks.clis) { cli in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(cli.name)
                            Spacer()
                            Text(integrationStatus(cli).0)
                                .font(.caption)
                                .foregroundStyle(integrationStatus(cli).1)
                            if cli.enabled && !cli.healthy {
                                Button("修复") { hooks.repair(cli.id) }
                                    .controlSize(.small)
                                    .disabled(!cli.cliPresent || hooks.workingSource == cli.id)
                            }
                            Toggle("", isOn: Binding(
                                get: { cli.enabled },
                                set: { hooks.setEnabled(cli.id, $0) }))
                                .labelsHidden()
                                .disabled(!cli.cliPresent || !hooks.workingSource.isEmpty)
                        }
                        Text(cli.supportsApproval ? "能力：会话监控 · 原生协议审批" : "能力：会话监控")
                            .font(.caption2).foregroundStyle(.secondary)
                        if !diagnosticText(cli).isEmpty {
                            Label(diagnosticText(cli), systemImage: cli.healthy ? "clock" : "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(cli.healthy ? Color.secondary : Color.red)
                        }
                        // Trust hint for trust-gated desktop CLIs (Codex/Qoder):
                        // hooks installed but no events → not trusted / app needs
                        // to re-read hooks (started before Atoll's hook was added).
                        if trustGated(cli.id), cli.installed, !store.seenSources.contains(cli.id) {
                            HStack(alignment: .top, spacing: 6) {
                                Label("已装但未收到事件 — 需重启该 App 会话并信任 Atoll hooks",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2).foregroundStyle(.orange)
                                Spacer()
                                if cli.id == "codex" {
                                    Button("一键授权…") { hooks.openCodexTrust() }
                                        .controlSize(.small)
                                }
                            }
                            Text(cli.id == "codex"
                                 ? "CLI：点按钮打开终端运行 codex 按提示 Trust；Desktop：设置 → Hooks → 信任 Atoll。"
                                 : "\(cli.name) 桌面应用启动时已缓存 hook 列表：新开一个任务/重启 App 让它重新读取，弹出信任提示时选信任。")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if cli.healthy, cli.supportsApproval {
                            Picker("审批位置", selection: Binding(
                                get: { settings.approvalRoute(for: cli.id) },
                                set: { settings.setApprovalRoute($0, for: cli.id) })) {
                                ForEach(ApprovalRoute.allCases) { route in
                                    Text(route.label).tag(route)
                                }
                            }
                            .pickerStyle(.segmented)
                            .controlSize(.small)
                            Text("跟随焦点：Agent 所在终端或桌面应用在前台时使用原生审批，否则在 Atoll 审批。")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Agent 集成")
                    Spacer()
                    Button { hooks.refresh() } label: {
                        Label("重新检测", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }
            }
            if !hooks.failureMessage.isEmpty {
                Section("诊断失败") {
                    Label(hooks.failureMessage, systemImage: "xmark.octagon.fill")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            extraDirsSection
            usageBridgeSection
            Section("诊断") {
                Button("导出诊断报告…") {
                    diagPreview = String(data: Diagnostics.serialize(Diagnostics.collect(hooks: hooks)),
                                         encoding: .utf8) ?? "{}"
                }
                Text("生成纯本地报告：版本、macOS、集成健康、网关状态、最近错误和设置摘要。不含 prompt、回复、命令、文件内容、Token 或用户名路径。导出前可先查看内容。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section {
                Text("“已配置”表示 Hook 与 bridge 完整；收到首个真实事件后变为“已连接”。配置异常不会被静默显示成未启用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { hooks.refreshStatusLine(); hooks.refreshExtraDirs() }
        .sheet(item: Binding(get: { diagPreview.map(DiagPreview.init) },
                             set: { diagPreview = $0?.text })) { preview in
            diagnosticSheet(preview.text)
        }
    }

    @ViewBuilder private var extraDirsSection: some View {
        Section("多配置目录（Claude / Codex）") {
            ForEach(hooks.extraDirs) { dir in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(dir.source.capitalized) · \((dir.directory as NSString).lastPathComponent)")
                            .font(.caption)
                        Spacer()
                        Text(dir.error.isEmpty ? (dir.healthy ? "已配置" : (dir.installed ? "需修复" : "未配置"))
                             : "配置异常")
                            .font(.caption2)
                            .foregroundStyle(dir.healthy ? .green : dir.error.isEmpty ? .orange : .red)
                        Button(role: .destructive) {
                            hooks.removeExtraDir(dir.source, dir.directory, removeHooks: true)
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(.red)
                    }
                    Text(dir.directory).font(.caption2).foregroundStyle(.secondary)
                    if !dir.error.isEmpty {
                        Text(dir.error).font(.caption2).foregroundStyle(.red)
                    }
                }
            }
            HStack {
                Button("添加 Claude 目录…") { pickExtraDir("claude") }
                Button("添加 Codex 目录…") { pickExtraDir("codex") }
            }
            if let err = extraDirError {
                Text("添加失败：\(err)").font(.caption2).foregroundStyle(.red)
            }
            Text("为多账号或兼容发行版添加额外配置目录，每个目录独立安装、诊断与卸载。移除时会一并清除该目录里的 Atoll Hook，其它工具配置保持不变。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func pickExtraDir(_ source: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "选择"
        panel.message = "选择 \(source.capitalized) 的配置目录"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let err = hooks.addExtraDir(source, url.path)
        extraDirError = err.isEmpty ? nil : err
    }

    private func diagnosticSheet(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("诊断报告预览").font(.headline)
            Text("这是将要保存的完整内容，已脱敏。确认后可保存到文件。")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(text).font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 300)
            .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("保存到文件…") { saveDiagnostic(text) }
                Spacer()
                Button("关闭") { diagPreview = nil }
            }
        }
        .padding(16)
        .frame(width: 560)
    }

    private func saveDiagnostic(_ text: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "atoll-diagnostics.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            try? text.data(using: .utf8)?.write(to: url)
        }
        diagPreview = nil
    }

    /// Effective usage-bridge status combines the installer facts (wrapped / jq)
    /// with the cache freshness the app itself sees.
    private var usageStatus: UsageStatus {
        let snap = UsageSnapshot.load() ?? UsageSnapshot()
        return UsageStatusPolicy.status(
            connected: hooks.statusLineConnected,
            jqPresent: hooks.statusLineJqPresent,
            configError: hooks.statusLineConfigError,
            hasData: !snap.isEmpty,
            isStale: snap.isStale())
    }

    @ViewBuilder private var usageBridgeSection: some View {
        Section("Claude 用量桥接") {
            HStack {
                Text("状态")
                Spacer()
                Text(usageStatus.label)
                    .font(.caption)
                    .foregroundStyle(usageStatus == .connected ? .green
                                     : usageStatus == .configError ? .red : .orange)
            }
            Text("Atoll 在 Claude Code 的 statusLine 上串接一个桥接脚本，读取每条消息里的 rate_limits 缓存到本地供面板显示。你原有的 statusLine 输出会被保留并透明转发，不受影响。")
                .font(.caption2).foregroundStyle(.secondary)
            if usageStatus == .configError && !hooks.statusLineJqPresent {
                Label("缺少 jq：请先 brew install jq 再连接。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.red)
            }
            if usageStatus == .stale {
                Label("缓存数据已超过 15 分钟未更新，显示为过期而非实时值。", systemImage: "clock.badge.exclamationmark")
                    .font(.caption2).foregroundStyle(.orange)
            }
            HStack {
                if hooks.statusLineConnected {
                    Button("断开") { hooks.disconnectStatusLine() }
                    Text("断开只移除 Atoll 串接的部分，恢复你原来的 statusLine。")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Button("连接") { hooks.connectStatusLine() }
                        .disabled(!hooks.statusLineJqPresent)
                }
                Spacer()
                Button { hooks.refreshStatusLine() } label: {
                    Image(systemName: "arrow.clockwise")
                }.controlSize(.small)
            }
        }
    }

    // MARK: 显示

    private var displayTab: some View {
        Form {
            Section("显示器") {
                Picker("灵动岛显示位置", selection: Binding(
                    get: { settings.displayScreenID },
                    set: { settings.displayScreenID = $0 })) {
                    Text("主显示器").tag("primary")
                    ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, screen in
                        Text(screen.localizedName).tag(DisplayPolicy.screenID(screen))
                    }
                }
                Picker("收起样式", selection: Binding(
                    get: { settings.collapsedStyle },
                    set: { settings.collapsedStyle = $0 })) {
                    ForEach(CollapsedStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("面板尺寸") {
                slider("展开宽度", value: bind(\.panelWidth), range: 380...760, unit: "pt")
                slider("展开高度", value: bind(\.panelHeight), range: 320...760, unit: "pt")
                slider("灵动岛宽度", value: bind(\.notchWidth), range: 160...440, unit: "pt")
                slider("灵动岛高度", value: bind(\.notchHeight), range: 22...44, unit: "pt")
                Button("恢复默认尺寸") {
                    settings.panelWidth = 600; settings.panelHeight = 560
                    settings.notchWidth = 260; settings.notchHeight = 30
                }
            }
            Section("会话卡片") {
                Toggle("显示 AI 模型", isOn: bind(\.showModel))
                Toggle("显示工作树", isOn: bind(\.showWorktree))
                Toggle("显示 Agent 活动详情", isOn: bind(\.showAgentDetail))
                Toggle("显示子 Agent", isOn: bind(\.showSubagents))
                Toggle("面板顶部显示用量限额", isOn: bind(\.showUsage))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: 行为

    private var behaviourTab: some View {
        Form {
            Section("展开") {
                Toggle("悬停时展开面板", isOn: bind(\.expandOnHover))
                slider("悬停展开延迟", value: bind(\.hoverExpandDelay), range: 0...1.5, unit: "s")
                Toggle("收到完成通知时展开", isOn: bind(\.expandOnComplete))
                slider("完成提醒停留", value: bind(\.completionDwell), range: 1...12, unit: "s")
                Toggle("Agent 应用在前台时不弹出完成面板",
                       isOn: bind(\.suppressCompletionPopupWhenAgentFrontmost))
            }
            Section("收起") {
                Toggle("鼠标离开时自动收起", isOn: bind(\.autoCollapseOnLeave))
                slider("离开收起延迟", value: bind(\.collapseDwell), range: 0.1...2, unit: "s")
                Toggle("面板外点击立即关闭提醒", isOn: bind(\.dismissOnOutsideClick))
                Text("按 ESC 或点击面板外可立即关闭完成/警告提醒；等待审批、回答、计划的卡片不受影响。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("显隐") {
                Toggle("全屏时隐藏", isOn: bind(\.hideInFullscreen))
                Toggle("无活跃会话时自动隐藏面板", isOn: bind(\.autoHideWhenIdle))
                Text("仅隐藏灵动岛显示，不会删除任何会话；有新事件或待审批时立即恢复。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("点击会话卡跳转到 Agent 终端", isOn: bind(\.clickSessionToJump))
                slider("空闲会话自动清理", value: bind(\.idleCleanupHours), range: 0.5...24, unit: "h")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: 通知与降噪

    private var notificationsTab: some View {
        Form {
            Section("通知渠道") {
                Toggle("系统通知横幅", isOn: Binding(
                    get: { settings.systemNotificationsEnabled },
                    set: { AtollNotifier.shared.setSystemNotificationsEnabled($0) }))
                Toggle("提醒音", isOn: Binding(
                    get: { SoundPlayer.enabled },
                    set: { SoundPlayer.enabled = $0; settings.objectWillChange.send() }))
            }
            Section("事件类型") {
                Toggle("等待审批", isOn: bind(\.notifyApprovals))
                Toggle("等待回答", isOn: bind(\.notifyQuestions))
                Toggle("任务完成", isOn: bind(\.notifyCompletions))
                Toggle("连续失败 / 异常结束", isOn: bind(\.notifyFailures))
                Picker("子 Agent / Agent Team 通知", selection: Binding(
                    get: { settings.childNotifyTiming },
                    set: { settings.childNotifyTiming = $0 })) {
                    ForEach(ChildNotifyTiming.allCases) { Text($0.label).tag($0) }
                }
                Text("选择完成通知时机；审批和问题始终立即显示。关闭某类通知只停止声音、横幅和完成弹出；审批卡及错误状态仍会保留。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("降噪") {
                slider("完成通知合并窗口", value: bind(\.completionNotificationCooldown),
                       range: 0...30, unit: "s")
                Toggle("Agent 应用在前台时不发系统横幅",
                       isOn: bind(\.suppressNotificationWhenAgentFrontmost))
            }
            Section("提醒音") {
                Picker("声音主题", selection: Binding(
                    get: { SoundPlayer.activePack },
                    set: { SoundPlayer.activePack = $0; settings.objectWillChange.send() })) {
                    Text("内置系统音").tag("")
                    ForEach(SoundPlayer.installedPacks(), id: \.self) { Text($0).tag($0) }
                }
            }
            Section("静默时段") {
                Toggle("启用静默时段", isOn: Binding(
                    get: { QuietPolicy.quietHoursEnabled },
                    set: { QuietPolicy.quietHoursEnabled = $0; settings.objectWillChange.send() }))
                Stepper("开始 \(QuietPolicy.quietStartHour):00", value: Binding(
                    get: { QuietPolicy.quietStartHour },
                    set: { QuietPolicy.quietStartHour = $0; settings.objectWillChange.send() }), in: 0...23)
                Stepper("结束 \(QuietPolicy.quietEndHour):00", value: Binding(
                    get: { QuietPolicy.quietEndHour },
                    set: { QuietPolicy.quietEndHour = $0; settings.objectWillChange.send() }), in: 0...23)
                Toggle("屏幕镜像 / AirPlay 时静默", isOn: Binding(
                    get: { QuietPolicy.suppressDuringScreenShare },
                    set: { QuietPolicy.suppressDuringScreenShare = $0; settings.objectWillChange.send() }))
                Toggle("锁屏或切换用户时静默", isOn: Binding(
                    get: { QuietPolicy.suppressWhenSessionInactive },
                    set: { QuietPolicy.suppressWhenSessionInactive = $0; settings.objectWillChange.send() }))
                Toggle("系统唤醒后 15 秒内静默", isOn: Binding(
                    get: { QuietPolicy.suppressAfterWake },
                    set: { QuietPolicy.suppressAfterWake = $0; settings.objectWillChange.send() }))
                Label(QuietPolicy.isQuiet ? "当前处于静默状态" : "当前通知正常",
                      systemImage: QuietPolicy.isQuiet ? "moon.fill" : "bell.fill")
                    .font(.caption)
                    .foregroundStyle(QuietPolicy.isQuiet ? Color.secondary : Color.green)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: 过滤

    private var filterTab: some View {
        Form {
            Section("内置后台规则") {
                ForEach(store.filterRules.filter(\.builtin)) { rule in
                    ruleRow(rule)
                }
                Text("这些是已知的后台/辅助会话签名，可逐条开关。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("自定义规则") {
                let custom = store.filterRules.filter { !$0.builtin }
                if custom.isEmpty {
                    Text("暂无自定义规则。右键会话卡可添加「隐藏此目录 / 此提示词」。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(custom) { rule in
                        HStack {
                            ruleRow(rule)
                            Button(role: .destructive) { store.removeRule(rule.id) } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.plain).foregroundStyle(.red)
                        }
                    }
                    Button("清空所有自定义规则") { store.resetHiddenDirs() }
                }
            }
            let hidden = store.hiddenSessionsWithRule
            if !hidden.isEmpty {
                Section("当前被过滤的会话（\(hidden.count)）") {
                    ForEach(hidden, id: \.session.id) { pair in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pair.session.displayTitle).font(.caption)
                            HStack {
                                Text("被规则「\(pair.rule.name)」过滤 · \(pair.rule.reason)")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Button("停用该规则") { store.setRuleEnabled(pair.rule.id, false) }
                                    .font(.caption2)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// A rule row: toggle + name + kind/match badge + live hit count.
    private func ruleRow(_ rule: FilterRule) -> some View {
        Toggle(isOn: Binding(
            get: { rule.enabled },
            set: { store.setRuleEnabled(rule.id, $0) })) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(rule.name).font(.caption)
                    Text("\(rule.kind.label)·\(rule.match.label)")
                        .font(.caption2).foregroundStyle(.secondary)
                    let hits = store.hitCount(for: rule)
                    if hits > 0 {
                        Text("命中 \(hits)").font(.caption2).foregroundStyle(.orange)
                    }
                }
                if !rule.reason.isEmpty {
                    Text(rule.reason).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: helpers

    private func bind(_ kp: ReferenceWritableKeyPath<Settings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: kp] }, set: { settings[keyPath: kp] = $0 })
    }
    private func bind(_ kp: ReferenceWritableKeyPath<Settings, Double>) -> Binding<Double> {
        Binding(get: { settings[keyPath: kp] }, set: { settings[keyPath: kp] = $0 })
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        HStack {
            Text(label)
            Slider(value: value, in: range)
            Text(sliderValue(value.wrappedValue, unit: unit)).font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
        }
    }

    private func sliderValue(_ value: Double, unit: String) -> String {
        if unit == "s", value > 0, value < 1 {
            return String(format: "%.1f%@", value, unit)
        }
        return "\(Int(value))\(unit)"
    }
}
