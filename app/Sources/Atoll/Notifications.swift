import AppKit
import UserNotifications

enum AtollNoticeKind: String, CaseIterable {
    case approval
    case question
    case subagentCompletion
    case completion
    case failure

    var title: String {
        switch self {
        case .approval: return "等待审批"
        case .question: return "等待回答"
        case .subagentCompletion: return "子 Agent 已完成"
        case .completion: return "任务已完成"
        case .failure: return "任务需要关注"
        }
    }

    var sound: SoundPlayer.Event {
        switch self {
        case .approval, .question: return .inputRequired
        case .subagentCompletion, .completion: return .taskComplete
        case .failure: return .taskError
        }
    }
}

/// Four independent channels for one event. Splitting them keeps the meaning of
/// each setting explicit: muting sound never hides a card, and closing the
/// completion pop never drops the attention state.
struct NoticeDecision: Equatable {
    var sound = false
    var banner = false
    var autoExpand = false
    var attentionDot = false
}

enum NoticePolicy {
    /// Compute the four channels for one event.
    ///
    /// Quiet / cooldown / enabled gate only the *notification* channels (sound,
    /// banner, and the completion auto-expand). They never gate `attentionDot`
    /// — an approval, question or failure must always leave a visible trace —
    /// and they never touch session or pending state (that's the store's job,
    /// done outside this policy).
    static func decision(kind: AtollNoticeKind, enabled: Bool, quiet: Bool,
                         systemEnabled: Bool, sourceFrontmost: Bool,
                         suppressBannerWhenSourceFrontmost: Bool,
                         withinCooldown: Bool, expandOnComplete: Bool) -> NoticeDecision {
        var d = NoticeDecision()
        let channelsOpen = enabled && !quiet && !withinCooldown
        d.sound = channelsOpen
        d.banner = channelsOpen && systemEnabled
            && !(suppressBannerWhenSourceFrontmost && sourceFrontmost)
        switch kind {
        case .approval, .question:
            d.autoExpand = true       // a decision is required — always surface
            d.attentionDot = true     // persists even when fully muted
        case .failure:
            d.autoExpand = false      // don't steal focus; just leave a trace
            d.attentionDot = true
        case .completion, .subagentCompletion:
            d.autoExpand = channelsOpen && expandOnComplete
            d.attentionDot = false
        }
        return d
    }
}

/// One decision point for sound, system banners and completion popups. Pending
/// cards are never removed by this policy; quiet mode only suppresses noise.
@MainActor
final class AtollNotifier {
    static let shared = AtollNotifier()

    private var lastNotice: [String: Date] = [:]

    func sourceIsFrontmost(_ source: String) -> Bool {
        let frontmost = NSWorkspace.shared.frontmostApplication
        return ApprovalRouter.isSourceAppFrontmost(
            source: source,
            bundleID: frontmost?.bundleIdentifier ?? "",
            name: frontmost?.localizedName ?? ""
        )
    }

    @discardableResult
    func notify(_ kind: AtollNoticeKind, source: String, project: String,
                detail: String = "", now: Date = Date()) -> NoticeDecision {
        let key = "\(kind.rawValue):\(source):\(project)"
        let cooldown = (kind == .completion || kind == .subagentCompletion)
            ? Settings.shared.completionNotificationCooldown : 0
        let withinCooldown = lastNotice[key].map { now.timeIntervalSince($0) < cooldown } ?? false
        let sourceFrontmost = sourceIsFrontmost(source)
        let decision = NoticePolicy.decision(
            kind: kind,
            enabled: Settings.shared.noticeEnabled(kind),
            quiet: QuietPolicy.isQuiet,
            systemEnabled: Settings.shared.systemNotificationsEnabled,
            sourceFrontmost: sourceFrontmost,
            suppressBannerWhenSourceFrontmost: Settings.shared.suppressNotificationWhenAgentFrontmost,
            withinCooldown: withinCooldown,
            expandOnComplete: Settings.shared.expandOnComplete
        )
        // Record cooldown only when a notification channel actually fired, so an
        // event that was fully muted doesn't start a cooldown of its own.
        if decision.sound || decision.banner { lastNotice[key] = now }
        if decision.sound { SoundPlayer.play(kind.sound) }
        if decision.banner {
            deliverSystemBanner(kind: kind, project: project, detail: detail)
        }
        return decision
    }

    func setSystemNotificationsEnabled(_ enabled: Bool) {
        Settings.shared.systemNotificationsEnabled = enabled
        guard enabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { allowed, error in
            if let error {
                NSLog("Atoll notification authorization failed: \(error)")
            } else if !allowed {
                NSLog("Atoll system notifications were not authorized")
            }
        }
    }

    private func deliverSystemBanner(kind: AtollNoticeKind, project: String, detail: String) {
        let content = UNMutableNotificationContent()
        content.title = kind.title
        content.subtitle = project
        content.body = detail
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("Atoll system notification failed: \(error)") }
        }
    }
}
