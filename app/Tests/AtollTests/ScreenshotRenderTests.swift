import XCTest
import AppKit
import SwiftUI
@testable import Atoll

/// Renders README screenshots from the real SwiftUI views fed with placeholder
/// hook payloads, so the images never contain a developer's real sessions.
/// Skipped unless ATOLL_SCREENSHOT_DIR is set; run via scripts/render-screenshots.sh.
@MainActor
final class ScreenshotRenderTests: XCTestCase {
    private var outputDir: URL!

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["ATOLL_SCREENSHOT_DIR"] else {
            throw XCTSkip("set ATOLL_SCREENSHOT_DIR to render README screenshots")
        }
        outputDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    }

    // MARK: - Scene

    private func makeStore() -> SessionStore {
        SessionStore(snapshotDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("atoll-shots-\(UUID().uuidString)"))
    }

    private func send(_ store: SessionStore, _ source: String, _ payload: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let form = ["payload": String(data: data, encoding: .utf8)!]
        guard let event = Normalizer.normalize(source: source, form: form) else {
            return XCTFail("placeholder payload did not normalize: \(payload)")
        }
        store.apply(event)
    }

    private func hold(_ store: SessionStore, _ source: String, _ payload: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let form = ["hold": "1", "payload": String(data: data, encoding: .utf8)!]
        guard let req = ClaudeCodec.pending(form: form, source: source) else {
            return XCTFail("placeholder payload did not produce a pending card: \(payload)")
        }
        store.addPending(req)
    }

    /// Three agents working in parallel, one of them waiting on an Edit approval.
    private func populate(_ store: SessionStore, withApproval: Bool) {
        let claude = "demo-claude", codex = "demo-codex", gemini = "demo-gemini"
        // Paths under the real home are shortened to "~/…" by the UI.
        let home = NSHomeDirectory()
        send(store, "claude", ["hook_event_name": "SessionStart", "session_id": claude,
                               "cwd": home + "/code/checkout-service", "model": ["display_name": "Opus"]])
        send(store, "claude", ["hook_event_name": "UserPromptSubmit", "session_id": claude,
                               "cwd": home + "/code/checkout-service",
                               "prompt": "Retry failed payments with exponential backoff"])
        send(store, "claude", ["hook_event_name": "PreToolUse", "session_id": claude,
                               "cwd": home + "/code/checkout-service", "tool_name": "Bash",
                               "tool_input": ["command": "go test ./payments/..."]])
        send(store, "claude", ["hook_event_name": "PostToolUse", "session_id": claude,
                               "cwd": home + "/code/checkout-service", "tool_name": "Bash",
                               "tool_response": ["stdout": "ok  payments  0.84s\n12 passed", "stderr": ""]])

        send(store, "codex", ["hook_event_name": "SessionStart", "session_id": codex,
                              "cwd": home + "/code/web-dashboard"])
        send(store, "codex", ["hook_event_name": "UserPromptSubmit", "session_id": codex,
                              "cwd": home + "/code/web-dashboard",
                              "prompt": "Add dark mode to the settings page"])
        send(store, "codex", ["hook_event_name": "PreToolUse", "session_id": codex,
                              "cwd": home + "/code/web-dashboard", "tool_name": "Edit",
                              "tool_input": ["file_path": home + "/code/web-dashboard/src/theme.ts"]])

        send(store, "gemini", ["hook_event_name": "SessionStart", "session_id": gemini,
                               "cwd": home + "/code/ml-notebooks"])
        send(store, "gemini", ["hook_event_name": "BeforeAgent", "session_id": gemini,
                               "cwd": home + "/code/ml-notebooks",
                               "prompt": "Summarize last week's eval results"])
        send(store, "gemini", ["hook_event_name": "AfterAgent", "session_id": gemini,
                               "cwd": home + "/code/ml-notebooks"])

        if withApproval {
            hold(store, "claude", ["hook_event_name": "PermissionRequest", "session_id": claude,
                                   "cwd": home + "/code/checkout-service",
                                   "tool_name": "Edit", "tool_use_id": "demo-edit",
                                   "tool_input": [
                                       "file_path": home + "/code/checkout-service/payments/retry.go",
                                       "old_string": "const maxAttempts = 1",
                                       "new_string": "const maxAttempts = 5 // exponential backoff"]])
        }
    }

    // MARK: - Rendering

    /// The expanded panel as it hangs from the top edge, over a dark desktop.
    private struct Backdrop<Content: View>: View {
        let content: Content
        var body: some View {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.20),
                                        Color(red: 0.03, green: 0.04, blue: 0.08)],
                               startPoint: .top, endPoint: .bottom)
                content
            }
            .frame(width: NotchPanel.panelWidth + NotchGeometry.expandedWingWidth * 2 + 120)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Hosts the view in an off-screen window rather than using ImageRenderer,
    /// which draws ScrollView (SessionListView) as an empty placeholder. Layout
    /// needs a few run-loop turns: the list sizes itself from a preference.
    private func write<V: View>(_ view: V, _ name: String) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 900),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        window.setContentSize(host.fittingSize)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = outputDir.appendingPathComponent(name)
        try png.write(to: url)
        print("wrote \(url.path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }

    func testRenderPanelScreenshots() throws {
        let wasEnabled = SoundPlayer.enabled
        defer { SoundPlayer.enabled = wasEnabled }

        let usage = UsageReader()
        usage.snapshot = UsageSnapshot(fiveHourPercent: 42, sevenDayPercent: 18,
                                       fiveHourResetsAt: Date().addingTimeInterval(2 * 3600 + 14 * 60),
                                       sevenDayResetsAt: Date().addingTimeInterval(3 * 86400),
                                       contextPercent: nil, updatedAt: Date())

        // Silence the placeholder events, then show the header's default
        // (sound on) speaker icon in the rendered panels.
        SoundPlayer.enabled = false
        let approval = makeStore(), collapsed = makeStore()
        populate(approval, withApproval: true)
        populate(collapsed, withApproval: false)
        SoundPlayer.enabled = true

        approval.notchExpanded = true
        try write(Backdrop(content: NotchView(store: approval, usage: usage)
            .padding(.bottom, 40)), "panel-approval.png")

        try write(Backdrop(content: NotchView(store: collapsed, usage: usage)
            .padding(.bottom, 24)), "island-collapsed.png")
    }
}
