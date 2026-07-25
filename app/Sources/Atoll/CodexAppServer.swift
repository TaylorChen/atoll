import Foundation

/// Monitors Codex Desktop (the ChatGPT/Codex app) via its own JSON-RPC
/// `app-server` channel, since sandboxed desktop apps don't invoke Atoll's
/// hooks. Spawns `codex app-server --listen stdio://`, does the initialize
/// handshake, then feeds thread/turn events into the session store.
///
/// Verified: a self-spawned app-server sees the Desktop app's live threads.
@MainActor
final class CodexAppServer {
    private let store: SessionStore
    private var process: Process?
    private var stdin: FileHandle?
    private var readBuffer = Data()
    private var nextID = 1
    private var pollTimer: Timer?
    private var restartTask: Task<Void, Never>?
    private var restartAttempt = 0
    private var shouldRun = false

    private static let warningPrefix = "Codex Desktop 监控中断"

    init(store: SessionStore) { self.store = store }

    /// The codex binary to run app-server with (CLI first, then the desktop app).
    private static func codexPath() -> String? {
        for p in ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                  "/Applications/ChatGPT.app/Contents/Resources/codex"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    func start() {
        shouldRun = true
        launch()
    }

    private func launch() {
        guard shouldRun, process == nil, let codex = Self.codexPath() else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: codex)
        proc.arguments = ["app-server", "--listen", "stdio://"]
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        stdin = inPipe.fileHandleForWriting

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.handleIncoming(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            let message = String(decoding: data.prefix(2_000), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty { NSLog("CodexAppServer stderr: \(message)") }
        }

        process = proc
        proc.terminationHandler = { [weak self] terminated in
            Task { @MainActor in self?.processTerminated(terminated) }
        }
        do {
            try proc.run()
        } catch {
            process = nil
            NSLog("CodexAppServer start failed: \(error)")
            scheduleRestart(reason: "启动失败：\(error.localizedDescription)")
            return
        }

        send(method: "initialize", params: ["clientInfo": ["name": "Atoll", "version": "1.0"]])
        // Seed existing threads, then poll periodically as a fallback for any
        // notifications that don't broadcast to this instance.
        listThreads()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.listThreads() }
        }
    }

    func stop() {
        shouldRun = false
        restartTask?.cancel()
        restartTask = nil
        pollTimer?.invalidate()
        pollTimer = nil
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        stdin = nil
    }

    private func processTerminated(_ terminated: Process) {
        guard process === terminated else { return }
        process = nil
        stdin = nil
        pollTimer?.invalidate()
        pollTimer = nil
        guard shouldRun else { return }

        let reason = "进程退出（status \(terminated.terminationStatus)）"
        NSLog("CodexAppServer \(reason)")
        scheduleRestart(reason: reason)
    }

    private func scheduleRestart(reason: String) {
        guard shouldRun, restartTask == nil else { return }
        store.warning = "\(Self.warningPrefix)，正在自动恢复：\(reason)"
        let delay = min(30, 1 << min(restartAttempt, 4))
        restartAttempt += 1
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.restartTask = nil
            self.launch()
        }
    }

    // MARK: - JSON-RPC out

    private func send(method: String, params: [String: Any]) {
        guard let stdin else { return }
        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": nextID, "method": method, "params": params]
        nextID += 1
        guard var line = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        line.append(0x0A)
        stdin.write(line)
    }

    private func listThreads() { send(method: "thread/list", params: ["limit": 30]) }

    // MARK: - JSON-RPC in

    private func handleIncoming(_ data: Data) {
        restartAttempt = 0
        if store.warning.hasPrefix(Self.warningPrefix) { store.warning = "" }
        readBuffer.append(data)
        while let nl = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer[readBuffer.startIndex..<nl]
            readBuffer.removeSubrange(readBuffer.startIndex...nl)
            guard let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else { continue }
            if let method = obj["method"] as? String {
                handleNotification(method: method, params: obj["params"] as? [String: Any] ?? [:])
            } else if let result = obj["result"] as? [String: Any] {
                // thread/list response: { data: [thread…] }
                if let data = result["data"] as? [[String: Any]] {
                    for t in data { applyThread(t) }
                }
            }
        }
    }

    private func handleNotification(method: String, params: [String: Any]) {
        switch method {
        case "thread/started":
            if let t = params["thread"] as? [String: Any] { applyThread(t, reviveDismissed: true) }
        case "thread/status/changed":
            if let id = params["threadId"] as? String {
                applyStatus(threadId: id, status: params["status"] as? [String: Any],
                            reviveDismissed: true)
            }
        case "thread/name/updated":
            if let id = params["threadId"] as? String {
                store.updateCodexDesktopTitle(id: id, title: params["name"] as? String ?? "")
            }
        case "turn/started":
            if let id = params["threadId"] as? String {
                store.setCodexDesktopState(id: id, .runningTool, reviveDismissed: true)
            }
        case "turn/completed":
            if let id = params["threadId"] as? String {
                store.setCodexDesktopState(id: id, .done, reviveDismissed: true)
            }
        case "thread/closed":
            if let id = params["threadId"] as? String {
                store.setCodexDesktopState(id: id, .ended, reviveDismissed: true)
            }
        default: break
        }
    }

    /// A thread object from thread/list or thread/started. Only surfaces
    /// currently-active threads or ones touched in the last few minutes —
    /// thread/list otherwise returns the whole history.
    private func applyThread(_ t: [String: Any], reviveDismissed: Bool = false) {
        guard let id = t["id"] as? String else { return }
        if t["ephemeral"] as? Bool == true { return }
        let status = t["status"] as? [String: Any]
        let isActive = (status?["type"] as? String) == "active"
        let updatedAt = (t["updatedAt"] as? Double) ?? (t["updatedAt"] as? Int).map(Double.init) ?? 0
        let recent = Date().timeIntervalSince1970 - updatedAt < Tuning.codexRecentWindow
        guard isActive || recent else { return }

        let cwd = t["cwd"] as? String ?? ""
        let title = (t["name"] as? String) ?? (t["preview"] as? String) ?? ""
        store.upsertCodexDesktopSession(id: id, cwd: cwd, title: title,
                                        reviveDismissed: reviveDismissed)
        applyStatus(threadId: id, status: status)
    }

    private func applyStatus(threadId: String, status: [String: Any]?,
                             reviveDismissed: Bool = false) {
        guard let status else { return }
        let type = status["type"] as? String ?? ""
        let flags = status["activeFlags"] as? [String] ?? []
        let state: SessionState
        switch type {
        case "active":
            if flags.contains("waitingOnApproval") { state = .waitingApproval }
            else if flags.contains("waitingOnUserInput") { state = .waitingAnswer }
            else { state = .runningTool }
        case "idle": state = .done        // resting; idle-cleanup ages it out
        case "systemError": state = .needsAttention
        default: return                   // notLoaded → ignore
        }
        store.setCodexDesktopState(id: threadId, state, reviveDismissed: reviveDismissed)
    }
}
