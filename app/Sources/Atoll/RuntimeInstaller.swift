import Foundation

/// Keeps hook-side helpers in sync with the installed App bundle. Hooks point
/// at a stable ~/.atoll/bin path, while application updates replace the bundle.
enum RuntimeInstaller {
    static func installBundledHelpers() throws {
        guard let resources = Bundle.main.resourceURL else { return }
        let destination = URL(fileURLWithPath: NSString(string: "~/.atoll/bin").expandingTildeInPath)
        try installHelpers(from: resources, to: destination)
    }

    static func installHelpers(from resources: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        for name in ["atoll-bridge", "atoll-statusline.sh"] {
            let source = resources.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let target = destination.appendingPathComponent(name)
            let contents = try Data(contentsOf: source)
            if (try? Data(contentsOf: target)) != contents {
                try contents.write(to: target, options: .atomic)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: target.path)
        }
    }
}
