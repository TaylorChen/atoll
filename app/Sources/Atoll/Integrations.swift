import Foundation

/// Reads/toggles per-CLI hook installation via install-hooks.py — backs the
/// Settings ▸ 集成 (Integrations) tab, listing per-CLI hook status.
@MainActor
final class HooksManager: ObservableObject {
    struct CLI: Identifiable {
        let id: String
        let name: String      // display name
        var installed: Bool
        var enabled: Bool
        var healthy: Bool
        var cliPresent: Bool
        var bridgePresent: Bool
        var missingHooks: Int
        var configPath: String
        var error: String
        var supportsApproval: Bool
    }

    @Published var clis: [CLI] = []
    @Published var failureMessage = ""
    @Published var workingSource = ""

    private var script: String {
        if let bundled = Bundle.main.path(forResource: "install-hooks", ofType: "py") {
            return bundled
        }
        return NSString(string: "~/atoll/scripts/install-hooks.py").expandingTildeInPath
    }

    func refresh() {
        let result = run(["--status"])
        guard result.status == 0,
              let data = result.stdout.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] else {
            failureMessage = result.errorMessage.isEmpty ? "无法解析集成诊断结果" : result.errorMessage
            return
        }
        failureMessage = ""
        clis = AgentCatalog.ids.compactMap { id in
            guard let s = obj[id] else { return nil }
            return CLI(id: id, name: AgentCatalog.displayName(id),
                       installed: s["installed"] as? Bool ?? false,
                       enabled: s["enabled"] as? Bool ?? false,
                       healthy: s["healthy"] as? Bool ?? false,
                       cliPresent: s["cliPresent"] as? Bool ?? false,
                       bridgePresent: s["bridgePresent"] as? Bool ?? false,
                       missingHooks: s["missingHooks"] as? Int ?? 0,
                       configPath: s["configPath"] as? String ?? "",
                       error: s["error"] as? String ?? "",
                       supportsApproval: AgentCatalog.canApprove(id))
        }
    }

    // MARK: - Usage statusLine bridge

    @Published var statusLineConnected = false
    @Published var statusLineJqPresent = true
    @Published var statusLineConfigError = false

    func refreshStatusLine() {
        let result = run(["--statusline", "status"])
        applyStatusLine(result)
    }

    func connectStatusLine() { applyStatusLine(run(["--statusline", "connect"])) }
    func disconnectStatusLine() { applyStatusLine(run(["--statusline", "disconnect"])) }

    private func applyStatusLine(_ result: ProcessResult) {
        guard let data = result.stdout.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            statusLineConfigError = true
            return
        }
        statusLineConnected = obj["connected"] as? Bool ?? false
        statusLineJqPresent = obj["jqPresent"] as? Bool ?? true
        let err = obj["error"] as? String ?? ""
        statusLineConfigError = !err.isEmpty
        if !err.isEmpty { failureMessage = err }
    }

    // MARK: - Extra config directories (multiple Claude/Codex accounts or forks)

    struct ExtraDir: Identifiable {
        let source: String
        let directory: String
        var installed: Bool
        var healthy: Bool
        var bridgePresent: Bool
        var error: String
        var id: String { "\(source)|\(directory)" }
    }

    @Published var extraDirs: [ExtraDir] = []

    /// Parse `--extra-status` JSON. Pure + static so it can be unit-tested.
    static func parseExtraDirs(_ json: String) -> [ExtraDir] {
        guard let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return arr.map {
            ExtraDir(source: $0["source"] as? String ?? "",
                     directory: $0["directory"] as? String ?? "",
                     installed: $0["installed"] as? Bool ?? false,
                     healthy: $0["healthy"] as? Bool ?? false,
                     bridgePresent: $0["bridgePresent"] as? Bool ?? false,
                     error: $0["error"] as? String ?? "")
        }
    }

    func refreshExtraDirs() {
        extraDirs = Self.parseExtraDirs(run(["--extra-status"]).stdout)
    }

    /// Register a directory and install its hooks. Returns an error string on
    /// failure (empty on success).
    @discardableResult
    func addExtraDir(_ source: String, _ path: String) -> String {
        let result = run(["--add-dir", source, path])
        guard let data = result.stdout.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return result.errorMessage
        }
        if obj["ok"] as? Bool == true {
            _ = run(["--only", source])   // install hooks into the new dir
            refreshExtraDirs()
            return ""
        }
        return obj["error"] as? String ?? "add-failed"
    }

    func removeExtraDir(_ source: String, _ path: String, removeHooks: Bool) {
        var args = ["--remove-dir", source, path]
        if removeHooks { args.append("--remove-hooks") }
        _ = run(args)
        refreshExtraDirs()
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        workingSource = id
        let result = run(enabled ? ["--only", id] : ["--only", id, "--remove"])
        workingSource = ""
        if result.status != 0 {
            failureMessage = result.errorMessage
            refresh()
            return
        }
        refresh()
    }

    func repair(_ id: String) {
        setEnabled(id, true)
    }

    /// Launch the Codex hook-trust flow. Codex persists hook trust in its own
    /// internal store (SQLite/rollout, hook-identity keyed) — writing it directly
    /// is fragile/risky, so we open a terminal running `codex`, which detects the
    /// new Atoll hooks and shows its "Trust hooks" prompt. One click to authorize.
    func openCodexTrust() {
        let script = """
        tell application "Terminal"
            activate
            do script "codex"
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String

        var errorMessage: String {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "集成脚本执行失败（退出码 \(status)）" : detail
        }
    }

    private func run(_ args: [String]) -> ProcessResult {
        guard FileManager.default.fileExists(atPath: script) else {
            return ProcessResult(status: 127, stdout: "", stderr: "找不到集成脚本：\(script)")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script] + args
        let stdout = Pipe()
        let stderr = Pipe()
        p.standardOutput = stdout
        p.standardError = stderr
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return ProcessResult(status: 126, stdout: "", stderr: error.localizedDescription)
        }
        return ProcessResult(
            status: p.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}
