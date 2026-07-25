import SwiftUI

extension SettingsView {
    // MARK: 显示

    var displayTab: some View {
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

    var behaviourTab: some View {
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

    var notificationsTab: some View {
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

    var filterTab: some View {
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
}
