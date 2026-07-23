import Foundation

/// Watches CLI config files and restores Atoll hook entries if another tool
/// strips them. Rate-limited: repeated removals mean a config war with another
/// tool — stop restoring and surface a warning instead of fighting.
final class HookWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var timer: DispatchSourceTimer?
    private var restoreTimes: [Date] = []
    private var debounce: DispatchWorkItem?
    private let store: SessionStore
    private var installScript: String {
        Bundle.main.path(forResource: "install-hooks", ofType: "py")
            ?? NSString(string: "~/atoll/scripts/install-hooks.py").expandingTildeInPath
    }

    /// Directories watched (files are replaced atomically, so watch the parent).
    private let watchedDirs = [
        NSString(string: "~/.claude").expandingTildeInPath,
        NSString(string: "~/.codex").expandingTildeInPath,
        NSString(string: "~/.gemini").expandingTildeInPath,
        NSString(string: "~/.qoder").expandingTildeInPath,
        NSString(string: "~/.cursor").expandingTildeInPath,
        NSString(string: "~/.qwen").expandingTildeInPath,
        NSString(string: "~/.factory").expandingTildeInPath,
        NSString(string: "~/.codebuddy").expandingTildeInPath,
        NSString(string: "~/.kimi").expandingTildeInPath,
        NSString(string: "~/.config/opencode").expandingTildeInPath,
    ]

    init(store: SessionStore) {
        self.store = store
    }

    func start() {
        // Directory watch catches atomic replaces; file watch catches in-place
        // writes; the periodic sweep catches anything both miss.
        for dir in watchedDirs {
            watch(path: dir, mask: [.write])
            for file in ["settings.json", "hooks.json", "config.toml", "opencode.json", "config.json"] {
                watch(path: dir + "/" + file, mask: [.write, .delete, .rename, .extend])
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in self?.checkAndRestore() }
        timer.resume()
        self.timer = timer
    }

    private func watch(path: String, mask: DispatchSource.FileSystemEvent) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: mask, queue: .global(qos: .utility))
        src.setEventHandler { [weak self] in self?.scheduleCheck() }
        src.setCancelHandler { close(fd) }
        src.resume()
        sources.append(src)
    }

    private func scheduleCheck() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkAndRestore() }
        debounce = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func checkAndRestore() {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
              FileManager.default.fileExists(atPath: installScript) else {
            NSLog("HookWatcher disabled: python3 or install-hooks.py is missing")
            return
        }

        // Rate limit: >3 restores in 10 minutes = config war, stop and warn.
        restoreTimes = restoreTimes.filter { $0.timeIntervalSinceNow > -600 }
        if restoreTimes.count > 3 {
            Task { @MainActor in
                self.store.warning = "Hooks 被反复移除，已停止自动恢复 — 请检查其他工具的配置行为"
            }
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [installScript, "--restore"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if out.contains("installed") {
                restoreTimes.append(Date())
                NSLog("HookWatcher: atoll hooks were removed by another tool — restored")
                Task { @MainActor in
                    self.store.warning = "Hooks 曾被其他工具移除，已自动恢复"
                }
            }
        } catch {
            NSLog("HookWatcher restore failed: \(error)")
        }
    }
}
