import XCTest
@testable import Atoll

/// Unit tests for the hook-payload → NormalizedEvent layer. This is the most
/// schema-drift-prone part of the pipeline and previously had no direct tests
/// (only indirect E2E coverage via self-test.sh, which needs a live app).
final class NormalizerTests: XCTestCase {
    /// Build the form dictionary the bridge forwards to the gateway.
    private func hookForm(_ payload: [String: Any], host: String? = nil) -> [String: String] {
        var form: [String: String] = [:]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let str = String(data: data, encoding: .utf8) {
            form["payload"] = str
        }
        if let host { form["host"] = host }
        return form
    }

    // MARK: - Claude

    func testClaudeSessionStart() throws {
        let ev = try XCTUnwrap(Normalizer.normalize(source: "claude", form: hookForm([
            "hook_event_name": "SessionStart", "session_id": "s1", "cwd": "/tmp"])))
        XCTAssertEqual(ev.source, "claude")
        XCTAssertEqual(ev.sessionKey, "s1")
        XCTAssertEqual(ev.cwd, "/tmp")
        XCTAssertEqual(ev.kind, .sessionStart)
    }

    func testClaudeUserPrompt() throws {
        let ev = try XCTUnwrap(Normalizer.normalize(source: "claude", form: hookForm([
            "hook_event_name": "UserPromptSubmit", "session_id": "s1",
            "prompt": "实现登录页"])))
        XCTAssertEqual(ev.kind, .prompt)
        XCTAssertEqual(ev.detail, "实现登录页")
    }

    func testClaudePreToolUseBash() throws {
        let ev = try XCTUnwrap(Normalizer.normalize(source: "claude", form: hookForm([
            "hook_event_name": "PreToolUse", "session_id": "s1", "tool_name": "Bash",
            "tool_use_id": "tu-1",
            "tool_input": ["command": "swift test"]])))
        XCTAssertEqual(ev.kind, .toolUse)
        XCTAssertEqual(ev.toolName, "Bash")
        XCTAssertEqual(ev.verb, "运行中")
        XCTAssertEqual(ev.detail, "swift test")
        XCTAssertEqual(ev.toolUseID, "tu-1")
    }

    func testClaudeTodoWriteCounts() throws {
        let ev = try XCTUnwrap(Normalizer.normalize(source: "claude", form: hookForm([
            "hook_event_name": "PreToolUse", "session_id": "s1", "tool_name": "TodoWrite",
            "tool_input": ["todos": [
                ["status": "completed"], ["status": "in_progress"], ["status": "pending"]]]])))
        XCTAssertEqual(ev.todos?.done, 1)
        XCTAssertEqual(ev.todos?.inProgress, 1)
        XCTAssertEqual(ev.todos?.pending, 1)
    }

    func testClaudePostToolUseSummarizesStdout() throws {
        let ev = try XCTUnwrap(Normalizer.normalize(source: "claude", form: hookForm([
            "hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "Bash",
            "tool_response": ["stdout": "All tests passed", "stderr": ""]])))
        XCTAssertEqual(ev.kind, .toolResult)
        XCTAssertEqual(ev.detail, "All tests passed")
    }

    func testClaudeUnknownEventMapsToOther() throws {
        let ev = try XCTUnwrap(Normalizer.normalize(source: "claude", form: hookForm([
            "hook_event_name": "SomeFutureEvent", "session_id": "s1"])))
        XCTAssertEqual(ev.kind, .other)
    }

    func testClaudeMissingSessionIDReturnsNil() {
        XCTAssertNil(Normalizer.normalize(source: "claude", form: hookForm([
            "hook_event_name": "SessionStart", "cwd": "/tmp"])))
    }

    func testClaudeInvalidPayloadReturnsNil() {
        XCTAssertNil(Normalizer.normalize(source: "claude", form: ["payload": "not json"]))
    }

