import AppKit
import Combine
import SwiftUI

enum NotchGeometry {
    /// Keep the collapsed corner shallow, then double the radius when expanded
    /// so the much wider panel still blends smoothly into the menu bar.
    static let collapsedWingWidth: CGFloat = 7
    static let expandedWingWidth: CGFloat = 14
    static let hoverMargin: CGFloat = 2
    static let detailedWindowWidth: CGFloat = 372

    static func windowSize(
        contentWidth: CGFloat,
        height: CGFloat,
        wingWidth: CGFloat = collapsedWingWidth
    ) -> NSSize {
        NSSize(width: contentWidth + 2 * wingWidth, height: height)
    }

    /// Prefer AppKit's physical camera-housing geometry. On displays without a
    /// notch, use the compact fallback tuned for the native menu-bar footprint.
    static func collapsedWindowSize(
        style: CollapsedStyle,
        fallbackContentWidth: CGFloat,
        fallbackHeight: CGFloat,
        safeAreaTop: CGFloat,
        auxiliaryLeftMaxX: CGFloat?,
        auxiliaryRightMinX: CGFloat?
    ) -> NSSize {
        var size = windowSize(contentWidth: fallbackContentWidth, height: fallbackHeight)
        if safeAreaTop > 0,
           let left = auxiliaryLeftMaxX,
           let right = auxiliaryRightMinX,
           right > left {
            size = NSSize(width: right - left, height: safeAreaTop)
        }
        if style == .detailed {
            size.width = max(size.width, detailedWindowWidth)
        }
        return size
    }

    static func frame(screenFrame: NSRect, size: NSSize) -> NSRect {
        NSRect(x: screenFrame.midX - size.width / 2,
               y: screenFrame.maxY - size.height,
               width: size.width,
               height: size.height)
    }

    /// The decorative wings do not respond to hover in the collapsed state.
    /// Once expanded, the full panel remains interactive.
    static func interactionFrame(targetFrame: NSRect, expanded: Bool) -> NSRect {
        let body = expanded
            ? targetFrame
            : targetFrame.insetBy(dx: collapsedWingWidth, dy: 0)
        return body.insetBy(dx: -hoverMargin, dy: -hoverMargin)
    }
}

/// Top-centre floating bar (notch-style overlay for displays without a notch).
/// Non-activating: it never steals focus from the editor or terminal.
/// Collapsed = live status pill; expands on hover or when a pending request
/// arrives. Collapses when the mouse leaves, when pendings clear, or on an
/// outside click — pending approvals keep it pinned open.
@MainActor
final class NotchPanel {
    private let panel: NSPanel
    private let store: SessionStore
    private var cancellables: Set<AnyCancellable> = []
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var hoverTimer: Timer?
    private var hiddenForFullscreen = false
    private var hiddenForIdle = false
    private var lastFullscreenCheck = Date.distantPast

    private static var selectedScreen: NSScreen? {
        let selected = Settings.shared.displayScreenID
        if selected != "primary",
           let match = NSScreen.screens.first(where: { DisplayPolicy.screenID($0) == selected }) {
            return match
        }
        return NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
    }

    static var panelWidth: CGFloat { CGFloat(Settings.shared.panelWidth) }
    static var collapsedSize: NSSize {
        let screen = selectedScreen
        return NotchGeometry.collapsedWindowSize(
            style: Settings.shared.collapsedStyle,
            fallbackContentWidth: CGFloat(Settings.shared.notchWidth),
            fallbackHeight: CGFloat(Settings.shared.notchHeight),
            safeAreaTop: screen?.safeAreaInsets.top ?? 0,
            auxiliaryLeftMaxX: screen?.auxiliaryTopLeftArea?.maxX,
            auxiliaryRightMinX: screen?.auxiliaryTopRightArea?.minX)
    }
    static var collapsedContentWidth: CGFloat {
        max(1, collapsedSize.width - 2 * NotchGeometry.collapsedWingWidth)
    }
    static var expandedSize: NSSize {
        NotchGeometry.windowSize(
            contentWidth: panelWidth,
            height: CGFloat(Settings.shared.panelHeight),
            wingWidth: NotchGeometry.expandedWingWidth)
    }

    /// Height the expanded panel should currently be, based on measured content
    /// (clamped to the configured max). Lets the panel fit content and only
    /// scroll past the max — no empty black space when few sessions.
    private var dynamicExpandedHeight: CGFloat = 0

    private var expandedFrameSize: NSSize {
        let h = dynamicExpandedHeight > 0 ? dynamicExpandedHeight : Self.expandedSize.height
        return NSSize(width: Self.expandedSize.width, height: h)
    }

