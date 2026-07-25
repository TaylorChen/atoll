import Foundation

// MARK: - Normalization

enum EventKind {
    case sessionStart, prompt, toolUse, toolResult, toolFailure
    case compactStart, stop, stopFailure, subagentStart, subagentStop, sessionEnd, other
}

struct NormalizedEvent {
    var source: String
    let sessionKey: String
    let kind: EventKind
    let cwd: String
    let tty: String
    var model: String = ""
    var toolName: String = ""
    var verb: String = ""
    var detail: String = ""
    var transcriptPath: String = ""
    var todos: (done: Int, inProgress: Int, pending: Int)?
    var host: String = ""
    var toolUseID: String = ""
}

enum Normalizer {
    static func normalize(source: String, form: [String: String]) -> NormalizedEvent? {
        var event: NormalizedEvent?
        switch source {
        case "claude": event = claude(form: form)
        case "codex", "qoder", "qwen", "factory", "codebuddy", "kimi":
            event = claudeClone(source: source, form: form)
        case "gemini": event = gemini(form: form)
        case "cursor": event = cursor(form: form)
        case "opencode": event = claudeClone(source: source, form: form)
        default:
            logUnparsed(source: source, form: form)
            return nil
        }
        event?.host = form["host"] ?? ""   // set by the SSH remote bridge
        return event
    }

    /// Claude-compatible agents reuse the parser but retain their source ID.
    static func claudeClone(source: String, form: [String: String]) -> NormalizedEvent? {
        guard var ev = claude(form: form) else {
            logUnparsed(source: source, form: form)
            return nil
        }
        ev.source = source
        return ev
    }

    /// Cursor Agent: flat camelCase hooks with a Cursor-specific payload.
    /// Defensive parsing — unknown shapes are logged for later refinement.
    static func cursor(form: [String: String]) -> NormalizedEvent? {
        guard let payloadStr = form["payload"],
              let data = payloadStr.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { logUnparsed(source: "cursor", form: form); return nil }

        let eventName = (payload["hook_event_name"] as? String) ?? (payload["event"] as? String) ?? ""
        let sessionKey = (payload["conversation_id"] as? String)
            ?? (payload["generation_id"] as? String)
            ?? (payload["session_id"] as? String) ?? ""
        guard !sessionKey.isEmpty else { logUnparsed(source: "cursor", form: form); return nil }
        let roots = payload["workspace_roots"] as? [String]
        let cwd = roots?.first ?? (payload["cwd"] as? String) ?? form["cwd"] ?? ""
        let tty = form["tty"] ?? ""

        func short(_ s: String?, _ n: Int = 80) -> String {
            guard let s else { return "" }
            let home = NSHomeDirectory()
            let v = s.hasPrefix(home) ? "~" + s.dropFirst(home.count) : s
            return String(v.prefix(n))
        }

        var kind: EventKind = .other
        var verb = "", detail = "", toolName = ""
        switch eventName {
        case "beforeSubmitPrompt":
            kind = .prompt; detail = String((payload["prompt"] as? String ?? "").prefix(120))
        case "preToolUse", "beforeShellExecution":
            kind = .toolUse; toolName = payload["tool_name"] as? String ?? "Shell"
            verb = "运行中"; detail = short(payload["command"] as? String ?? (payload["tool_input"] as? [String: Any])?["command"] as? String)
        case "beforeReadFile":
            kind = .toolUse; toolName = "Read"; verb = "读取中"; detail = short(payload["file_path"] as? String)
        case "afterFileEdit":
            kind = .toolResult; toolName = "Edit"; detail = short(payload["file_path"] as? String)
        case "afterShellExecution":
            kind = .toolResult; toolName = "Shell"
        case "postToolUse", "afterMCPExecution":
            kind = .toolResult
        case "postToolUseFailure":
            kind = .toolFailure
        case "stop", "afterAgentResponse":
            kind = .stop
        case "subagentStart": kind = .subagentStart
        case "subagentStop": kind = .subagentStop
        default:
            logUnparsed(source: "cursor", form: form)
        }
        return NormalizedEvent(source: "cursor", sessionKey: sessionKey, kind: kind,
                               cwd: cwd, tty: tty, toolName: toolName, verb: verb, detail: detail)
    }