    func testClaudeStopReadsLastAssistantMessageFromTranscript() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("atoll-transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("transcript.jsonl")
        let lines = [
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"world reply"}]}}"#,
            #"{"type":"system","message":{"role":"system","content":[{"type":"text","text":"noise"}]}}"#,
        ]
        try lines.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

        // recentMessages: chronological, system noise skipped.
        let messages = Normalizer.recentMessages(transcriptPath: transcript.path, limit: 6)
        XCTAssertEqual(messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(messages.first?.text, "hello")
        XCTAssertEqual(messages.last?.text, "world reply")

        // Stop hook surfaces the last assistant message as the detail.
        let ev = try XCTUnwrap(Normalizer.normalize(source: "claude", form: hookForm([
            "hook_event_name": "Stop", "session_id": "s1", "transcript_path": transcript.path])))
        XCTAssertEqual(ev.kind, .stop)
        XCTAssertEqual(ev.detail, "world reply")
    }

    func testClaudeStopWithoutTranscriptIsSafe() throws {
        let ev = try XCTUnwrap(Normalizer.normalize(source: "claude", form: hookForm([
            "hook_event_name": "Stop", "session_id": "s1"])))
        XCTAssertEqual(ev.kind, .stop)
        XCTAssertEqual(ev.detail, "")
    }

    // MARK: - Claude-compatible clones

    func testClaudeClonePreservesSourceID() throws {
        for source in ["qwen", "factory", "codebuddy", "kimi", "opencode"] {
            let ev = try XCTUnwrap(Normalizer.normalize(source: source, form: hookForm([
                "hook_event_name": "SessionStart", "session_id": "s-\(source)"])))
            XCTAssertEqual(ev.source, source, "source id must survive normalization")
            XCTAssertEqual(ev.sessionKey, "s-\(source)")
        }
    }

    // MARK: - Cursor (flat format)

    func testCursorPrompt() throws {
        let ev = try XCTUnwrap(Normalizer.normalize(source: "cursor", form: hookForm([
            "hook_event_name": "beforeSubmitPrompt", "conversation_id": "c1",
            "prompt": "重构", "workspace_roots": ["/repo"]])))
        XCTAssertEqual(ev.source, "cursor")
        XCTAssertEqual(ev.sessionKey, "c1")
        XCTAssertEqual(ev.kind, .prompt)
        XCTAssertEqual(ev.cwd, "/repo")
    }

    func testCursorPreToolUse() throws {
        let ev = try XCTUnwrap(Normalizer.normalize(source: "cursor", form: hookForm([
            "hook_event_name": "preToolUse", "conversation_id": "c1",
            "tool_name": "Shell", "command": "npm test"])))
        XCTAssertEqual(ev.kind, .toolUse)
        XCTAssertEqual(ev.toolName, "Shell")
        XCTAssertEqual(ev.detail, "npm test")
    }

    func testCursorUnknownEventStillProducesEvent() throws {
        let ev = try XCTUnwrap(Normalizer.normalize(source: "cursor", form: hookForm([
            "hook_event_name": "futureEvent", "conversation_id": "c1"])))
        XCTAssertEqual(ev.kind, .other)
    }

    func testCursorMissingSessionKeyReturnsNil() {
        XCTAssertNil(Normalizer.normalize(source: "cursor", form: hookForm([
            "hook_event_name": "beforeSubmitPrompt"])))
    }

    // MARK: - Gemini

    func testGeminiUsesProvidedSessionID() throws {
        let ev = try XCTUnwrap(Normalizer.normalize(source: "gemini", form: hookForm([
            "hook_event_name": "BeforeAgent", "session_id": "g-1", "cwd": "/repo", "prompt": "hi"])))
        XCTAssertEqual(ev.sessionKey, "g-1")
        XCTAssertEqual(ev.kind, .prompt)
        XCTAssertEqual(ev.detail, "hi")
    }

    func testGeminiAfterAgentIsStop() throws {
        let ev = try XCTUnwrap(Normalizer.normalize(source: "gemini", form: hookForm([
            "hook_event_name": "AfterAgent", "cwd": "/repo", "tty": "/dev/ttys001"])))
        XCTAssertEqual(ev.kind, .stop)
    }

    func testStableSessionKeyIsDeterministicAndDistinct() {
        let a = Normalizer.stableSessionKey(cwd: "/repo", tty: "/dev/ttys001")
        let b = Normalizer.stableSessionKey(cwd: "/repo", tty: "/dev/ttys001")
        XCTAssertEqual(a, b, "same cwd+tty must derive the same key every call")
        XCTAssertTrue(a.hasPrefix("gemini-"))
        XCTAssertEqual(a.count, "gemini-".count + 24, "12 bytes → 24 hex chars")

        let other = Normalizer.stableSessionKey(cwd: "/repo2", tty: "/dev/ttys001")
        XCTAssertNotEqual(a, other, "different cwd must derive a different key")
        let otherTTY = Normalizer.stableSessionKey(cwd: "/repo", tty: "/dev/ttys002")
        XCTAssertNotEqual(a, otherTTY, "different tty must derive a different key")
    }

    // MARK: - Host propagation

    func testRemoteHostPropagatesToEvent() throws {
        let ev = try XCTUnwrap(Normalizer.normalize(source: "claude", form: hookForm(
            ["hook_event_name": "SessionStart", "session_id": "s1"], host: "remote-box")))
        XCTAssertEqual(ev.host, "remote-box")
    }

    // MARK: - Unknown source

    func testUnknownSourceReturnsNil() {
        XCTAssertNil(Normalizer.normalize(source: "unknown-tool", form: hookForm([
            "hook_event_name": "SessionStart", "session_id": "s1"])))
    }
}
