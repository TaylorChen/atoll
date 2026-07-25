import AppKit
import SwiftUI

extension SettingsView {
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

    var integrationsTab: some View {
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
}
