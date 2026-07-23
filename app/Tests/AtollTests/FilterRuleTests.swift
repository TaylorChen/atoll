import XCTest
@testable import Atoll

final class FilterRuleTests: XCTestCase {
    private func session(id: String = "s", cwd: String = "/Users/x/proj",
                         firstPrompt: String = "") -> AgentSession {
        var s = AgentSession(id: id, source: "claude", cwd: cwd, tty: "", state: .thinking,
                             startedAt: Date(), lastActivity: Date())
        s.firstPrompt = firstPrompt
        return s
    }

    private func suite(_ name: String = UUID().uuidString) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: Matching

    func testDirectoryPrefixMatch() {
        let rule = FilterRule(id: "r", name: "n", kind: .directory, match: .prefix,
                              value: "/Users/x/proj", reason: "", enabled: true, builtin: false)
        XCTAssertTrue(rule.matches(session(cwd: "/Users/x/proj/sub")))
        XCTAssertFalse(rule.matches(session(cwd: "/Users/y/other")))
    }

    func testContainsMatchIsCaseInsensitive() {
        let rule = FilterRule(id: "r", name: "n", kind: .promptPrefix, match: .contains,
                              value: "guardian", reason: "", enabled: true, builtin: false)
        XCTAssertTrue(rule.matches(session(firstPrompt: "Running GUARDIAN checks")))
    }

    func testEmptyValueNeverMatches() {
        let rule = FilterRule(id: "r", name: "n", kind: .promptPrefix, match: .contains,
                              value: "", reason: "", enabled: true, builtin: false)
        XCTAssertFalse(rule.matches(session(firstPrompt: "anything")),
                       "a blank rule must not silently hide everything")
    }

    func testDisabledRuleNeverMatches() {
        let rule = FilterRule(id: "r", name: "n", kind: .directory, match: .prefix,
                              value: "/Users/x", reason: "", enabled: false, builtin: false)
        XCTAssertFalse(rule.matches(session(cwd: "/Users/x/proj")))
    }

    func testBuiltinSignatureGroupMatchesAnyNeedle() {
        let memory = FilterRule.builtinGroups.first { $0.id == "builtin.memory" }!
        XCTAssertTrue(memory.matches(session(firstPrompt: "Codex Chronicle daily digest")))
        XCTAssertTrue(memory.matches(session(firstPrompt: "## Memory Writing Agent")))
        XCTAssertFalse(memory.matches(session(firstPrompt: "normal task")))
    }

    // MARK: Store composition + migration

    func testDefaultLoadIncludesBuiltins() {
        let result = FilterRuleStore.load(defaults: suite())
        XCTAssertEqual(result.rules.filter(\.builtin).count, FilterRule.builtinGroups.count)
        XCTAssertNil(result.warning)
    }

    func testLegacyKeysMigrateToUserRules() {
        let d = suite()
        d.set(["/Users/x/hidden"], forKey: "hiddenDirs")
        d.set(["scratch prompt"], forKey: "hiddenPromptPrefixes")
        let rules = FilterRuleStore.load(defaults: d).rules
        XCTAssertTrue(rules.contains { $0.kind == .directory && $0.value == "/Users/x/hidden" })
        XCTAssertTrue(rules.contains { $0.kind == .promptPrefix && $0.value == "scratch prompt" })
    }

    func testLegacyBackgroundOffDisablesBuiltins() {
        let d = suite()
        d.set(false, forKey: "filterBackgroundTasks")
        let rules = FilterRuleStore.load(defaults: d).rules
        XCTAssertTrue(rules.filter(\.builtin).allSatisfy { !$0.enabled })
    }

    func testDuplicateUserRulesAreDropped() {
        var state = FilterRuleState()
        let mk = { FilterRule(id: UUID().uuidString, name: "n", kind: .directory, match: .prefix,
                              value: "/dup", reason: "", enabled: true, builtin: false) }
        state.userRules = [mk(), mk()]
        let d = suite()
        FilterRuleStore.save(state, defaults: d)
        let user = FilterRuleStore.load(defaults: d).rules.filter { !$0.builtin }
        XCTAssertEqual(user.count, 1, "same kind+match+value collapses to one rule")
    }

    func testCorruptStoreFallsBackToBuiltinsWithWarning() {
        let d = suite()
        d.set(Data("not json".utf8), forKey: FilterRuleStore.key)
        let result = FilterRuleStore.load(defaults: d)
        XCTAssertNotNil(result.warning, "corruption must surface, not silently drop rules")
        XCTAssertEqual(result.rules.filter(\.builtin).count, FilterRule.builtinGroups.count,
                       "built-ins survive a corrupt user store")
    }

    // MARK: Store integration

    @MainActor
    func testMultipleRulesHideOverlappingSessions() {
        let store = SessionStore(snapshotDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        store.apply(NormalizedEvent(source: "claude", sessionKey: "a", kind: .sessionStart,
                                    cwd: "/Users/x/secret", tty: "t"))
        store.hideDir("/Users/x/secret")
        XCTAssertFalse(store.sorted.contains { $0.id == "a" }, "hidden by directory rule")
        XCTAssertEqual(store.firstMatchingRule(store.sessions["a"]!)?.kind, .directory)
    }
}
