import XCTest
@testable import Atoll

final class SessionSnapshotTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSession(id: String, state: SessionState = .runningTool,
                             lastActivity: Date = Date(), toolLog: Int = 0) -> AgentSession {
        var s = AgentSession(id: id, source: "claude", cwd: "/Users/x/proj-\(id)", tty: "ttys001",
                             state: state, startedAt: Date(), lastActivity: lastActivity)
        s.firstPrompt = "first \(id)"
        s.lastReply = "reply \(id)"
        for i in 0..<toolLog {
            s.toolLog.append(ToolEvent(id: UUID(), time: Date(), verb: "运行中",
                                       toolName: "Bash", detail: "cmd \(i)"))
        }
        return s
    }

    func testSaveWritesAtomicOwnerOnlyFile() throws {
        let dir = tempDir()
        SessionSnapshot.save([makeSession(id: "a")], to: dir)
        let file = dir.appendingPathComponent("sessions.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
    }

    func testRoundTripRestoresDisplayFields() {
        let dir = tempDir()
        let original = makeSession(id: "a")
        SessionSnapshot.save([original], to: dir)
        let loaded = SessionSnapshot.load(from: dir)
        XCTAssertNil(loaded.warning)
        XCTAssertEqual(loaded.sessions.count, 1)
        XCTAssertEqual(loaded.sessions.first?.id, "a")
        XCTAssertEqual(loaded.sessions.first?.firstPrompt, "first a")
        XCTAssertEqual(loaded.sessions.first?.lastReply, "reply a")
        XCTAssertEqual(loaded.sessions.first?.source, "claude")
    }

    func testRestoreDowngradesPendingImplyingStates() {
        let dir = tempDir()
        SessionSnapshot.save([
            makeSession(id: "wa", state: .waitingApproval),
            makeSession(id: "wq", state: .waitingAnswer),
            makeSession(id: "rt", state: .runningTool),
        ], to: dir)
        let loaded = SessionSnapshot.load(from: dir)
        let byID = Dictionary(uniqueKeysWithValues: loaded.sessions.map { ($0.id, $0) })
        XCTAssertEqual(byID["wa"]?.state, .thinking, "waitingApproval must not restore as a ghost approval")
        XCTAssertEqual(byID["wq"]?.state, .thinking, "waitingAnswer must not restore as a ghost question")
        XCTAssertEqual(byID["rt"]?.state, .runningTool, "non-pending states are preserved")
    }

    func testCorruptSnapshotIsIsolatedWithWarning() throws {
        let dir = tempDir()
        let file = dir.appendingPathComponent("sessions.json")
        try Data("{ not valid json".utf8).write(to: file)
        let loaded = SessionSnapshot.load(from: dir)
        XCTAssertTrue(loaded.sessions.isEmpty)
        XCTAssertNotNil(loaded.warning, "corruption must surface, not be swallowed")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("sessions.json.corrupt").path),
            "corrupt file is isolated aside")
    }

    func testTrimCapsSessionCountKeepingMostRecent() {
        let dir = tempDir()
        let base = Date()
        let many = (0..<(SessionSnapshot.maxSessions + 10)).map {
            makeSession(id: "s\($0)", lastActivity: base.addingTimeInterval(Double($0)))
        }
        SessionSnapshot.save(many, to: dir)
        let loaded = SessionSnapshot.load(from: dir)
        XCTAssertEqual(loaded.sessions.count, SessionSnapshot.maxSessions)
        // Newest (highest index) survives; oldest is dropped.
        let ids = Set(loaded.sessions.map(\.id))
        XCTAssertTrue(ids.contains("s\(SessionSnapshot.maxSessions + 9)"))
        XCTAssertFalse(ids.contains("s0"))
    }

    func testToolLogCappedPerSession() {
        let dir = tempDir()
        SessionSnapshot.save([makeSession(id: "a", toolLog: 50)], to: dir)
        let loaded = SessionSnapshot.load(from: dir)
        XCTAssertEqual(loaded.sessions.first?.toolLog.count, SessionSnapshot.maxToolLogPerSession)
    }

    func testMissingFileLoadsEmptyWithoutWarning() {
        let loaded = SessionSnapshot.load(from: tempDir())
        XCTAssertTrue(loaded.sessions.isEmpty)
        XCTAssertNil(loaded.warning)
    }

    // MARK: - Store integration

    @MainActor
    func testStoreRestoresSnapshotOnInit() {
        let dir = tempDir()
        SessionSnapshot.save([makeSession(id: "a", state: .waitingApproval)], to: dir)
        let store = SessionStore(snapshotDirectory: dir)
        XCTAssertEqual(store.sessions["a"]?.id, "a")
        XCTAssertEqual(store.sessions["a"]?.state, .thinking, "restored card is not a ghost approval")
        XCTAssertTrue(store.pending.isEmpty, "pending is never persisted or restored")
    }

    @MainActor
    func testStoreDoesNotReviveUserRemovedSession() {
        let dir = tempDir()
        // First store sees a session and the user removes it; snapshot reflects removal.
        let store1 = SessionStore(snapshotDirectory: dir)
        store1.upsertCodexDesktopSession(id: "gone", cwd: "/tmp", title: "t")
        XCTAssertNotNil(store1.sessions["gone"])
        store1.removeSession(id: "gone")
        SessionSnapshot.save(Array(store1.sessions.values), to: dir)
        // A fresh store must not resurrect the removed session from the snapshot.
        let store2 = SessionStore(snapshotDirectory: dir)
        XCTAssertNil(store2.sessions["gone"])
    }
}
