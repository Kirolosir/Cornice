import Foundation
import OSLog

/// Central logging facade.
///
/// Every subsystem logs through one of these categories so that
/// `log stream --predicate 'subsystem == "dev.cornice.app"'` gives a coherent
/// trace of what the app is doing. Nothing here ever receives a secret: call
/// sites are responsible for passing redacted values, and the helpers in
/// `Redaction` exist to make that easy.
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
    /// Renders a token as a fingerprint that is stable across a session but
    /// reveals nothing useful: `ghp_…(len:40,#a91f)`.
    ///
    /// Used when we genuinely need to correlate "which credential failed"
    /// across log lines without ever writing the credential down.
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
