import AppKit
import CoreGraphics

/// Decides when Atoll should stay quiet — no sound, no auto-expand — mirroring
/// Quiet Hours + scene-based suppression. Completion still leaves a dot.
@MainActor
enum QuietPolicy {
    /// User-configured quiet window, e.g. 22:00–08:00 (crosses midnight).
    static var quietHoursEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "quietHoursEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "quietHoursEnabled") }
    }
    static var quietStartHour: Int {
        get { UserDefaults.standard.object(forKey: "quietStartHour") as? Int ?? 22 }
        set { UserDefaults.standard.set(newValue, forKey: "quietStartHour") }
    }
    static var quietEndHour: Int {
        get { UserDefaults.standard.object(forKey: "quietEndHour") as? Int ?? 8 }
        set { UserDefaults.standard.set(newValue, forKey: "quietEndHour") }
    }
    static var suppressDuringScreenShare: Bool {
        get { UserDefaults.standard.object(forKey: "suppressDuringScreenShare") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "suppressDuringScreenShare") }
    }
    static var suppressWhenSessionInactive: Bool {
        get { UserDefaults.standard.object(forKey: "suppressWhenSessionInactive") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "suppressWhenSessionInactive") }
    }
    static var suppressAfterWake: Bool {
        get { UserDefaults.standard.object(forKey: "suppressAfterWake") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "suppressAfterWake") }
    }

    /// True when any quiet condition holds right now.
    static var isQuiet: Bool {
        inQuietHours
            || (suppressDuringScreenShare && isScreenMirrored)
            || (suppressWhenSessionInactive && QuietRuntimeState.shared.sessionInactive)
            || (suppressAfterWake && QuietRuntimeState.shared.isInWakeGracePeriod)
    }

    private static var inQuietHours: Bool {
        guard quietHoursEnabled else { return false }
        let hour = Calendar.current.component(.hour, from: Date())
        let start = quietStartHour, end = quietEndHour
        if start == end { return false }
        // Window may cross midnight (e.g. 22 → 8).
        return start < end ? (hour >= start && hour < end)
                           : (hour >= start || hour < end)
    }

    /// Screen mirroring active (screen-share / AirPlay / presenting).
    /// Uses only the public CoreGraphics mirror API to avoid private KVC crashes.
    private static var isScreenMirrored: Bool {
        CGDisplayIsInMirrorSet(CGMainDisplayID()) != 0
    }
}

/// Runtime-only quiet context that cannot be derived from UserDefaults.
@MainActor
final class QuietRuntimeState {
    static let shared = QuietRuntimeState()

    private(set) var sessionInactive = false
    private var wakeGraceUntil = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    var isInWakeGracePeriod: Bool { Date() < wakeGraceUntil }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sessionInactive = true }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sessionInactive = false }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.wakeGraceUntil = Date().addingTimeInterval(15) }
        })
    }
}
