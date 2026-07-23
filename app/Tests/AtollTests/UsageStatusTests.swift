import XCTest
@testable import Atoll

final class UsageStatusTests: XCTestCase {
    // MARK: Staleness

    func testEmptySnapshotIsStale() {
        XCTAssertTrue(UsageSnapshot().isStale())
    }

    func testFreshSnapshotIsNotStale() {
        var s = UsageSnapshot()
        s.fiveHourPercent = 20
        s.updatedAt = Date()
        XCTAssertFalse(s.isStale())
    }

    func testOldSnapshotIsStale() {
        var s = UsageSnapshot()
        s.fiveHourPercent = 20
        s.updatedAt = Date().addingTimeInterval(-UsageSnapshot.staleThreshold - 60)
        XCTAssertTrue(s.isStale())
    }

    func testResetTimeParsedFromCache() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("usage.json")
        let resets = Date().addingTimeInterval(3600).timeIntervalSince1970
        let json = """
        {"five_hour":{"used_percentage":42,"resets_at":\(resets)},"at":\(Date().timeIntervalSince1970)}
        """
        try Data(json.utf8).write(to: file)
        let snap = try XCTUnwrap(UsageSnapshot.load(path: file.path))
        XCTAssertEqual(snap.fiveHourPercent, 42)
        XCTAssertEqual(snap.fiveHourResetsAt?.timeIntervalSince1970 ?? 0, resets, accuracy: 1)
        XCTAssertFalse(snap.isStale())
    }

    func testCorruptCacheLoadsNilNotCrash() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("usage.json")
        try Data("{ broken".utf8).write(to: file)
        XCTAssertNil(UsageSnapshot.load(path: file.path))
    }

    func testMissingCacheLoadsNil() {
        XCTAssertNil(UsageSnapshot.load(path: "/no/such/usage.json"))
    }

    // MARK: Status policy

    func testConfigErrorAndMissingJqDominate() {
        XCTAssertEqual(UsageStatusPolicy.status(connected: true, jqPresent: true,
            configError: true, hasData: true, isStale: false), .configError)
        XCTAssertEqual(UsageStatusPolicy.status(connected: true, jqPresent: false,
            configError: false, hasData: true, isStale: false), .configError)
    }

    func testNotConnectedWhenUnwrapped() {
        XCTAssertEqual(UsageStatusPolicy.status(connected: false, jqPresent: true,
            configError: false, hasData: false, isStale: false), .notConnected)
    }

    func testConnectedFreshVsStale() {
        XCTAssertEqual(UsageStatusPolicy.status(connected: true, jqPresent: true,
            configError: false, hasData: true, isStale: false), .connected)
        XCTAssertEqual(UsageStatusPolicy.status(connected: true, jqPresent: true,
            configError: false, hasData: true, isStale: true), .stale)
    }

    func testConnectedButNoDataYetIsConnectedNotStale() {
        XCTAssertEqual(UsageStatusPolicy.status(connected: true, jqPresent: true,
            configError: false, hasData: false, isStale: true), .connected)
    }
}
