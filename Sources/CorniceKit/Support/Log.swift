import Foundation
import OSLog

/// Log categories for each part of the app. Redact credentials before logging them;
/// Redaction has helpers for that.
public enum Log {
    public static let subsystem = "dev.cornice.app"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let window = Logger(subsystem: subsystem, category: "window")
    public static let telemetry = Logger(subsystem: subsystem, category: "telemetry")
    public static let process = Logger(subsystem: subsystem, category: "process")
    public static let settings = Logger(subsystem: subsystem, category: "settings")
    public static let media = Logger(subsystem: subsystem, category: "media")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
}

/// Helpers for producing log-safe representations of sensitive values.
public enum Redaction {
    /// Use a short fingerprint to compare credentials in logs without printing the full
    /// token.
    public static func fingerprint(_ secret: String) -> String {
        guard !secret.isEmpty else { return "<empty>" }
        var hash: UInt32 = 2_166_136_261
        for byte in secret.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        let prefix = secret.prefix(while: { $0 != "_" })
        let scheme = prefix.count < secret.count ? String(prefix) : "token"
        return "\(scheme)…(len:\(secret.count),#\(String(format: "%04x", hash & 0xFFFF)))"
    }

    /// Strips the user's home directory from a path so logs do not leak the
    /// account short name.
    public static func path(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard !home.isEmpty, path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