    /// Gemini CLI: minimal monitoring via BeforeAgent/AfterAgent.
    static func gemini(form: [String: String]) -> NormalizedEvent? {
        guard let payloadStr = form["payload"],
              let data = payloadStr.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            logUnparsed(source: "gemini", form: form)
            return nil
        }
        let cwd = payload["cwd"] as? String ?? form["cwd"] ?? ""
        let tty = form["tty"] ?? ""
        // Gemini payloads may lack a session id; derive a stable key.
        let sessionKey = (payload["session_id"] as? String)
            ?? "gemini-\(cwd)-\(tty)".hashValue.description
        let eventName = (payload["hook_event_name"] as? String)
            ?? (payload["event"] as? String) ?? ""
        var kind: EventKind = .other
        var detail = ""
        switch eventName {
        case "BeforeAgent":
            kind = .prompt
            detail = String(((payload["prompt"] as? String) ?? "").prefix(120))
        case "AfterAgent":
            kind = .stop
        default:
            logUnparsed(source: "gemini", form: form)
        }
        return NormalizedEvent(source: "gemini", sessionKey: sessionKey, kind: kind,
                               cwd: cwd, tty: tty, detail: detail)
    }

    /// Opt-in schema-drift safety net: capture unparsed payloads for adapter
    /// refinement. Off by default — enable with `defaults write Atoll debugUnparsed
    /// -bool true`. Payloads may contain prompt text, so this is user-gated and
    /// truncated, written 0600, and stays local.
    private static func logUnparsed(source: String, form: [String: String]) {
        guard UserDefaults.standard.bool(forKey: "debugUnparsed") else { return }
        let path = NSString(string: "~/.atoll/debug-unparsed.log").expandingTildeInPath
        let payload = String((form["payload"] ?? "").prefix(500))
        let line = "[\(Date())] source=\(source) payload=\(payload)\n"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(Data(line.utf8))
            try? fh.close()
        }
    }

    /// Claude Code hook payload → NormalizedEvent.
    /// Unknown event names map to .other so schema drift never crashes the pipeline.
    static func claude(form: [String: String]) -> NormalizedEvent? {
        guard let payloadStr = form["payload"],
              let payloadData = payloadStr.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any]
        else { return nil }

        let eventName = payload["hook_event_name"] as? String ?? ""
        let sessionID = payload["session_id"] as? String ?? ""
        guard !sessionID.isEmpty else { return nil }
        let cwd = payload["cwd"] as? String ?? form["cwd"] ?? ""
        let tty = form["tty"] ?? ""
        let model = ((payload["model"] as? [String: Any])?["display_name"] as? String) ?? ""
        let transcriptPath = payload["transcript_path"] as? String ?? ""
        let toolUseID = payload["tool_use_id"] as? String ?? ""

        var kind: EventKind = .other
        var toolName = ""
        var verb = ""
        var detail = ""
        var todos: (done: Int, inProgress: Int, pending: Int)?

        switch eventName {
        case "SessionStart": kind = .sessionStart
        case "UserPromptSubmit":
            kind = .prompt
            detail = String((payload["prompt"] as? String ?? "").prefix(120))
        case "PreToolUse":
            kind = .toolUse
            toolName = payload["tool_name"] as? String ?? "?"
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            (verb, detail) = describeTool(toolName, input: input)
            if toolName == "TodoWrite", let items = input["todos"] as? [[String: Any]] {
                var d = 0, ip = 0, p = 0
                for item in items {
                    switch item["status"] as? String {
                    case "completed": d += 1
                    case "in_progress": ip += 1
                    default: p += 1
                    }
                }
                todos = (d, ip, p)
            }
        case "PostToolUse":
            kind = .toolResult
            toolName = payload["tool_name"] as? String ?? ""
            detail = summarizeResult(toolName, payload["tool_response"])
        case "PostToolUseFailure": kind = .toolFailure
        case "PreCompact": kind = .compactStart
        case "Stop":
            kind = .stop
            if let path = payload["transcript_path"] as? String {
                detail = lastAssistantMessage(transcriptPath: path)
            }
        case "StopFailure": kind = .stopFailure
        case "SubagentStart": kind = .subagentStart
        case "SubagentStop": kind = .subagentStop
        case "SessionEnd": kind = .sessionEnd
        default: kind = .other
        }

        return NormalizedEvent(source: "claude", sessionKey: sessionID, kind: kind,
                               cwd: cwd, tty: tty, model: model,
                               toolName: toolName, verb: verb, detail: detail,
                               transcriptPath: transcriptPath, todos: todos,
                               toolUseID: toolUseID)
    }

    /// Recent conversation excerpt from a transcript.
    static func recentMessages(transcriptPath: String, limit: Int = 6) -> [(role: String, text: String)] {
        guard let fh = FileHandle(forReadingAtPath: transcriptPath) else { return [] }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let maxTailBytes: UInt64 = 4 * 1_024 * 1_024
        let readFrom = size > maxTailBytes ? size - maxTailBytes : 0
        try? fh.seek(toOffset: readFrom)
        guard let data = try? fh.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [(String, String)] = []
        for line in text.components(separatedBy: "\n").reversed() {
            guard out.count < limit,
                  let d = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            else { continue }
            let role: String
            let msg: [String: Any]
            if let type = obj["type"] as? String,
               type == "assistant" || type == "user",
               let message = obj["message"] as? [String: Any] {
                role = type
                msg = message
            } else if obj["type"] as? String == "response_item",
                      let payload = obj["payload"] as? [String: Any],
                      payload["type"] as? String == "message",
                      let payloadRole = payload["role"] as? String,
                      payloadRole == "assistant" || payloadRole == "user" {
                role = payloadRole
                msg = payload
            } else {
                continue
            }
            var textParts: [String] = []
            if let content = msg["content"] as? [[String: Any]] {
                for block in content where ["text", "input_text", "output_text"]
                    .contains(block["type"] as? String ?? "") {
                    if let t = block["text"] as? String { textParts.append(t) }
                }
            } else if let s = msg["content"] as? String {
                textParts.append(s)
            }
            let joined = textParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joined.isEmpty, !joined.hasPrefix("<") else { continue }  // skip tool/system noise
            out.append((role, String(joined.prefix(220))))
        }
        return out.reversed()
    }

    /// Compact tool result summary ("└ 3 passed", "1.2 KB").
    private static func summarizeResult(_ tool: String, _ response: Any?) -> String {
        func kb(_ n: Int) -> String {
            n < 1024 ? "\(n) B" : String(format: "%.1f KB", Double(n) / 1024)
        }
        if let s = response as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "" }
            let lines = trimmed.components(separatedBy: "\n")
            return lines.count > 1 ? "\(kb(trimmed.count)) · \(lines.count) 行" : String(trimmed.prefix(60))
        }
        guard let dict = response as? [String: Any] else { return "" }
        if let stdout = dict["stdout"] as? String {
            let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if let first = out.components(separatedBy: "\n").last, !first.isEmpty {
                return String(first.prefix(60))
            }
            return (dict["stderr"] as? String)?.isEmpty == false ? "stderr 有输出" : "无输出"
        }
        if let file = dict["file"] as? [String: Any], let content = file["content"] as? String {
            return "\(kb(content.count)) · \(content.components(separatedBy: "\n").count) 行"
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            return kb(data.count)
        }
        return ""
    }

    /// Tail-read the session transcript for the last assistant text message.
    private static func lastAssistantMessage(transcriptPath: String) -> String {
        guard let fh = FileHandle(forReadingAtPath: transcriptPath) else { return "" }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let readFrom = size > 131_072 ? size - 131_072 : 0
        try? fh.seek(toOffset: readFrom)
        guard let data = try? fh.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return "" }
        for line in text.components(separatedBy: "\n").reversed() {
            guard let d = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { continue }
            for block in content where block["type"] as? String == "text" {
                if let t = block["text"] as? String, !t.isEmpty {
                    return String(t.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
                }
            }
        }
        return ""
    }

    private static func describeTool(_ name: String, input: [String: Any]) -> (String, String) {
        func short(_ s: String?) -> String {
            guard let s, !s.isEmpty else { return "" }
            let home = NSHomeDirectory()
            let abbreviated = s.hasPrefix(home) ? "~" + s.dropFirst(home.count) : s
            return String(abbreviated.prefix(80))
        }
        switch name {
        case "Read": return ("读取中", short(input["file_path"] as? String))
        case "Edit", "NotebookEdit": return ("编辑中", short(input["file_path"] as? String))
        case "Write": return ("写入中", short(input["file_path"] as? String))
        case "Bash": return ("运行中", short(input["command"] as? String))
        case "Grep", "Glob": return ("搜索中", short((input["pattern"] as? String) ?? (input["query"] as? String)))
        case "WebFetch", "WebSearch": return ("获取中", short((input["url"] as? String) ?? (input["query"] as? String)))
        case "Task", "Agent": return ("任务中", short(input["description"] as? String))
        case "Skill": return ("运行技能", short(input["skill"] as? String))
        default: return ("工作中", short(nil))
        }
    }
}
