import XCTest
@testable import Atoll

/// Unit tests for the per-source approval codecs and the held-request parser.
/// The wire formats are the highest-stakes part of approval routing (a wrong
/// response shape makes the CLI reject or ignore the decision), so they get
/// direct coverage instead of only the E2E self-test.
final class CodecTests: XCTestCase {
    private func pending(source: String = "claude", toolName: String = "Bash",
                         bashCommand: String = "") -> PendingRequest {
        PendingRequest(id: "p1", sessionKey: "s1", kind: .approval,
                       toolName: toolName, detailLines: [], questions: [], plan: "",
                       createdAt: Date(), bashCommand: bashCommand, source: source)
    }

    private func planPending() -> PendingRequest {
        PendingRequest(id: "p1", sessionKey: "s1", kind: .plan,
                       toolName: "ExitPlanMode", detailLines: [], questions: [],
                       plan: "1. 重构 2. 测试", createdAt: Date(), source: "claude")
    }

    private func questionPending() -> PendingRequest {
        PendingRequest(id: "p1", sessionKey: "s1", kind: .question,
                       toolName: "AskUserQuestion",
                       detailLines: [],
                       questions: [PendingQuestion(id: 0, question: "选框架?",
                                                  header: "", multiSelect: false,
                                                  options: [QuestionOption(label: "Vue", description: ""),
                                                            QuestionOption(label: "React", description: "")])],
                       plan: "", createdAt: Date(), source: "claude")
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Held-request parsing

    private func heldForm(_ payload: [String: Any]) -> [String: String] {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return ["hold": "1", "payload": String(data: data, encoding: .utf8)!]
    }

    func testPendingParsesPermissionRequest() throws {
        let req = try XCTUnwrap(ClaudeCodec.pending(form: heldForm([
            "hook_event_name": "PermissionRequest", "session_id": "s1",
            "tool_name": "Bash", "tool_use_id": "tu-9",
            "tool_input": ["command": "git push"]])))
        XCTAssertEqual(req.kind, .approval)
        XCTAssertEqual(req.sessionKey, "s1")
        XCTAssertEqual(req.toolName, "Bash")
        XCTAssertEqual(req.toolUseID, "tu-9")
        XCTAssertEqual(req.bashCommand, "git push")
        XCTAssertEqual(req.alwaysAllowRuleContent, "git:*")
    }

    func testPendingParsesExitPlanMode() throws {
        let req = try XCTUnwrap(ClaudeCodec.pending(form: heldForm([
            "hook_event_name": "PermissionRequest", "session_id": "s1",
            "tool_name": "ExitPlanMode", "tool_input": ["plan": "分三步重构"]])))
        XCTAssertEqual(req.kind, .plan)
        XCTAssertEqual(req.plan, "分三步重构")
    }

    func testPendingParsesAskUserQuestion() throws {
        let payload: [String: Any] = [
            "hook_event_name": "PreToolUse",
            "session_id": "s1",
            "tool_name": "AskUserQuestion",
            "tool_input": [
                "questions": [
                    [
                        "question": "数据库?",
                        "header": "依赖",
                        "multiSelect": true,
                        "options": [
                            ["label": "Postgres", "description": ""],
                            ["label": "MySQL", "description": ""],
                        ],
                    ],
                ],
            ],
        ]
        let req = try XCTUnwrap(ClaudeCodec.pending(form: heldForm(payload)))
        XCTAssertEqual(req.kind, .question)
        XCTAssertEqual(req.questions.count, 1)
        let q = req.questions[0]
        XCTAssertEqual(q.question, "数据库?")
        XCTAssertTrue(q.multiSelect)
        XCTAssertEqual(q.options.map(\.label), ["Postgres", "MySQL"])
    }

    func testPendingRequiresHoldFlag() {
        let form = heldForm(["hook_event_name": "PermissionRequest",
                             "session_id": "s1", "tool_name": "Bash"])
        let noHold = ["payload": form["payload"]!]
        XCTAssertNil(ClaudeCodec.pending(form: noHold))
    }

    func testPendingRequiresSessionID() {
        XCTAssertNil(ClaudeCodec.pending(form: heldForm([
            "hook_event_name": "PermissionRequest", "tool_name": "Bash"])))
    }

    func testPendingIgnoresNonInteractivePreToolUse() {
        XCTAssertNil(ClaudeCodec.pending(form: heldForm([
            "hook_event_name": "PreToolUse", "session_id": "s1",
            "tool_name": "Bash", "tool_input": ["command": "ls"]])))
    }

    // MARK: - Claude wire format

    func testClaudeAllow() throws {
        let obj = try decode(ClaudeCodec.encode(.allow, for: pending()))
        let hook = try XCTUnwrap(obj["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(hook["hookEventName"] as? String, "PermissionRequest")
        let decision = try XCTUnwrap(hook["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
    }

    func testClaudeAlwaysAllowAddsSessionRule() throws {
        let obj = try decode(ClaudeCodec.encode(.alwaysAllow, for: pending(bashCommand: "git status")))
        let hook = try XCTUnwrap(obj["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hook["decision"] as? [String: Any])
        let perms = try XCTUnwrap(decision["updatedPermissions"] as? [[String: Any]])
        XCTAssertEqual(perms.first?["type"] as? String, "addRules")
        XCTAssertEqual(perms.first?["destination"] as? String, "session")
        let rules = try XCTUnwrap(perms.first?["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.first?["toolName"] as? String, "Bash")
        XCTAssertEqual(rules.first?["ruleContent"] as? String, "git:*")
    }

    func testClaudeAlwaysAllowWithoutBashHasNoRuleContent() throws {
        let obj = try decode(ClaudeCodec.encode(.alwaysAllow, for: pending(toolName: "Read")))
        let hook = try XCTUnwrap(obj["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hook["decision"] as? [String: Any])
        let perms = try XCTUnwrap(decision["updatedPermissions"] as? [[String: Any]])
        let rules = try XCTUnwrap(perms.first?["rules"] as? [[String: Any]])
        XCTAssertNil(rules.first?["ruleContent"], "non-Bash tools get a plain tool rule")
        XCTAssertEqual(rules.first?["toolName"] as? String, "Read")
    }

    func testClaudePlanAllowSetsPermissionMode() throws {
        let obj = try decode(ClaudeCodec.encode(.planAllow(mode: "auto"), for: planPending()))
        let hook = try XCTUnwrap(obj["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hook["decision"] as? [String: Any])
        let perms = try XCTUnwrap(decision["updatedPermissions"] as? [[String: Any]])
        XCTAssertEqual(perms.first?["type"] as? String, "setMode")
        XCTAssertEqual(perms.first?["mode"] as? String, "auto")
    }

    func testClaudeDenyCarriesReason() throws {
        let obj = try decode(ClaudeCodec.encode(.deny(reason: "不要这么做"), for: pending()))
        let hook = try XCTUnwrap(obj["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hook["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "deny")
        XCTAssertEqual(decision["message"] as? String, "不要这么做")
    }

    func testClaudeDenyWithoutReasonOmitsMessage() throws {
        let obj = try decode(ClaudeCodec.encode(.deny(reason: ""), for: pending()))
        let hook = try XCTUnwrap(obj["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hook["decision"] as? [String: Any])
        XCTAssertNil(decision["message"])
    }

    func testClaudePlanFeedbackDeniesWithMessage() throws {
        let obj = try decode(ClaudeCodec.encode(.planFeedback("先修 bug"), for: planPending()))
        let hook = try XCTUnwrap(obj["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hook["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "deny")
        XCTAssertEqual(decision["message"] as? String, "先修 bug")
    }

    func testClaudeQuestionAnswersBecomeDenyWithReason() throws {
        let obj = try decode(ClaudeCodec.encode(.answers([0: ["Vue"]]), for: questionPending()))
        let hook = try XCTUnwrap(obj["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(hook["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(hook["permissionDecision"] as? String, "deny")
        let reason = hook["permissionDecisionReason"] as? String ?? ""
        XCTAssertTrue(reason.contains("选框架?"), "reason must carry the question")
        XCTAssertTrue(reason.contains("Vue"), "reason must carry the picked answer")
    }

    func testClaudeQuestionDeny() throws {
        let obj = try decode(ClaudeCodec.encode(.deny(reason: ""), for: questionPending()))
        let hook = try XCTUnwrap(obj["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(hook["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(hook["permissionDecision"] as? String, "deny")
    }

    // MARK: - Codex wire format

    func testCodexAllowUsesOfficialStructureWithoutUpdatedPermissions() throws {
        let data = CodexCodec.encode(.allow, for: pending(source: "codex"))
        let obj = try decode(data)
        XCTAssertEqual(obj["continue"] as? Bool, true, "Codex expects a top-level continue flag")
        let hook = try XCTUnwrap(obj["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(hook["hookEventName"] as? String, "PermissionRequest")
        let decision = try XCTUnwrap(hook["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        // Codex does not support updatedPermissions — its presence would break
        // the schema (verified in agent-protocol research).
        XCTAssertNil(hook["updatedPermissions"])
        XCTAssertNil(decision["updatedPermissions"])
    }

    func testCodexAlwaysAllowStaysPlainAllow() throws {
        let obj = try decode(CodexCodec.encode(.alwaysAllow, for: pending(source: "codex", bashCommand: "git push")))
        let hook = try XCTUnwrap(obj["hookSpecificOutput"] as? [String: Any])
        XCTAssertNil(hook["updatedPermissions"], "always-allow must not leak Claude rules into Codex")
    }

    func testCodexDenyCarriesMessage() throws {
        let obj = try decode(CodexCodec.encode(.deny(reason: "拒绝"), for: pending(source: "codex")))
        let hook = try XCTUnwrap(obj["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hook["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "deny")
        XCTAssertEqual(decision["message"] as? String, "拒绝")
    }

    func testCodexResponseEndsWithNewline() {
        let data = CodexCodec.encode(.allow, for: pending(source: "codex"))
        XCTAssertEqual(data.last, 0x0A, "Codex expects newline-terminated JSON")
    }

    func testCodexQuestionAnswersProduceNoResponse() {
        // Codex has no AskUserQuestion hook path — answers must not fabricate
        // a Claude-shaped reply.
        let data = CodexCodec.encode(.answers([0: ["a"]]), for: pending(source: "codex"))
        XCTAssertTrue(data.isEmpty)
    }

    func testHookDecisionCodecRoutesBySource() throws {
        let codex = try decode(HookDecisionCodec.encode(.allow, for: pending(source: "codex")))
        XCTAssertNotNil(codex["continue"], "codex requests go through the Codex codec")
        let claude = try decode(HookDecisionCodec.encode(.allow, for: pending(source: "claude")))
        XCTAssertNil(claude["continue"], "claude requests keep the Claude shape")
    }
}
