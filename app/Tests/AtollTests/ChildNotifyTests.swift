import XCTest
@testable import Atoll

final class ChildNotifyTests: XCTestCase {
    func testEveryCompletionFiresOnEachStop() {
        let a = ChildNotifyPolicy.onSubagentStop(timing: .everyCompletion, runningAfter: 2,
                                                 alreadyFiredAllFinished: false)
        let b = ChildNotifyPolicy.onSubagentStop(timing: .everyCompletion, runningAfter: 0,
                                                 alreadyFiredAllFinished: false)
        XCTAssertTrue(a.notify)
        XCTAssertTrue(b.notify)
    }

    func testOffAndRootResponseNeverFirePerChild() {
        for timing in [ChildNotifyTiming.off, .rootResponse] {
            let r = ChildNotifyPolicy.onSubagentStop(timing: timing, runningAfter: 0,
                                                     alreadyFiredAllFinished: false)
            XCTAssertFalse(r.notify, "\(timing) must not fire on a child stop")
        }
    }

    func testAllFinishedFiresOnceWhenRunningReachesZero() {
        // Two subagents: first stop (1 left) is silent, second (0 left) fires.
        let first = ChildNotifyPolicy.onSubagentStop(timing: .allFinished, runningAfter: 1,
                                                     alreadyFiredAllFinished: false)
        XCTAssertFalse(first.notify)
        let second = ChildNotifyPolicy.onSubagentStop(timing: .allFinished, runningAfter: 0,
                                                      alreadyFiredAllFinished: first.firedAllFinished)
        XCTAssertTrue(second.notify)
        XCTAssertTrue(second.firedAllFinished)
    }

    func testAllFinishedDoesNotDoubleFireOnDuplicateOrOutOfOrderStop() {
        // Already fired once; a duplicate/late stop at zero must stay silent.
        let dup = ChildNotifyPolicy.onSubagentStop(timing: .allFinished, runningAfter: 0,
                                                   alreadyFiredAllFinished: true)
        XCTAssertFalse(dup.notify)
        XCTAssertTrue(dup.firedAllFinished)
    }

    // MARK: Store-level behaviour

    @MainActor
    private func store() -> SessionStore {
        SessionStore(snapshotDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
    }

    @MainActor
    private func event(_ kind: EventKind, _ key: String = "s") -> NormalizedEvent {
        NormalizedEvent(source: "claude", sessionKey: key, kind: kind, cwd: "/tmp", tty: "t")
    }

    @MainActor
    func testConcurrentSubagentsTrackRunningCount() {
        let s = store()
        s.apply(event(.sessionStart))
        s.apply(event(.subagentStart))
        s.apply(event(.subagentStart))
        XCTAssertEqual(s.sessions["s"]?.subagentsRunning, 2)
        s.apply(event(.subagentStop))
        XCTAssertEqual(s.sessions["s"]?.subagentsRunning, 1)
        XCTAssertEqual(s.sessions["s"]?.subagentsDone, 1)
    }

    @MainActor
    func testNewFanoutReArmsAllFinishedFlag() {
        Settings.shared.childNotifyTiming = .allFinished
        defer { Settings.shared.childNotifyTiming = .off }
        let s = store()
        s.apply(event(.sessionStart))
        s.apply(event(.subagentStart))
        s.apply(event(.subagentStop))                    // running 0 → fires, flag set
        XCTAssertEqual(s.sessions["s"]?.firedAllFinished, true)
        s.apply(event(.subagentStart))                   // new fan-out re-arms
        XCTAssertEqual(s.sessions["s"]?.firedAllFinished, false)
    }

    @MainActor
    func testRootStopWithSubagentsStillRunningDoesNotFireAllFinished() {
        Settings.shared.childNotifyTiming = .allFinished
        defer { Settings.shared.childNotifyTiming = .off }
        let s = store()
        s.apply(event(.sessionStart))
        s.apply(event(.subagentStart))
        s.apply(event(.stop))                            // root ends early, 1 subagent still running
        XCTAssertEqual(s.sessions["s"]?.firedAllFinished, false)
        XCTAssertEqual(s.sessions["s"]?.subagentsRunning, 1)
    }
}