    private func updateExpandedHeight(_ h: CGFloat) {
        let clamped = min(max(h, CGFloat(Settings.shared.notchHeight) + 20), CGFloat(Settings.shared.panelHeight))
        guard abs(clamped - dynamicExpandedHeight) > 1 else { return }
        dynamicExpandedHeight = clamped
        if store.notchExpanded {
            reposition(size: NSSize(width: Self.expandedSize.width, height: clamped))
        }
    }

    var onOpenSettings: () -> Void = {}

    init(store: SessionStore, usage: UsageReader) {
        self.store = store
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.collapsedSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        let hosting = NSHostingView(rootView: NotchView(
            store: store, usage: usage,
            onOpenSettings: { [weak self] in self?.onOpenSettings() },
            onHeightChange: { [weak self] h in self?.updateExpandedHeight(h) }))
        panel.contentView = hosting
        reposition(size: Self.collapsedSize)
        panel.orderFrontRegardless()

        store.$notchExpanded
            .removeDuplicates()
            .sink { [weak self] expanded in
                guard let self else { return }
                self.reposition(size: expanded ? self.expandedFrameSize : Self.collapsedSize)
            }
            .store(in: &cancellables)

        // Approvals force the panel open; when the last one clears, collapse
        // after a short dwell unless the user is interacting with it.
        store.$pending
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { [weak self] hasPending in
                guard let self else { return }
                if hasPending {
                    self.store.notchExpanded = true
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if self.store.pending.isEmpty && !self.store.notchHovering {
                            self.store.notchExpanded = false
                        }
                    }
                }
            }
            .store(in: &cancellables)

        // Click anywhere outside the panel: collapse (unless approvals pending).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in
                guard let self, self.store.notchExpanded,
                      Settings.shared.dismissOnOutsideClick else { return }
                let f = self.targetFrame == .zero ? self.panel.frame : self.targetFrame
                guard !f.contains(NSEvent.mouseLocation) else { return }
                if PanelDismissPolicy.shouldCollapse(trigger: .outsideClick,
                                                     pendingPresent: !self.store.pending.isEmpty,
                                                     userOpened: self.store.notchUserOpened,
                                                     hovering: self.store.notchHovering) {
                    self.collapse()
                }
            }
        }

        // ESC dismisses a completion/warning reminder — but never an approval,
        // question or plan card (pending keeps the panel pinned open).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53, let self, self.store.notchExpanded else { return event }  // 53 = esc
            let collapse = PanelDismissPolicy.shouldCollapse(
                trigger: .escKey, pendingPresent: !self.store.pending.isEmpty,
                userOpened: self.store.notchUserOpened, hovering: self.store.notchHovering)
            if collapse { self.collapse(); return nil }
            return event
        }

        // Hover via cursor-geometry polling instead of SwiftUI .onHover, which
        // flickers false↔true during the expand animation and view swap and
        // caused the panel to collapse/reposition ~1s after the user hovered in.
        hoverTimer = Timer.scheduledTimer(withTimeInterval: Tuning.hoverPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollHover() }
        }

        // Re-apply geometry when the user changes panel size in Settings.
        Settings.shared.objectWillChange
            .sink { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.reposition(size: self.store.notchExpanded ? self.expandedFrameSize : Self.collapsedSize)
                }
            }
            .store(in: &cancellables)
    }

    private var outsideSince: Date?
    private var insideSince: Date?

    /// Expand only from the visible collapsed body. Once open, the complete
    /// panel is interactive. Collapse waits for the configured leave dwell.
    private func pollHover() {
        updateFullscreenVisibility()
        let frame = targetFrame == .zero ? panel.frame : targetFrame
        let hot = NotchGeometry.interactionFrame(
            targetFrame: frame, expanded: store.notchExpanded)
        let inside = hot.contains(NSEvent.mouseLocation)
        if store.notchHovering != inside { store.notchHovering = inside }
        if inside {
            outsideSince = nil
            if insideSince == nil { insideSince = Date() }
            if !store.notchExpanded, Settings.shared.expandOnHover,
               Date().timeIntervalSince(insideSince ?? Date()) >= Settings.shared.hoverExpandDelay {
                store.notchExpanded = true
            }
        } else if store.notchExpanded, store.pending.isEmpty, Settings.shared.autoCollapseOnLeave {
            insideSince = nil
            let now = Date()
            if let since = outsideSince {
                if now.timeIntervalSince(since) >= Settings.shared.collapseDwell { collapse(); outsideSince = nil }
            } else {
                outsideSince = now
            }
        } else { insideSince = nil }
    }

    private func updateFullscreenVisibility() {
        updateIdleVisibility()
        if !Settings.shared.hideInFullscreen || !store.pending.isEmpty {
            guard hiddenForFullscreen else { return }
            hiddenForFullscreen = false
            if !hiddenForIdle { panel.orderFrontRegardless() }
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastFullscreenCheck) >= 1 else { return }
        lastFullscreenCheck = now
        let shouldHide = DisplayPolicy.frontmostAppIsFullScreen()
        guard shouldHide != hiddenForFullscreen else { return }
        hiddenForFullscreen = shouldHide
        if shouldHide {
            panel.orderOut(nil)
        } else if !hiddenForIdle {
            panel.orderFrontRegardless()
        }
    }

    /// Hide the whole panel when idle (no live session, nothing pending). A new
    /// event flips `hasLiveSession`/pending and the next poll restores it.
    private func updateIdleVisibility() {
        let shouldHide = PanelVisibilityPolicy.shouldHideWhenIdle(
            enabled: Settings.shared.autoHideWhenIdle,
            hasLiveSession: store.hasLiveSession,
            pendingPresent: !store.pending.isEmpty,
            expanded: store.notchExpanded,
            hovering: store.notchHovering)
        guard shouldHide != hiddenForIdle else { return }
        hiddenForIdle = shouldHide
        if shouldHide {
            panel.orderOut(nil)
        } else if !hiddenForFullscreen {
            panel.orderFrontRegardless()
        }
    }

    func toggle() {
        store.notchExpanded.toggle()
        // Mark an explicit open so a completion reminder timing out won't close it.
        store.notchUserOpened = store.notchExpanded
    }

    /// Collapse the panel and clear the user-opened flag together, so the two
    /// never drift out of sync.
    private func collapse() {
        store.notchExpanded = false
        store.notchUserOpened = false
    }

    /// The screen the panel lives on. Pinned to the menu-bar (primary) screen —
    /// NOT NSScreen.main, which follows keyboard focus and makes the panel jump
    /// between monitors on multi-display setups (breaking hover detection).
    private var homeScreen: NSScreen? { Self.selectedScreen }

    /// The frame the panel is settling toward — hover detection uses this, not
    /// the live (mid-animation) panel.frame, so a quick move during the open/close
    /// animation is judged against the final geometry.
    private var targetFrame: NSRect = .zero

    private func reposition(size: NSSize) {
        guard let screen = homeScreen else { return }
        targetFrame = NotchGeometry.frame(screenFrame: screen.frame, size: size)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Tuning.panelAnimation
            ctx.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }
}

