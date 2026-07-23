import AppKit

/// Event sounds with optional imported custom sound packs.
/// A pack is a folder or .zip containing wav files named by event category
/// (inputRequired.wav / taskComplete.wav / taskError.wav) plus an optional
/// manifest.json {"name": "..."}. Imports land in ~/.atoll/sound-packs/<name>/.
@MainActor
enum SoundPlayer {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "soundEnabled") }
    }

    /// Active pack folder name, or "" for built-in system sounds.
    static var activePack: String {
        get { UserDefaults.standard.string(forKey: "activeSoundPack") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "activeSoundPack") }
    }

    enum Event: String {
        case inputRequired   // approval / question / plan
        case taskComplete
        case taskError

        var systemSound: String {
            switch self {
            case .inputRequired: return "Sosumi"
            case .taskComplete: return "Glass"
            case .taskError: return "Basso"
            }
        }
    }

    private static var packsDir: String {
        NSString(string: "~/.atoll/sound-packs").expandingTildeInPath
    }

    static func play(_ event: Event) {
        guard enabled, !QuietPolicy.isQuiet else { return }
        if !activePack.isEmpty {
            let wav = "\(packsDir)/\(activePack)/\(event.rawValue).wav"
            if FileManager.default.fileExists(atPath: wav),
               let sound = NSSound(contentsOfFile: wav, byReference: true) {
                sound.play()
                return
            }
        }
        NSSound(named: event.systemSound)?.play()
    }

    // MARK: - Pack management

    static func installedPacks() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: packsDir))?
            .filter { !$0.hasPrefix(".") }
            .sorted() ?? []
    }

    /// Import a pack from a folder or .zip. Returns the installed pack name.
    @discardableResult
    static func importPack(from url: URL) -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: packsDir, withIntermediateDirectories: true)

        var sourceDir = url
        var tempExtract: URL?
        if url.pathExtension.lowercased() == "zip" {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("atoll-pack-\(UUID().uuidString)")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            // -j would flatten; keep structure but unzip refuses ../ traversal by
            // default. -o overwrite in the isolated temp dir only.
            p.arguments = ["-q", "-o", url.path, "-d", tmp.path]
            try? p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { try? fm.removeItem(at: tmp); return nil }
            // If the zip wraps a single folder, descend into it.
            let entries = (try? fm.contentsOfDirectory(atPath: tmp.path))?.filter { !$0.hasPrefix("__") && !$0.hasPrefix(".") } ?? []
            sourceDir = (entries.count == 1 && isDir(tmp.appendingPathComponent(entries[0])))
                ? tmp.appendingPathComponent(entries[0]) : tmp
            tempExtract = tmp
        }

        guard let name = packName(in: sourceDir)
                ?? sanitizePackName(url.deletingPathExtension().lastPathComponent) else {
            if let t = tempExtract { try? fm.removeItem(at: t) }
            return nil
        }
        let dest = URL(fileURLWithPath: packsDir).appendingPathComponent(name)
        // Final guard: dest must stay directly under packsDir.
        guard dest.deletingLastPathComponent().path == packsDir else {
            if let t = tempExtract { try? fm.removeItem(at: t) }
            return nil
        }
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: sourceDir, to: dest)
        } catch {
            NSLog("Sound pack import failed: \(error)")
            if let t = tempExtract { try? fm.removeItem(at: t) }
            return nil
        }
        if let t = tempExtract { try? fm.removeItem(at: t) }
        activePack = name
        return name
    }

    private static func packName(in dir: URL) -> String? {
        let manifest = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifest),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = obj["name"] as? String else { return nil }
        return sanitizePackName(name)
    }

    /// Reduce a pack name to a single safe path component (no /, no .., no
    /// leading dot) so a hostile manifest can't escape the packs directory.
    private static func sanitizePackName(_ raw: String) -> String? {
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "..", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned.isEmpty ? nil : String(cleaned.prefix(60))
    }

    private static func isDir(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
