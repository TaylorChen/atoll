import Foundation

// MARK: - Pending interactive requests (approval / question / plan review)

struct QuestionOption: Codable, Identifiable, Hashable {
    var id: String { label }
    let label: String
    let description: String
}

struct PendingQuestion: Codable, Identifiable {
    let id: Int
    let question: String
    let header: String
    let multiSelect: Bool
    let options: [QuestionOption]
}

enum PendingKind: String, Codable {
    case approval   // PermissionRequest
    case question   // PreToolUse AskUserQuestion (held)
    case plan       // PermissionRequest for ExitPlanMode
}

struct PendingRequest: Codable, Identifiable {
    let id: String
    let sessionKey: String
    let kind: PendingKind
    let toolName: String
    let detailLines: [String]
    let questions: [PendingQuestion]
    let plan: String
    let createdAt: Date
    var bashCommand: String = ""   // for always-allow rule derivation
    var source: String = "claude"
    var toolUseID: String = ""

    /// "Bash(git:*)"-style prefix rule for Bash; nil = plain tool rule.
    var alwaysAllowRuleContent: String? {
        guard toolName == "Bash", let word = bashCommand.split(separator: " ").first,
              !word.isEmpty else { return nil }
        return "\(word):*"
    }
}

enum Decision {
    case allow
    case alwaysAllow                // allow + session-scoped permission rule
    case planAllow(mode: String)    // ExitPlanMode: approve + switch permission mode
    case deny(reason: String)
    case answers([Int: [String]])   // question index → selected labels
    case planFeedback(String)
}

// MARK: - Claude-specific wire formats

