import SwiftUI

/// The coral 🪸 logo, gently bobbing + wiggling while any agent is working
/// (idle = still). Driven by TimelineView for smooth continuous motion.
struct AnimatedCoral: View {
    let working: Bool
    var size: CGFloat = 12

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let s = working ? sin(t * 4.0) : 0          // -1…1
            Text("🪸")
                .font(.system(size: size))
                .scaleEffect(1.0 + (working ? 0.10 : 0) * (0.5 + 0.5 * s))
                .rotationEffect(.degrees(s * 7))
        }
    }
}

/// Animated pixel-buddy: a per-agent glyph rendered in
/// the agent's colour that bounces between two frames while the session works.
struct AgentBuddy: View {
    let source: String
    let state: SessionState
    var size: CGFloat = 12

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.45)) { ctx in
            let frame = Int(ctx.date.timeIntervalSinceReferenceDate / 0.45) % 2
            Text(glyph)
                .font(.system(size: size, weight: .bold, design: .monospaced))
                .foregroundStyle(working ? color : color.opacity(0.55))
                .offset(y: working && frame == 1 ? -1.5 : 0)
                .animation(.easeInOut(duration: 0.2), value: frame)
        }
    }

    private var working: Bool {
        state == .thinking || state == .runningTool || state == .compacting
    }

    private var glyph: String {
        switch state {
        case .waitingApproval, .waitingAnswer: return "⚠︎"
        case .needsAttention: return "✗"
        case .done: return "✓"
        case .ended: return "·"
        default:
            switch source {
            case "claude": return "✳︎"
            case "codex": return "◆"
            case "gemini": return "✦"
            default: return "●"
            }
        }
    }

    private var color: Color {
        switch state {
        case .waitingApproval, .waitingAnswer, .needsAttention: return .red
        case .done: return .green
        case .ended: return .gray
        default: return Theme.agentColor(source)
        }
    }
}
