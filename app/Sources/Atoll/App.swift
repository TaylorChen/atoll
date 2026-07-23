import AppKit
import Darwin
import SwiftUI

final class AppInstanceLock {
    enum LockError: Error {
        case cannotOpen(path: String, errno: Int32)
        case alreadyRunning
        case cannotLock(path: String, errno: Int32)
    }

    private var descriptor: Int32

    init(path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory,
                                                withIntermediateDirectories: true)
        descriptor = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LockError.cannotOpen(path: path, errno: errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            descriptor = -1
            if code == EWOULDBLOCK { throw LockError.alreadyRunning }
            throw LockError.cannotLock(path: path, errno: code)
        }
    }

    deinit {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var instanceLock: AppInstanceLock?
    private let store = SessionStore()
    private var gateway: Gateway!
    private var notch: NotchPanel!
    private var watcher: HookWatcher!
    private var hotKeys: HotKeys!
    private var codexAppServer: CodexAppServer!
    private let usage = UsageReader()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let lockPath = NSString(string: "~/.atoll/run/app.lock").expandingTildeInPath
        do {
            instanceLock = try AppInstanceLock(path: lockPath)
        } catch AppInstanceLock.LockError.alreadyRunning {
            NSLog("Atoll is already running; exiting duplicate instance")
            NSApp.terminate(nil)
            return
        } catch {
            NSLog("Atoll cannot acquire its single-instance lock: \(error)")
            NSApp.terminate(nil)
            return
        }
        do {
            try RuntimeInstaller.installBundledHelpers()
        } catch {
            let message = "Atoll helper 安装失败：\(error.localizedDescription)"
            NSLog("\(message)")
            store.warning = message
        }
        gateway = Gateway(store: store)
        gateway.onFailure = { message in
            DispatchQueue.main.async {
                NSLog("Atoll cannot continue without its local gateway: \(message)")
                NSApp.terminate(nil)
            }
        }
        do {
            try gateway.start()
        } catch {
            NSLog("Atoll gateway failed to start: \(error)")
            NSApp.terminate(nil)
            return
        }

        usage.start()
        QuietRuntimeState.shared.start()
        // Codex Desktop doesn't fire hooks; monitor it via the app-server channel.
        codexAppServer = CodexAppServer(store: store)
        codexAppServer.start()
        notch = NotchPanel(store: store, usage: usage)
        notch.onOpenSettings = { [weak self] in self?.openSettings() }
        watcher = HookWatcher(store: store)
        watcher.start()
        hotKeys = HotKeys(store: store)
        hotKeys.togglePanel = { [weak self] in self?.notch.toggle() }
        hotKeys.register()

        // Panel hygiene: periodically drop long-idle sessions.
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in self.store.cleanupIdle() }
        }
        // Push AI session titles from the statusLine bridge into the store.
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in self.store.applyTitles(self.usage.sessionNames) }
        }

        if ProcessInfo.processInfo.environment["ATOLL_OPEN_SETTINGS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.openSettings() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        codexAppServer?.stop()
    }

    private var settingsWindow: NSWindow?

    @objc private func openSettings() {
        // Collapse the notch so the panel (statusBar level) doesn't cover the
        // settings window, and float the settings window above it.
        store.notchExpanded = false
        if settingsWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            win.title = "Atoll 设置"
            win.contentView = NSHostingView(rootView: SettingsView(store: store))
            win.center()
            win.isReleasedWhenClosed = false
            settingsWindow = win
        }
        // Normal window level (not always-on-top). Collapsing the notch above +
        // activating is enough to bring it to front without floating over everything.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

}

@main
struct AtollMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