// MARK: - Dark theme

enum Theme {
    static let bg = Color.black
    static let card = Color(white: 0.11)
    static let accent = Color.orange
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.62)
    static let textTertiary = Color(white: 0.4)

    /// Per-agent brand color — used for the source tag AND the pixel buddy so
    /// Claude / Codex / Gemini are distinguishable at a glance.
    static func agentColor(_ source: String) -> Color { AgentCatalog.color(source) }
}

struct NotchView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var usage: UsageReader
    var onOpenSettings: () -> Void = {}
    var onHeightChange: (CGFloat) -> Void = { _ in }

    private var chromeHeight: CGFloat {
        var h: CGFloat = 40   // header
        if !store.warning.isEmpty { h += 20 }
        if Settings.shared.showUsage, !usage.snapshot.isEmpty { h += 46 }
        return h
    }

    var body: some View {
        Group {
            if store.notchExpanded {
                VStack(spacing: 0) {
                    header
                    if !store.warning.isEmpty {
                        Text("⚠ \(store.warning)")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    if Settings.shared.showUsage, !usage.snapshot.isEmpty {
                        UsageBar(snapshot: usage.snapshot)
                    }
                    SessionListView(
                        store: store,
                        maxHeight: CGFloat(Settings.shared.panelHeight) - chromeHeight,
                        onHeight: { listH in onHeightChange(chromeHeight + listH) })
                }
                .frame(width: NotchPanel.panelWidth, alignment: .top)
                .padding(.horizontal, NotchGeometry.expandedWingWidth)
                // The content layer carries its own rectangular backgrounds
                // (SessionListView, UsageBar), and .background(in: shape) only
                // clips the background, not the content. Clip the whole expanded
                // surface to the same outline so the bottom-left/right corners
                // stay rounded instead of being overpainted as right angles.
                .clipShape(NotchShape(
                    topRadius: NotchGeometry.expandedWingWidth,
                    bottomRadius: 14))
                .background(Theme.bg, in: NotchShape(
                    topRadius: NotchGeometry.expandedWingWidth,
                    bottomRadius: 14))
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else {
                collapsedPill
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: store.notchExpanded)
        // Hover is handled by NotchPanel's cursor-geometry polling, not .onHover
        // (which flickers during the expand animation).
    }

    /// Top bar with sound toggle + settings gear (settings is always
    /// reachable from the panel, not a hard-to-find menu-bar icon).
    private var header: some View {
        HStack(spacing: 5) {
            AnimatedCoral(working: anyWorking, size: 13)
            Text("Atoll").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            Spacer()
            if store.removableCompletedSessionCount > 0 {
                Button { store.removeCompletedSessions() } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("清理已完成会话")
                .accessibilityLabel("清理已完成会话")
            }
            Button { SoundPlayer.enabled.toggle() } label: {
                Image(systemName: SoundPlayer.enabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }.buttonStyle(.plain)
            Button { onOpenSettings() } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
    }

    /// Compact native status line: one primary Agent, its current action, and a
    /// count. Do not render one icon per session here; that makes the collapsed
    /// island noisy and wider than the camera housing.
    private var collapsedPill: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 5) {
                if let session = primarySession {
                    AgentBuddy(source: session.source, state: session.state, size: 9)
                }
                if anyWorking {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(activitySummary)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 3)
                if store.pending.count > 0 {
                    Text("\(store.pending.count)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.red)
                } else if store.hasAttentionState {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                } else if activeCount > 0 {
                    Text(Settings.shared.collapsedStyle == .detailed
                         ? "\(activeCount) 个会话" : "\(activeCount)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: NotchPanel.collapsedContentWidth,
                   height: NotchPanel.collapsedSize.height)
            .padding(.horizontal, NotchGeometry.collapsedWingWidth)
            .background(Theme.bg, in: NotchShape(
                topRadius: NotchGeometry.collapsedWingWidth,
                bottomRadius: 8))
        }
    }

    private var primarySession: AgentSession? {
        store.sorted.first(where: { $0.state != .ended && $0.state != .done })
            ?? store.sorted.first
    }

    private var anyWorking: Bool {
        store.sorted.contains {
            $0.state == .thinking || $0.state == .runningTool || $0.state == .compacting
        }
    }

    private var activeCount: Int {
        store.sorted.filter { $0.state != .ended }.count
    }

    private var activitySummary: String {
        guard let s = primarySession else { return "空闲" }
        if !s.currentTool.isEmpty { return s.currentTool }
        if Settings.shared.collapsedStyle == .detailed {
            return "\(s.displayTitle) · \(s.state.label)"
        }
        return s.state.label
    }

    private func color(for state: SessionState) -> Color {
        switch state {
        case .thinking, .compacting: return .blue
        case .runningTool: return .orange
        case .waitingApproval, .waitingAnswer, .needsAttention: return .red
        case .done: return .green
        case .ended: return .gray
        }
    }
}

/// Usage bar: Claude 5-hour and 7-day rate-limit meters.
struct UsageBar: View {
    let snapshot: UsageSnapshot

    var body: some View {
        HStack(spacing: 12) {
            if let p = snapshot.fiveHourPercent {
                meter(label: "5小时", pct: p, resetsAt: snapshot.fiveHourResetsAt)
            }
            if let p = snapshot.sevenDayPercent {
                meter(label: "7天", pct: p, resetsAt: snapshot.sevenDayResetsAt)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.bg)
    }

    private func meter(label: String, pct: Double, resetsAt: Date?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 9)).foregroundStyle(Theme.textSecondary)
                Text("\(Int(pct))%").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color(pct))
                if let r = resetsAt {
                    Text(resetLabel(r)).font(.system(size: 8)).foregroundStyle(Theme.textTertiary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.card).frame(height: 4)
                    Capsule().fill(color(pct))
                        .frame(width: max(2, geo.size.width * pct / 100), height: 4)
                }
            }
            .frame(width: 90, height: 4)
        }
    }

    private func color(_ pct: Double) -> Color {
        pct >= 90 ? .red : pct >= 70 ? .orange : .green
    }

    private func resetLabel(_ date: Date) -> String {
        let secs = Int(date.timeIntervalSinceNow)
        if secs <= 0 { return "已重置" }
        if secs < 3600 { return "\(secs / 60)m 后重置" }
        if secs < 86400 { return "\(secs / 3600)h 后重置" }
        return "\(secs / 86400)d 后重置"
    }
}
