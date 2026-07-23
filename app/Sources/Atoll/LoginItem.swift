import ServiceManagement

/// Launch-at-login via SMAppService (macOS 13+). Only meaningful for the packaged
/// Atoll.app in /Applications — a no-op/failure for the raw SPM debug binary.
enum LoginItem {
    static var enabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("LoginItem toggle failed (expected for non-bundled builds): \(error)")
        }
    }
}
