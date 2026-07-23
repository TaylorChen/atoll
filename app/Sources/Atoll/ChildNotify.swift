import Foundation

/// When a subagent / Agent Team member finishing should raise a completion
/// notice. Replaces the old single "notify on subagent completion" boolean.
enum ChildNotifyTiming: String, CaseIterable, Identifiable {
    case off              // never for child agents
    case everyCompletion  // each subagent stop
    case allFinished      // once, when the last running subagent stops
    case rootResponse     // never for children — fold into the root agent's own完成

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "关闭"
        case .everyCompletion: return "每个子 Agent 完成时"
        case .allFinished: return "全部子 Agent 完成后"
        case .rootResponse: return "仅主 Agent 回复时"
        }
    }
}

enum ChildNotifyPolicy {
    /// Whether a subagent stop should emit a completion notice, and the updated
    /// "already fired the all-finished notice" flag (carried on the session).
    ///
    /// - `everyCompletion` fires on each stop.
    /// - `allFinished` fires exactly once, when the running count reaches zero,
    ///   guarded by the flag so duplicate/out-of-order stops can't double-fire.
    /// - `off` / `rootResponse` never fire per child (rootResponse relies on the
    ///   root agent's own completion notice at Stop).
    static func onSubagentStop(timing: ChildNotifyTiming, runningAfter: Int,
                               alreadyFiredAllFinished: Bool) -> (notify: Bool, firedAllFinished: Bool) {
        switch timing {
        case .off, .rootResponse:
            return (false, alreadyFiredAllFinished)
        case .everyCompletion:
            return (true, alreadyFiredAllFinished)
        case .allFinished:
            if runningAfter <= 0 && !alreadyFiredAllFinished {
                return (true, true)
            }
            return (false, alreadyFiredAllFinished)
        }
    }
}
