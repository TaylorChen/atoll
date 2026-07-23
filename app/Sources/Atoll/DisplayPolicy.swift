import AppKit
import CoreGraphics

enum CollapsedStyle: String, CaseIterable, Identifiable {
    case compact
    case detailed

    var id: String { rawValue }
    var label: String { self == .compact ? "紧凑" : "详细" }
}

enum DisplayPolicy {
    static func screenID(_ screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .stringValue ?? screen.localizedName
    }

    static func windowCoversScreen(windowSize: CGSize, screenSize: CGSize,
                                   tolerance: CGFloat = 2) -> Bool {
        abs(windowSize.width - screenSize.width) <= tolerance
            && abs(windowSize.height - screenSize.height) <= tolerance
    }

    static func frontmostAppIsFullScreen() -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]] else { return false }
        let screenSizes = NSScreen.screens.map(\.frame.size)
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat else { return false }
            return screenSizes.contains {
                windowCoversScreen(windowSize: CGSize(width: width, height: height), screenSize: $0)
            }
        }
    }
}
