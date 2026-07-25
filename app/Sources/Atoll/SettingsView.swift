import AppKit
import SwiftUI

/// Wraps the diagnostic preview text so it can drive a `.sheet(item:)`.
struct DiagPreview: Identifiable {
    let text: String
    var id: String { text }
}

/// Atoll's Settings window — covers the
/// preferences Atoll can actually honor (display / behaviour / sound / filter).
struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var store: SessionStore
    @StateObject var hooks = HooksManager()
    @ObservedObject private var hotkeyStatus = HotKeyStatus.shared
    @State var diagPreview: String?
    @State var extraDirError: String?

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
                HStack { Text("版本"); Spacer(); Text(AppInfo.version).foregroundStyle(.secondary) }
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


    // MARK: helpers

    func bind(_ kp: ReferenceWritableKeyPath<Settings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: kp] }, set: { settings[keyPath: kp] = $0 })
    }
    func bind(_ kp: ReferenceWritableKeyPath<Settings, Double>) -> Binding<Double> {
        Binding(get: { settings[keyPath: kp] }, set: { settings[keyPath: kp] = $0 })
    }

    func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        HStack {
            Text(label)
            Slider(value: value, in: range)
            Text(sliderValue(value.wrappedValue, unit: unit)).font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
        }
    }

    func sliderValue(_ value: Double, unit: String) -> String {
        if unit == "s", value > 0, value < 1 {
            return String(format: "%.1f%@", value, unit)
        }
        return "\(Int(value))\(unit)"
    }
}
