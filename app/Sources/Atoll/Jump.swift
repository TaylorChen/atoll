import AppKit

/// Click-to-jump: locate the terminal tab hosting a session by its tty.
/// Precise match for iTerm2 and Terminal.app; falls back to activating the app.
/// First use triggers the macOS Automation permission prompt.
enum JumpEngine {
    static func jump(to session: AgentSession) {
        // Validate the tty before interpolating it into AppleScript source, so a
        // malformed/hostile tty value can't inject script. Real ttys look like
        // /dev/ttys012 — allow only that shape.
        let tty = session.tty
        guard !tty.isEmpty, isValidTTY(tty) else {
            NSLog("Jump: no valid tty for session \(session.id); nothing to do")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            if runAppleScript(iterm2Script(tty: tty)) == "ok" { return }
            if runAppleScript(terminalScript(tty: tty)) == "ok" { return }
            DispatchQueue.main.async {
                // Fallback: bring the most likely terminal forward.
                for name in ["iTerm2", "iTerm", "Terminal"] {
                    if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
                        app.activate()
                        return
                    }
                }
            }
        }
    }

    /// A device tty path: /dev/tty… or /dev/pts/… with only safe characters.
    private static func isValidTTY(_ tty: String) -> Bool {
        guard tty.hasPrefix("/dev/"), tty.count < 40 else { return false }
        return tty.allSatisfy { $0.isLetter || $0.isNumber || $0 == "/" }
    }

    private static func runAppleScript(_ source: String) -> String {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("Jump AppleScript error: \(error)") }
        return result?.stringValue ?? ""
    }

    private static func iterm2Script(tty: String) -> String {
        """
        if application "iTerm2" is not running then return "no"
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select s
                            select t
                            select w
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "no"
        """
    }

    private static func terminalScript(tty: String) -> String {
        """
        if application "Terminal" is not running then return "no"
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set frontmost of w to true
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "no"
        """
    }
}
