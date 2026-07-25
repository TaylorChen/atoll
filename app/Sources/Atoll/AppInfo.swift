import Foundation

/// Single source of truth for the app version. Reads the bundle (set by
/// build-app.sh at package time); falls back to "dev" for the SPM debug binary,
/// which has no Info.plist version.
enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
