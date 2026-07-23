import XCTest
@testable import Atoll

@MainActor
final class SessionStoreTests: XCTestCase {
    /// A store with a unique, throwaway snapshot directory so tests never read
    /// or write the real ~/.atoll/sessions.json.
    private func makeStore() -> SessionStore {
        SessionStore(snapshotDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
    }

    func testAppInstanceLockRejectsSecondHolder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atoll-instance-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("app.lock").path
        let first = try AppInstanceLock(path: path)

        XCTAssertThrowsError(try AppInstanceLock(path: path)) { error in
            guard case AppInstanceLock.LockError.alreadyRunning = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        _ = first
    }

    private func decide(_ kind: AtollNoticeKind, enabled: Bool = true, quiet: Bool = false,
                        systemEnabled: Bool = true, sourceFrontmost: Bool = false,
                        suppressBanner: Bool = true, withinCooldown: Bool = false,
                        expandOnComplete: Bool = true) -> NoticeDecision {
        NoticePolicy.decision(kind: kind, enabled: enabled, quiet: quiet,
                              systemEnabled: systemEnabled, sourceFrontmost: sourceFrontmost,
                              suppressBannerWhenSourceFrontmost: suppressBanner,
                              withinCooldown: withinCooldown, expandOnComplete: expandOnComplete)
    }

    func testQuietMutesSoundAndBannerButKeepsApprovalAttentionAndExpand() {
        let d = decide(.approval, quiet: true)
        XCTAssertFalse(d.sound, "quiet mutes sound")
        XCTAssertFalse(d.banner, "quiet mutes banner")
        XCTAssertTrue(d.autoExpand, "an approval must still surface when muted")
        XCTAssertTrue(d.attentionDot, "attention trace persists through quiet")
    }

    func testFailureLeavesAttentionTraceWithoutStealingFocus() {
        let d = decide(.failure, quiet: true, withinCooldown: true)
        XCTAssertFalse(d.sound)
        XCTAssertFalse(d.banner)
        XCTAssertFalse(d.autoExpand, "a failure does not pop the panel open")
        XCTAssertTrue(d.attentionDot, "a failure always leaves a visible trace")
    }

    func testCompletionAutoExpandGatedByQuietCooldownAndSetting() {
        XCTAssertTrue(decide(.completion).autoExpand)
        XCTAssertFalse(decide(.completion, quiet: true).autoExpand)
        XCTAssertFalse(decide(.completion, withinCooldown: true).autoExpand)
        XCTAssertFalse(decide(.completion, expandOnComplete: false).autoExpand)
        XCTAssertFalse(decide(.completion).attentionDot, "completion leaves no lingering dot")
    }

    func testBannerSuppressedWhenAgentFrontmostButSoundStays() {
        let d = decide(.approval, sourceFrontmost: true)
        XCTAssertTrue(d.sound)
        XCTAssertFalse(d.banner)
    }

    func testDisabledKindMutesChannelsButApprovalStillSurfaces() {
        let d = decide(.approval, enabled: false)
        XCTAssertFalse(d.sound)
        XCTAssertFalse(d.banner)
        XCTAssertTrue(d.autoExpand, "disabling the sound preference cannot hide an approval")
        XCTAssertTrue(d.attentionDot)
    }

    func testAllChannelsOpenOutsideNoiseConditions() {
        let d = decide(.completion)
        XCTAssertEqual(d, NoticeDecision(sound: true, banner: true, autoExpand: true, attentionDot: false))
    }

    func testSmartApprovalUsesNativeSurfaceWhenAgentTerminalIsFrontmost() {
        XCTAssertEqual(
            ApprovalRouter.effectiveRoute(configured: .smart, source: "claude",
                                          sessionHasTTY: true,
                                          frontmostBundleID: "com.apple.Terminal",
                                          frontmostName: "Terminal"),
            .native
        )
    }

    func testSmartApprovalUsesAtollWhenUnrelatedAppIsFrontmost() {
        XCTAssertEqual(
            ApprovalRouter.effectiveRoute(configured: .smart, source: "codex",
                                          sessionHasTTY: true,
                                          frontmostBundleID: "com.apple.Safari",
                                          frontmostName: "Safari"),
            .atoll
        )
    }

    func testExplicitApprovalRouteOverridesFocus() {
        XCTAssertEqual(
            ApprovalRouter.effectiveRoute(configured: .atoll, source: "codex",
                                          sessionHasTTY: true,
                                          frontmostBundleID: "com.openai.chat",
                                          frontmostName: "ChatGPT"),
            .atoll
        )
        XCTAssertEqual(
            ApprovalRouter.effectiveRoute(configured: .native, source: "claude",
                                          sessionHasTTY: false,
                                          frontmostBundleID: "com.apple.Safari",
                                          frontmostName: "Safari"),
            .native
        )
    }

    func testCodexAllowUsesCodexPermissionRequestEnvelope() throws {
        let request = pending(id: "codex", kind: .approval, toolName: "Bash", source: "codex")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: HookDecisionCodec.encode(.allow, for: request))
                as? [String: Any])
        let hook = try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hook["decision"] as? [String: Any])

        XCTAssertEqual(object["continue"] as? Bool, true)
        XCTAssertEqual(hook["hookEventName"] as? String, "PermissionRequest")
        XCTAssertEqual(decision["behavior"] as? String, "allow")
    }

    func testCodexAlwaysAllowDoesNotEmitUnsupportedPermissionUpdates() throws {
        let request = pending(id: "codex", kind: .approval, toolName: "Bash", source: "codex")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: HookDecisionCodec.encode(.alwaysAllow, for: request))
                as? [String: Any])
        let hook = try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hook["decision"] as? [String: Any])

        XCTAssertEqual(decision["behavior"] as? String, "allow")
        XCTAssertNil(decision["updatedPermissions"])
    }

    func testPlanCardClearsWhenToolFinishesOutsideAtoll() {
        withSoundDisabled {
            let store = makeStore()
            var resolved: [String] = []
            store.resolver = { id, _ in resolved.append(id) }
            store.addPending(pending(id: "plan", kind: .plan, toolName: "ExitPlanMode"))

            store.apply(event(kind: .toolResult, toolName: "ExitPlanMode"))

            XCTAssertTrue(store.pending.isEmpty)
            XCTAssertEqual(resolved, ["plan"])
        }
    }

    func testQuestionCardClearsWhenTurnStopsOutsideAtoll() {
        withSoundDisabled {
            let store = makeStore()
            var resolved: [String] = []
            store.resolver = { id, _ in resolved.append(id) }
            store.addPending(pending(id: "question", kind: .question, toolName: "AskUserQuestion"))

            store.apply(event(kind: .stop))

            XCTAssertTrue(store.pending.isEmpty)
            XCTAssertEqual(resolved, ["question"])
        }
    }

    func testUnrelatedToolDoesNotClearApprovalCard() {
        withSoundDisabled {
            let store = makeStore()
            store.addPending(pending(id: "approval", kind: .approval, toolName: "Bash"))

            store.apply(event(kind: .toolUse, toolName: "Read"))

            XCTAssertEqual(store.pending.map(\.id), ["approval"])
        }
    }

    func testToolUseIDClearsOnlyTheMatchingApproval() {
        withSoundDisabled {
            let store = makeStore()
            store.addPending(pending(id: "first", kind: .approval, toolName: "Bash", toolUseID: "call-1"))
            store.addPending(pending(id: "second", kind: .approval, toolName: "Bash", toolUseID: "call-2"))

            store.apply(event(kind: .toolUse, toolName: "Bash", toolUseID: "call-2"))

            XCTAssertEqual(store.pending.map(\.id), ["first"])
        }
    }

    func testRemoveActiveSessionOnlyRemovesLocalPresentationAndNextEventRecreatesIt() {
        withSoundDisabled {
            let store = makeStore()
            store.apply(event(kind: .sessionStart))

            XCTAssertTrue(store.removeSession(id: "session"))
            XCTAssertTrue(store.sessions.isEmpty)

            store.apply(event(kind: .toolUse, toolName: "Bash"))

            XCTAssertEqual(store.sessions["session"]?.state, .runningTool)
        }
    }

    func testPendingInteractionBlocksSessionRemoval() {
        withSoundDisabled {
            let store = makeStore()
            store.apply(event(kind: .sessionStart))
            store.addPending(pending(id: "approval", kind: .approval, toolName: "Bash"))

            XCTAssertFalse(store.removeSession(id: "session"))
            XCTAssertNotNil(store.sessions["session"])
            XCTAssertEqual(store.pending.map(\.id), ["approval"])
        }
    }

    func testBulkCleanupRemovesOnlyFinishedSessionsWithoutPendingInteractions() {
        withSoundDisabled {
            let store = makeStore()
            store.apply(event(sessionKey: "done", kind: .stop))
            store.apply(event(sessionKey: "ended", kind: .sessionEnd))
            store.apply(event(sessionKey: "active", kind: .toolUse, toolName: "Read"))
            store.apply(event(sessionKey: "protected", kind: .stop))
            store.addPending(pending(id: "question", sessionKey: "protected",
                                     kind: .question, toolName: "AskUserQuestion"))

            XCTAssertEqual(store.removableCompletedSessionCount, 2)
            XCTAssertEqual(store.removeCompletedSessions(), 2)
            XCTAssertEqual(Set(store.sessions.keys), ["active", "protected"])
            XCTAssertEqual(store.pending.map(\.id), ["question"])
        }
    }

    func testCodexPollingDoesNotImmediatelyRestoreDismissedSession() {
        withSoundDisabled {
            let store = makeStore()
            store.upsertCodexDesktopSession(id: "thread", cwd: "/tmp", title: "Task")
            let key = "thread"
            XCTAssertTrue(store.removeSession(id: key))

            store.upsertCodexDesktopSession(id: "thread", cwd: "/tmp", title: "Task")

            XCTAssertNil(store.sessions[key])
        }
    }

    func testCodexActivityRestoresDismissedSession() {
        withSoundDisabled {
            let store = makeStore()
            store.upsertCodexDesktopSession(id: "thread", cwd: "/tmp", title: "Task")
            let key = "thread"
            XCTAssertTrue(store.removeSession(id: key))

            store.setCodexDesktopState(id: "thread", .runningTool, reviveDismissed: true)

            XCTAssertEqual(store.sessions[key]?.state, .runningTool)
        }
    }

    func testCodexDesktopAndHookEventsMergeIntoOneSession() {
        withSoundDisabled {
            let store = makeStore()
            store.upsertCodexDesktopSession(id: "thread", cwd: "/tmp/project",
                                            title: "分析并启动项目")
            store.apply(event(source: "codex", sessionKey: "thread", kind: .prompt,
                              detail: "请再次整理 P0 包含哪些功能？"))
            store.apply(event(source: "codex", sessionKey: "thread", kind: .toolUse,
                              toolName: "Bash", detail: "swift test"))

            XCTAssertEqual(store.sessions.count, 1)
            XCTAssertEqual(store.sessions["thread"]?.aiTitle, "分析并启动项目")
            XCTAssertEqual(store.sessions["thread"]?.firstPrompt, "请再次整理 P0 包含哪些功能？")
            XCTAssertEqual(store.sessions["thread"]?.lastPrompt, "请再次整理 P0 包含哪些功能？")
            XCTAssertEqual(store.sessions["thread"]?.toolLog.map(\.toolName), ["Bash"])
            XCTAssertEqual(store.sessions["thread"]?.observedInCodexDesktop, true)
        }
    }

    func testCodexDesktopMetadataMergesWhenHookSessionArrivesFirst() {
        withSoundDisabled {
            let store = makeStore()
            store.apply(event(source: "codex", sessionKey: "thread", kind: .prompt,
                              detail: "当前问题"))

            store.upsertCodexDesktopSession(id: "thread", cwd: "/tmp/project",
                                            title: "稳定任务标题")

            XCTAssertEqual(store.sessions.count, 1)
            XCTAssertEqual(store.sessions["thread"]?.aiTitle, "稳定任务标题")
            XCTAssertEqual(store.sessions["thread"]?.firstPrompt, "当前问题")
            XCTAssertEqual(store.sessions["thread"]?.lastPrompt, "当前问题")
            XCTAssertEqual(store.sessions["thread"]?.observedInCodexDesktop, true)
        }
    }

    func testCodexPromptTracksLatestTurnWithoutReplacingFirstPrompt() {
        withSoundDisabled {
            let store = makeStore()
            store.apply(event(source: "codex", sessionKey: "thread", kind: .prompt,
                              detail: "第一个问题"))
            store.apply(event(source: "codex", sessionKey: "thread", kind: .stop,
                              detail: "第一个回答"))
            store.apply(event(source: "codex", sessionKey: "thread", kind: .prompt,
                              detail: "第二个问题"))

            XCTAssertEqual(store.sessions["thread"]?.firstPrompt, "第一个问题")
            XCTAssertEqual(store.sessions["thread"]?.lastPrompt, "第二个问题")
            XCTAssertEqual(store.sessions["thread"]?.lastReply, "第一个回答")
        }
    }

    func testHookEventRestoresConversationPreviewFromTranscriptAfterRestart() throws {
        try withSoundDisabled {
            let transcript = FileManager.default.temporaryDirectory
                .appendingPathComponent("atoll-transcript-\(UUID().uuidString).jsonl")
            defer { try? FileManager.default.removeItem(at: transcript) }
            let lines = [
                #"{"type":"user","message":{"content":[{"type":"text","text":"当前问题"}]}}"#,
                #"{"type":"response_item","payload":{"type":"custom_tool_call_output","output":"\#(String(repeating: "x", count: 300_000))"}}"#,
                #"{"type":"assistant","message":{"content":[{"type":"text","text":"上一条回复"}]}}"#,
            ] + (1...8).map {
                #"{"type":"assistant","message":{"content":[{"type":"text","text":"进度 \#($0)"}]}}"#
            }
            let transcriptContent = lines.joined(separator: "\n")
            try transcriptContent.write(to: transcript, atomically: true, encoding: .utf8)

            let store = makeStore()
            var toolEvent = event(source: "codex", sessionKey: "thread", kind: .toolUse,
                                  toolName: "Bash", detail: "swift test")
            toolEvent.transcriptPath = transcript.path
            store.apply(toolEvent)

            XCTAssertEqual(store.sessions["thread"]?.lastPrompt, "当前问题")
            XCTAssertEqual(store.sessions["thread"]?.lastReply, "进度 8")
        }
    }

    func testRecentMessagesParsesCodexResponseItems() throws {
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("atoll-codex-transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: transcript) }
        let lines = [
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Codex 问题"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Codex 回复"}]}}"#,
        ].joined(separator: "\n")
        try lines.write(to: transcript, atomically: true, encoding: .utf8)

        let messages = Normalizer.recentMessages(transcriptPath: transcript.path)

        XCTAssertEqual(messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(messages.map(\.text), ["Codex 问题", "Codex 回复"])
    }

    private func pending(id: String, sessionKey: String = "session",
                         kind: PendingKind, toolName: String,
                         source: String = "claude", toolUseID: String = "") -> PendingRequest {
        PendingRequest(id: id, sessionKey: sessionKey, kind: kind, toolName: toolName,
                       detailLines: [], questions: [], plan: "", createdAt: Date(), source: source,
                       toolUseID: toolUseID)
    }

    private func event(source: String = "claude", sessionKey: String = "session", kind: EventKind,
                       toolName: String = "", detail: String = "", toolUseID: String = "") -> NormalizedEvent {
        NormalizedEvent(source: source, sessionKey: sessionKey, kind: kind,
                        cwd: "/tmp", tty: "", toolName: toolName, detail: detail,
                        toolUseID: toolUseID)
    }

    private func withSoundDisabled(_ body: () throws -> Void) rethrows {
        let wasEnabled = SoundPlayer.enabled
        SoundPlayer.enabled = false
        defer { SoundPlayer.enabled = wasEnabled }
        try body()
    }
}