enum ClaudeCodec {
    /// Build the hook response JSON the CLI expects for a resolved pending request.
    static func encode(_ decision: Decision, for pending: PendingRequest) -> Data {
        let obj: [String: Any]
        switch (pending.kind, decision) {
        case (.question, .answers(let answers)):
            // AskUserQuestion cannot be answered via hooks directly; deny the tool
            // call and hand the model the user's answers as the denial reason.
            var parts: [String] = []
            for q in pending.questions {
                let picked = (answers[q.id] ?? []).joined(separator: "、")
                parts.append("「\(q.question)」→ \(picked)")
            }
            let reason = "用户已在 Atoll 面板回答（请直接按此答案继续，不要再次调用 AskUserQuestion 重复提问）：" + parts.joined(separator: "；")
            obj = ["hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            ]]
        case (.question, .deny(let reason)):
            obj = ["hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason.isEmpty ? "用户在 Atoll 面板拒绝了提问" : reason,
            ]]
        case (_, .allow):
            obj = ["hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "allow"],
            ]]
        case (_, .alwaysAllow):
            // Session-scoped rule: this tool (with a command-prefix rule for Bash)
            // is auto-allowed for the rest of the session.
            var rule: [String: Any] = ["toolName": pending.toolName]
            if let content = pending.alwaysAllowRuleContent { rule["ruleContent"] = content }
            obj = ["hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": [
                    "behavior": "allow",
                    "updatedPermissions": [
                        ["type": "addRules", "rules": [rule], "behavior": "allow", "destination": "session"]
                    ],
                ],
            ]]
        case (_, .planAllow(let mode)):
            // Plan approval must also switch the session's permission mode
            // (mirrors the terminal's "Yes, and use auto mode" / "manually approve").
            obj = ["hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": [
                    "behavior": "allow",
                    "updatedPermissions": [
                        ["type": "setMode", "mode": mode, "destination": "session"]
                    ],
                ],
            ]]
        case (.plan, .planFeedback(let text)):
            obj = ["hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "deny", "message": text],
            ]]
        case (_, .deny(let reason)):
            var d: [String: Any] = ["behavior": "deny"]
            if !reason.isEmpty { d["message"] = reason }
            obj = ["hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": d,
            ]]
        default:
            obj = [:]
        }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    /// Parse a held hook payload into a PendingRequest, or nil if not interactive.
    static func pending(form: [String: String], source: String = "claude") -> PendingRequest? {
        guard form["hold"] == "1",
              let payloadStr = form["payload"],
              let payloadData = payloadStr.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any],
              let sessionID = payload["session_id"] as? String
        else { return nil }

        let eventName = payload["hook_event_name"] as? String ?? ""
        let toolName = payload["tool_name"] as? String ?? "?"
        let toolUseID = payload["tool_use_id"] as? String ?? ""
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        let id = UUID().uuidString

        if eventName == "PreToolUse", toolName == "AskUserQuestion" {
            var questions: [PendingQuestion] = []
            for (i, q) in ((input["questions"] as? [[String: Any]]) ?? []).enumerated() {
                let options = ((q["options"] as? [[String: Any]]) ?? []).map {
                    QuestionOption(label: $0["label"] as? String ?? "",
                                   description: $0["description"] as? String ?? "")
                }
                questions.append(PendingQuestion(
                    id: i,
                    question: q["question"] as? String ?? "",
                    header: q["header"] as? String ?? "",
                    multiSelect: q["multiSelect"] as? Bool ?? false,
                    options: options))
            }
            guard !questions.isEmpty else { return nil }
            return PendingRequest(id: id, sessionKey: sessionID, kind: .question,
                                  toolName: toolName, detailLines: [], questions: questions,
                                  plan: "", createdAt: Date(), source: source, toolUseID: toolUseID)
        }

        if eventName == "PermissionRequest" {
            // Show every held PermissionRequest — if the hook fired and is
            // waiting, the agent genuinely wants a decision (regardless of
            // permission mode). Auto-resolved ones are dropped by the gateway's
            // short grace delay / the PreToolUse-proceeds cleanup in the store.
            if toolName == "ExitPlanMode" {
                return PendingRequest(id: id, sessionKey: sessionID, kind: .plan,
                                      toolName: toolName, detailLines: [], questions: [],
                                      plan: input["plan"] as? String ?? "", createdAt: Date(),
                                      source: source, toolUseID: toolUseID)
            }
            return PendingRequest(id: id, sessionKey: sessionID, kind: .approval,
                                  toolName: toolName, detailLines: detailLines(toolName, input),
                                  questions: [], plan: "", createdAt: Date(),
                                  bashCommand: input["command"] as? String ?? "", source: source,
                                  toolUseID: toolUseID)
        }
        return nil
    }

    private static func detailLines(_ tool: String, _ input: [String: Any]) -> [String] {
        func short(_ s: String?, _ n: Int = 200) -> String {
            let home = NSHomeDirectory()
            var v = s ?? ""
            if v.hasPrefix(home) { v = "~" + v.dropFirst(home.count) }
            return String(v.prefix(n))
        }
        switch tool {
        case "Bash":
            return [short(input["command"] as? String, 500)]
        case "Read":
            // Show the first lines of the file being requested.
            var lines = [short(input["file_path"] as? String)]
            if let path = input["file_path"] as? String,
               let content = try? String(contentsOfFile: path, encoding: .utf8) {
                let preview = content.components(separatedBy: "\n").prefix(8)
                lines.append(contentsOf: preview.enumerated().map { "\($0.offset + 1)  \(String($0.element.prefix(90)))" })
            }
            return lines
        case "Edit":
            var lines = [short(input["file_path"] as? String)]
            if let old = input["old_string"] as? String { lines.append("- " + short(old, 150)) }
            if let new = input["new_string"] as? String { lines.append("+ " + short(new, 150)) }
            return lines
        case "Write":
            let content = input["content"] as? String ?? ""
            return [short(input["file_path"] as? String), "新内容 \(content.count) 字符"]
        default:
            if let data = try? JSONSerialization.data(withJSONObject: input),
               let str = String(data: data, encoding: .utf8) {
                return [short(str, 300)]
            }
            return []
        }
    }
}

/// Codex's PermissionRequest response is deliberately separate from the
/// Claude-family codec. Keeping the wire formats source-specific prevents a
/// compatible-looking Claude response from drifting away from Codex's schema.
enum HookDecisionCodec {
    static func encode(_ decision: Decision, for pending: PendingRequest) -> Data {
        pending.source == "codex"
            ? CodexCodec.encode(decision, for: pending)
            : ClaudeCodec.encode(decision, for: pending)
    }
}

enum CodexCodec {
    static func encode(_ decision: Decision, for pending: PendingRequest) -> Data {
        let behavior: String
        var message: String?

        switch decision {
        case .allow, .alwaysAllow, .planAllow:
            behavior = "allow"
        case .deny(let reason):
            behavior = "deny"
            message = reason.isEmpty ? nil : reason
        case .planFeedback(let text):
            behavior = "deny"
            message = text.isEmpty ? nil : text
        case .answers:
            return Data()
        }

        var wireDecision: [String: Any] = ["behavior": behavior]
        if let message { wireDecision["message"] = message }
        let object: [String: Any] = [
            "continue": true,
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": wireDecision,
            ],
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return Data() }
        data.append(0x0A)
        return data
    }
}
