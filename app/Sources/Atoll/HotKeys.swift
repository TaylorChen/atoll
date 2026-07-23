import AppKit
import Carbon.HIToolbox

/// Global hotkeys (Carbon, no external deps), driven by the configurable
/// `HotKeyConfig` registry. A registration that the system rejects is recorded
/// so the failure is visible in Settings rather than silently missing.
@MainActor
final class HotKeys {
    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private let store: SessionStore
    var togglePanel: (() -> Void)?

    /// Actions whose Carbon registration failed (already-taken combo, etc.).
    private(set) var registrationFailures: Set<HotKeyAction> = []

    init(store: SessionStore) {
        self.store = store
        NotificationCenter.default.addObserver(forName: .atollHotkeysChanged, object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func register() {
        unregister()
        guard HotKeyConfig.enabled else { HotKeyStatus.shared.registrationFailures = []; return }
        installHandlerIfNeeded()
        let mods = HotKeyConfig.modifier.carbonFlags
        for (index, action) in HotKeyAction.allCases.enumerated() {
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: OSType(0x41544C4C /* "ATLL" */), id: UInt32(index + 1))
            let status = RegisterEventHotKey(HotKeyConfig.keyCode(for: action), mods, hkID,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, ref != nil {
                refs.append(ref)
            } else {
                registrationFailures.insert(action)
            }
        }
        HotKeyStatus.shared.registrationFailures = registrationFailures
    }

    /// Re-read the config and re-register (called after Settings changes).
    func reload() { register() }

    private func unregister() {
        for ref in refs { if let ref { UnregisterEventHotKey(ref) } }
        refs.removeAll()
        registrationFailures.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let me = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in me.fire(index: hkID.id) }
            return noErr
        }, 1, &eventType, selfPtr, &handler)
    }

    private func fire(index: UInt32) {
        let i = Int(index) - 1
        guard i >= 0, i < HotKeyAction.allCases.count else { return }
        perform(HotKeyAction.allCases[i])
    }

    private func perform(_ action: HotKeyAction) {
        switch action {
        case .togglePanel:
            togglePanel?()
        case .collapse:
            store.notchExpanded = false
        case .cycleForward, .cycleBackward:
            let ids = store.sorted.map(\.id)
            let next = SessionSwitcher.step(ids: ids, current: store.selectedSessionID,
                                            forward: action == .cycleForward)
            store.selectedSessionID = next
            if next != nil { store.notchExpanded = true }
        case .jump:
            if let id = store.selectedSessionID ?? store.sorted.first?.id,
               let s = store.sessions[id] {
                JumpEngine.jump(to: s)
            }
        case .approve, .deny, .alwaysAllow, .autoApprove:
            // Guard: these are no-ops with nothing pending.
            guard let req = store.pending.first(where: { $0.kind == .approval }) else { return }
            switch action {
            case .approve: store.decide(req.id, .allow)
            case .deny: store.decide(req.id, .deny(reason: ""))
            case .alwaysAllow: store.decide(req.id, .alwaysAllow)
            case .autoApprove: store.setBypass(req.sessionKey, true)
            default: break
            }
        }
    }
}
