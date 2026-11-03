// LoginItem.swift - "Open at login" via a per-user LaunchAgent (works for unsandboxed apps on macOS 13+,
// and is the same file install.sh writes, so both stay in sync).
import Foundation

enum LoginItem {
    static let label = "com.evilork.thermalbar"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    static func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Writes or removes the agent. It takes effect at the next login; nothing is launched now.
    static func setEnabled(_ enabled: Bool, appPath: String) throws {
        let url = plistURL
        if !enabled {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        guard appPath.hasSuffix(".app"), !appPath.contains("\n") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-a", appPath],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
