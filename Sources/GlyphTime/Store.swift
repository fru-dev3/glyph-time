import AppKit
import GlyphVault
import SystemConfiguration

/// Where the sessions go: `<vault>/data/apps/time/sessions/` in a Glyph Studio vault, a hidden
/// `.glyph-time/sessions/` in any other folder chosen in Settings, and Application Support when
/// none is chosen. One file per month per Mac (`TimeLog`).
enum Store {
    /// Same host naming as Glyph Jot and Studio's streams: "Mac-Name.local" -> "mac-name-local".
    /// From the Mac's own Bonjour name, never DNS (a DNS lookup can hang for minutes).
    static let host: String = {
        if let test = ProcessInfo.processInfo.environment["GLYPH_TIME_HOST"] { return test }
        let name = SCDynamicStoreCopyLocalHostName(nil) as String? ?? "mac"
        return (name + ".local").lowercased().replacingOccurrences(of: ".", with: "-")
    }()

    static let device = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"

    /// The folder chosen in Settings, else this Mac's vault (`LocalVault`).
    static var chosen: URL? {
        guard let path = UserDefaults.standard.string(forKey: "folder") ?? LocalVault.path,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(filePath: path)
    }

    /// The chosen folder when it is a Glyph Studio vault (it has `data/domains`).
    static var vault: URL? {
        chosen.flatMap { FileManager.default.fileExists(atPath: $0.appending(path: "data/domains").path) ? $0 : nil }
    }

    static var folder: URL {
        vault?.appending(path: "data/apps/time/sessions")
            ?? chosen?.appending(path: ".glyph-time/sessions")
            ?? URL.applicationSupportDirectory.appending(path: "Glyph Time/sessions")
    }

    /// A line that can't be written is said once in the menu, never lost silently.
    private(set) static var problem: String?

    static func write(_ event: TimeEvent) {
        do {
            try TimeLog.append(event, to: folder)
            problem = nil
        } catch {
            problem = "Can't save to \(folder.path): \(error.localizedDescription)"
            log.error("write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func recent() -> [TimeEvent] { TimeLog.read(folder, months: TimeLog.recentMonths()) }

    /// In a Glyph Studio vault with a time domain: the hours by project for today, this week and
    /// last week, every device, at `data/domains/time/source/apps/time/summary.md`, where Studio
    /// reads a domain's sources. Written only when it changed.
    // ponytail: each Mac rewrites it from the same merged files; a hub-only writer if syncs ever clash.
    static func writeSummary() {
        guard let vault, FileManager.default.fileExists(atPath: vault.appending(path: "data/domains/time").path) else { return }
        let file = vault.appending(path: "data/domains/time/source/apps/time/summary.md")
        let text = TimeLog.summary(TimeLog.sessions(TimeLog.read(folder, months: TimeLog.recentMonths())))
        guard (try? String(contentsOf: file, encoding: .utf8)) != text else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            log.error("summary failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
