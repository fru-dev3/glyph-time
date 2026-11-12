import AppKit
import GlyphVault
import SystemConfiguration

/// Where the sessions go: `<vault>/data/apps/time/sessions/` in a Glyph Bot vault, a hidden
/// `.glyph-time/sessions/` in any other folder chosen in Settings, and Application Support when
/// none is chosen or the folder is away. One file per month per Mac (`TimeLog`).
///
/// Application Support is an **outbox, never a second store** (Fru, 2026-10-31: "if vault is taken
/// away, writing locally, that's fine. Writing locally and then can sync it back to the vault").
/// Lines written while the vault is unreachable are folded into it the moment it is back, same
/// file names, same lines, so nothing is lost and nothing is written twice.
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

    /// The chosen folder when it is a Glyph Bot vault (it has `data/domains`).
    static var vault: URL? {
        chosen.flatMap { FileManager.default.fileExists(atPath: $0.appending(path: "data/domains").path) ? $0 : nil }
    }

    static var folder: URL {
        vault?.appending(path: "data/apps/time/sessions")
            ?? chosen?.appending(path: ".glyph-time/sessions")
            ?? outbox
    }

    /// Where lines wait when the chosen folder or vault can't be reached. Application Support,
    /// or the folder given with `-support` (the UI check, so a run never touches the real app's).
    static var outbox: URL {
        (UserDefaults.standard.string(forKey: "support").map { URL(filePath: $0) }
            ?? URL.applicationSupportDirectory.appending(path: "Glyph Time")).appending(path: "sessions")
    }

    /// True while the sessions are going to the folder that was chosen, not to the outbox.
    static var connected: Bool { chosen != nil }

    /// What the shared vault view shows: where it writes, when it last did, and how many lines
    /// are still waiting in the outbox.
    static var vaultPath: String? { chosen?.path }
    private(set) static var lastWrite: Date?
    static var waiting: Int {
        guard connected else { return 0 } // while away, the outbox is simply where it writes
        return outboxFiles().reduce(0) { $0 + TimeLog.events(in: (try? Data(contentsOf: $1)) ?? Data()).count }
    }

    /// The session lines still waiting. The outbox holds whole folders, not one: `sessions/`
    /// beside `activity/` and `captures/`, exactly as the vault does, because Tracking and
    /// Captures hang off the same folder (`Store.folder`'s parent).
    static func outboxFiles() -> [URL] { waitingRoots().flatMap { logs(in: "sessions", under: $0) } }

    private static var outboxRoot: URL { outbox.deletingLastPathComponent() }
    private static var liveRoot: URL { folder.deletingLastPathComponent() }

    /// Every root this Mac has written to. Changing the folder in Settings would otherwise strand
    /// everything written to the old one: nothing points at it any more, so nothing folds it back.
    /// Kept here rather than worked out, because a folder no longer chosen cannot be derived from
    /// one that is (the sweep below covers the rest without remembering anything).
    static let rootsKey = "knownRoots"
    static var knownRoots: [String] {
        get { UserDefaults.standard.stringArray(forKey: rootsKey) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.suffix(10)), forKey: rootsKey) }
    }

    /// Written to, so remembered. Called after a line lands, never before: a root that was never
    /// written to holds nothing to come back for.
    private static func remember(_ root: URL) {
        var roots = knownRoots
        guard !roots.contains(root.path) else { return }
        roots.append(root.path)
        knownRoots = roots
    }

    /// Everywhere this Mac may have left lines, newest last, with the one it writes to now taken
    /// out. Three ways a folder stops being the one in use, and all three end up here:
    /// the vault going away (the outbox), a chosen folder gaining a vault underneath it (the hidden
    /// `.glyph-time` beside it), and a different folder being chosen in Settings (remembered).
    private static func waitingRoots() -> [URL] {
        var roots = [outboxRoot]
        if let chosen { roots.append(chosen.appending(path: ".glyph-time")) }
        roots += knownRoots.map { URL(filePath: $0) }
        let live = liveRoot.standardizedFileURL.path
        var seen = Set<String>()
        return roots.filter { root in
            let path = root.standardizedFileURL.path
            guard path != live, seen.insert(path).inserted else { return false }
            return FileManager.default.fileExists(atPath: path)
        }
    }

    private static func logs(in part: String, under root: URL) -> [URL] {
        guard root.standardizedFileURL != liveRoot.standardizedFileURL else { return [] } // away: it IS where it writes
        let dir = root.appending(path: part)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".jsonl") }.sorted().map { dir.appending(path: $0) }
    }

    /// Folds the outbox into the folder that is back, by file shape, never by folder:
    /// - `sessions/` and `activity/` are append-only logs, one file per month or day per host, so
    ///   they fold line by line into the file of the same name, skipping any line already there
    ///   (lines are written with sorted keys, so the same event is the same bytes).
    /// - everything else is whole files (`captures/<day>/` images, `projects/<name>.md` notes,
    ///   `exports/`, an `archived-<date>/`), so each moves only into a name that is free, and is
    ///   never appended to or written over. A shape nobody has thought of yet is treated this way
    ///   too, so the worst it can do is wait.
    ///
    /// Safe to run twice and safe to interrupt: a half-done drain repeats without writing anything
    /// twice, and a file is taken away only once its bytes are in the vault. The line-by-line skip
    /// is what makes that true, and not only after a crash: if taking the file away fails (a folder
    /// gone read-only), the next drain writes nothing rather than a second copy of every line.
    /// (The shapes, and why a single append-everything sweep corrupts whole-file data: Glyph Well,
    /// 2026-10-31.)
    @discardableResult
    static func drainOutbox() -> Int {
        var moved = 0
        for root in waitingRoots() { moved += drain(root) }
        return moved
    }

    /// One waiting root into the one in use.
    private static func drain(_ root: URL) -> Int {
        var moved = 0
        do {
            for part in ["sessions", "activity"] {
                for file in logs(in: part, under: root) { moved += try fold(file, into: liveRoot.appending(path: part)) }
            }
            // The bug is never "the fallback folder", it is every shape in it (Glyph Jot, 2026-10-31):
            // Tracking, Captures, the project notes and the exports all hang off this one root.
            // The shapes Time owns, named rather than discovered. Carrying everything a folder
            // held swept up what the app keeps for itself and moved it mid-flight: a reminder lost
            // its fifteen-minute warning that way. The bug is still every shape in the folder, but
            // the folder is Time’s, so Time names its shapes.
            for part in ["captures", "projects", "exports"] {
                moved += try carry(root.appending(path: part), into: liveRoot.appending(path: part))
            }
        } catch {
            problem = "Can't move what is waiting into \(liveRoot.path): \(error.localizedDescription)"
            log.error("outbox drain failed: \(error.localizedDescription, privacy: .public)")
        }
        if moved > 0 { log.info("outbox: \(moved, privacy: .public) folded into the vault") }
        return moved
    }

    /// One append-only log, line by line into the file of its own name. The source goes away only
    /// after the bytes are written, so an interrupted fold strands lines again rather than losing them.
    private static func fold(_ file: URL, into dir: URL) throws -> Int {
        guard let data = try? Data(contentsOf: file) else {
            log.error("outbox: can't read \(file.lastPathComponent, privacy: .public), left where it is")
            return 0 // left where it is: waiting is recoverable, and silence is not
        }
        let newline = UInt8(0x0A)
        let target = dir.appending(path: file.lastPathComponent)
        let already = (try? Data(contentsOf: target)) ?? Data()
        let there = Set(already.split(separator: newline).map { Data($0) })
        let lines = data.split(separator: newline).map { Data($0) }.filter { !there.contains($0) }
        if !lines.isEmpty {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: target.path) { FileManager.default.createFile(atPath: target.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            try handle.seekToEnd()
            // A write cut short leaves the file without its last newline; without this the first
            // folded line would run into it and both become one unreadable line. (Glyph Jot, 2026-10-31.)
            if let end = already.last, end != newline { try handle.write(contentsOf: Data([newline])) }
            for line in lines { try handle.write(contentsOf: line + Data([newline])) }
            try handle.close() // closed before reading it back, not left to the defer
        }
        // Read the file back and confirm every line of the outbox file is in it before unlinking.
        // A write that throws is caught by the caller, but one that silently fell short would take
        // the only copy of those lines with it, and a fold that loses a session is worse than one
        // that never ran. If anything is missing the outbox file stays and the next drain retries:
        // the lines already written are skipped by the same byte comparison, so a retry is free.
        let landed = Set(((try? Data(contentsOf: target)) ?? Data()).split(separator: newline).map { Data($0) })
        let mine = Set(data.split(separator: newline).map { Data($0) })
        guard mine.isSubset(of: landed) else {
            problem = "Kept \(file.lastPathComponent): not every line reached \(dir.path), so nothing was taken away."
            log.error("outbox: \(mine.subtracting(landed).count, privacy: .public) line(s) did not land in \(file.lastPathComponent, privacy: .public); kept")
            return 0
        }
        try FileManager.default.removeItem(at: file)
        return lines.count
    }

    /// Whole files, at any depth: a capture inside its day folder, a project note, an export.
    /// Each moves only into a name that is free. A name already taken is left where it is and not
    /// merged, because merging two of them is a guess and the wrong guess quietly drops what was
    /// written (the rule: Glyph Jot's words.json and Glyph Well's records.json, 2026-10-31). An
    /// emptied folder goes away; one still holding something of its own stays.
    private static func carry(_ dir: URL, into live: URL) throws -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return 0 } // a loose file: left alone
        var moved = 0
        for name in names.sorted() where !name.hasPrefix(".") {
            let from = dir.appending(path: name), to = live.appending(path: name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: from.path, isDirectory: &isDir)
            if isDir.boolValue {
                // A name that is a folder here and a file there is a taken name like any other:
                // left alone, and the fold carries on past it rather than stopping (Glyph Jot, 2026-10-31).
                var taken: ObjCBool = false
                if fm.fileExists(atPath: to.path, isDirectory: &taken), !taken.boolValue { continue }
                moved += try carry(from, into: to)
                if ((try? fm.contentsOfDirectory(atPath: from.path)) ?? []).isEmpty { try? fm.removeItem(at: from) }
            } else if !fm.fileExists(atPath: to.path) {
                try fm.createDirectory(at: live, withIntermediateDirectories: true)
                try fm.moveItem(at: from, to: to)
                moved += 1
            }
        }
        return moved
    }

    /// A line that can't be written is said once in the menu, never lost silently.
    private(set) static var problem: String?

    static func write(_ event: TimeEvent) {
        if connected { drainOutbox() } // back from an away spell: the waiting lines go in first
        do {
            try TimeLog.append(event, to: folder)
            remember(liveRoot)
            lastWrite = .now
            problem = connected ? nil : "Vault away. Saving here and folding it back when it returns."
        } catch {
            problem = "Can't save to \(folder.path): \(error.localizedDescription)"
            log.error("write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func recent() -> [TimeEvent] { TimeLog.read(folder, months: TimeLog.recentMonths()) }

    /// Every month on disk, for the projects list and its totals.
    // ponytail: reads every file on each refresh; keep a running fold if years of files make it slow.
    static func all() -> [TimeEvent] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return TimeLog.read(folder, months: Set(names.filter { $0.first?.isNumber == true }.map { String($0.prefix(7)) }))
    }

    /// In a Glyph Bot vault with a time domain: the hours by project for today, this week and
    /// last week, every device, at `data/domains/time/source/apps/time/summary.md`, where Studio
    /// reads a domain's sources. Written only when it changed.
    // ponytail: each Mac rewrites it from the same merged files; a hub-only writer if syncs ever clash.
    @MainActor static func writeSummary() {
        guard let vault, FileManager.default.fileExists(atPath: vault.appending(path: "data/domains/time").path) else { return }
        let file = vault.appending(path: "data/domains/time/source/apps/time/summary.md")
        // With Track apps and tabs, today's top apps and sites from every Mac follow the sessions.
        let today = DateInterval(start: Calendar.current.startOfDay(for: .now), end: .now)
        let text = TimeLog.summary(TimeLog.sessions(TimeLog.read(folder, months: TimeLog.recentMonths())))
            + ActivityMath.summary(Activity.read(today, folder: Activity.folder))
        guard (try? String(contentsOf: file, encoding: .utf8)) != text else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            log.error("summary failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
