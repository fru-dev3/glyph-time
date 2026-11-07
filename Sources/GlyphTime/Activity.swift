import Foundation

// Where the time went between sessions and inside them: which app was in front, its window's title,
// and for a browser the tab's title and site. Plain lines, one per span, written when the span ends,
// to `<time folder>/activity/<YYYY-MM-DD>.<host>.jsonl` (each Mac its own file, like the sessions).
// Foundation only, so the check runs it as a script:
//     cat Sources/GlyphTime/Activity.swift ActivityCheck.swift | swift -
//
//     {"app":"Safari","bundle":"com.apple.Safari","domain":"example.com","end":"2026-10-27T09:14:10-05:00","host":"laptop-local","project":"acme-api","start":"2026-10-27T09:12:04-05:00","title":"Example Domain"}
//     {"app":"Preview","bytes":182044,"end":"2026-10-27T09:15:00-05:00","file":"captures/2026-10-27/091500.laptop-local.jpg","host":"laptop-local","kind":"shot","start":"2026-10-27T09:15:00-05:00"}

/// What was in front at one moment.
struct Front: Equatable, Sendable {
    var app: String
    var bundle: String?
    /// The window's title (a browser: the tab's).
    var title: String?
    /// A browser's site, "example.com".
    var domain: String?
    /// A private or incognito browser window: only the app is kept.
    var isPrivate = false
}

/// One stretch of time on one thing, or (kind "shot" or "clip") a screen capture taken then.
struct ActivitySpan: Codable, Equatable, Sendable {
    var start: Date
    var end: Date
    var host: String
    var app: String
    var bundle: String?
    var title: String?
    var domain: String?
    /// The project of the session running then, if one was.
    var project: String?
    /// True for a private window (no title or site kept).
    var `private`: Bool?
    /// Nil for time on something; "shot" or "clip" for a capture.
    var kind: String?
    /// A capture's file, relative to the time folder.
    var file: String?
    var bytes: Int?

    var seconds: TimeInterval { kind == nil ? max(0, end.timeIntervalSince(start)) : 0 }
}

/// What may be kept: excluded apps and sites leave nothing, private windows only their app.
enum ActivityRules {
    /// Never recorded unless taken off the list in Settings.
    static let defaultExcluded = ["1Password", "Keychain Access", "Passwords"]
    static let browsers = ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.beta",
                           "com.brave.Browser", "com.microsoft.edgemac"]
    /// What browsers put in a private window's title.
    static let privateMarks = ["private browsing", "incognito", "inprivate", "\u{2014} private", "- private"]
    static let maxTitle = 160

    static func isPrivate(title: String?) -> Bool {
        guard let t = title?.lowercased() else { return false }
        return privateMarks.contains { t.contains($0) }
    }

    /// "https://www.example.com/a?b" -> "example.com". Nil for anything without a web host.
    static func domain(_ url: String?) -> String? {
        guard let url, let host = URL(string: url)?.host(), url.hasPrefix("http") else { return nil }
        let h = host.lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// The exclude list as typed: one per line or comma, any case.
    static func list(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    /// An app by name or bundle id, or a site and its subdomains.
    static func excluded(_ f: Front, _ list: [String]) -> Bool {
        let app = f.app.lowercased(), bundle = f.bundle?.lowercased(), domain = f.domain?.lowercased()
        return list.contains { e in
            e == app || e == bundle || (domain.map { $0 == e || $0.hasSuffix("." + e) } ?? false)
        }
    }

    /// What is kept of a front: nil when nothing may be, the app alone for a private window.
    static func keep(_ f: Front?, excluded list: [String]) -> Front? {
        guard var f, !f.app.isEmpty, !excluded(f, list) else { return nil }
        if f.isPrivate || isPrivate(title: f.title) {
            f.isPrivate = true; f.title = nil; f.domain = nil
        }
        if let t = f.title?.trimmingCharacters(in: .whitespacesAndNewlines) {
            f.title = t.isEmpty ? nil : String(t.prefix(maxTitle))
        }
        return f
    }

    /// A capture may be taken: someone is there, and nothing excluded or private is in front.
    static func mayCapture(_ f: Front?, excluded list: [String], away: Bool) -> Bool {
        guard !away, let kept = keep(f, excluded: list) else { return false }
        return !kept.isPrivate
    }
}

/// Turns samples of what is in front into spans. A span ends when the front changes, when you go
/// away (dated when you left), at midnight (so each day's file holds its own time), or when samples
/// stop coming (the Mac slept): then it ends at the last sample.
struct Tracker {
    struct Open: Equatable { var front: Front; var project: String?; var start: Date; var seen: Date }
    var open: Open?
    var host: String
    /// Shorter than this is a flick through, not time spent.
    var minimum: TimeInterval = 2
    /// Samples further apart than this mean the Mac wasn't watching.
    var gap: TimeInterval = 90

    init(host: String) { self.host = host }

    /// One sample. `front` is what may be kept (`ActivityRules.keep`), nil for nothing; `awaySince`
    /// is when input stopped, when you count as away (idle, locked, asleep).
    mutating func sample(_ front: Front?, project: String?, at now: Date, awaySince: Date? = nil) -> [ActivitySpan] {
        var out: [ActivitySpan] = []
        if var o = open {
            if let away = awaySince {
                out += close(o, at: max(o.start, min(away, now))); open = nil
            } else if now.timeIntervalSince(o.seen) > gap {
                out += close(o, at: o.seen); open = nil
            } else if front != o.front || project != o.project {
                out += close(o, at: now); open = nil
            } else {
                o.seen = now; open = o
            }
        }
        if open == nil, awaySince == nil, let front {
            open = Open(front: front, project: project, start: now, seen: now)
        }
        return out
    }

    /// Ends the open span now (quit, sleep, tracking turned off).
    mutating func flush(at now: Date) -> [ActivitySpan] {
        guard let o = open else { return [] }
        open = nil
        return close(o, at: now.timeIntervalSince(o.seen) > gap ? o.seen : now)
    }

    /// The span from its start to `end`, cut at each midnight between; flicks dropped.
    private func close(_ o: Open, at end: Date) -> [ActivitySpan] {
        var out: [ActivitySpan] = [], from = o.start
        let cal = Calendar.current
        while from < end {
            let next = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: from))! // the next midnight, DST or not
            let to = min(end, next)
            let piece = ActivitySpan(start: from, end: to, host: host, app: o.front.app, bundle: o.front.bundle, title: o.front.title,
                                     domain: o.front.domain, project: o.project?.isEmpty == false ? o.project : nil,
                                     private: o.front.isPrivate ? true : nil)
            if piece.seconds >= minimum { out.append(piece) }
            from = to
        }
        return out
    }
}

/// The files: `<folder>/<YYYY-MM-DD>.<host>.jsonl`, appended, never rewritten.
enum ActivityLog {
    static func day(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func line(_ s: ActivitySpan) -> Data? {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { d, enc in
            var c = enc.singleValueContainer()
            let f = ISO8601DateFormatter(); f.timeZone = .current
            try c.encode(f.string(from: d))
        }
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? e.encode(s) else { return nil }
        data.append(0x0A)
        return data
    }

    static func append(_ spans: [ActivitySpan], to folder: URL) throws {
        guard !spans.isEmpty else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, group) in Dictionary(grouping: spans, by: { "\(day($0.start)).\($0.host).jsonl" }) {
            let file = folder.appending(path: name)
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
            let h = try FileHandle(forWritingTo: file)
            defer { try? h.close() }
            try h.seekToEnd()
            for s in group { if let d = line(s) { try h.write(contentsOf: d) } }
        }
    }

    /// Every Mac's lines for these days; a line that doesn't read is skipped.
    static func read(_ folder: URL, days: [String]) -> [ActivitySpan] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let want = Set(days)
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        var out: [ActivitySpan] = []
        for n in names where n.hasSuffix(".jsonl") && want.contains(String(n.prefix(10))) {
            guard let text = try? String(contentsOf: folder.appending(path: n), encoding: .utf8) else { continue }
            for l in text.split(separator: "\n") {
                if let s = try? d.decode(ActivitySpan.self, from: Data(l.utf8)) { out.append(s) }
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// The days from `start` up to (not including) `end`.
    static func days(_ start: Date, _ end: Date) -> [String] {
        var out: [String] = [], d = Calendar.current.startOfDay(for: start)
        while d < end, out.count < 400 {
            out.append(day(d))
            d = Calendar.current.date(byAdding: .day, value: 1, to: d)!
        }
        return out
    }
}

/// History's arithmetic over spans: top apps, sites and windows (by project).
enum ActivityMath {
    struct Row: Identifiable, Equatable, Sendable { var name: String; var seconds: TimeInterval; var bundle: String?; var id: String { name } }
    struct Group: Identifiable, Equatable, Sendable { var project: String; var seconds: TimeInterval; var titles: [Row]; var id: String { project } }
    static let noSession = "Outside a session"

    static func total(_ spans: [ActivitySpan]) -> TimeInterval { spans.reduce(0) { $0 + $1.seconds } }

    static func apps(_ spans: [ActivitySpan]) -> [Row] {
        rank(spans) { $0.app }.map { r in Row(name: r.name, seconds: r.seconds, bundle: spans.first { $0.app == r.name }?.bundle) }
    }

    static func sites(_ spans: [ActivitySpan]) -> [Row] { rank(spans) { $0.domain } }

    /// Each project's top windows (a browser's by its tab), projects by time.
    static func windows(_ spans: [ActivitySpan], top: Int = 4) -> [Group] {
        let byProject = Dictionary(grouping: spans.filter { $0.kind == nil }) { $0.project ?? noSession }
        return byProject.map { p, list in
            Group(project: p, seconds: total(list), titles: Array(rank(list) { s in s.title.map { "\($0) (\(s.app))" } }.prefix(top)))
        }
        .filter { $0.seconds > 0 }
        .sorted { ($0.project == noSession ? 1 : 0, -$0.seconds) < ($1.project == noSession ? 1 : 0, -$1.seconds) }
    }

    private static func rank(_ spans: [ActivitySpan], _ key: (ActivitySpan) -> String?) -> [Row] {
        var sum: [String: TimeInterval] = [:]
        for s in spans where s.kind == nil { if let k = key(s), !k.isEmpty { sum[k, default: 0] += s.seconds } }
        return sum.map { Row(name: $0.key, seconds: $0.value) }.sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.name < $1.name }
    }

    /// "2 h 5 min", "12 min", "40 s".
    static func span(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        if m < 1 { return "\(Int(s)) s" }
        return m >= 60 ? (m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min") : "\(m) min"
    }

    /// The day's top apps and sites, for the summary Studio and agents read.
    static func summary(_ spans: [ActivitySpan], top: Int = 8) -> String {
        let apps = apps(spans), sites = sites(spans)
        guard !apps.isEmpty else { return "" }
        var s = "\n## Today by app\n\n"
        for a in apps.prefix(top) { s += "- \(a.name): \(span(a.seconds))\n" }
        if !sites.isEmpty {
            s += "\n## Today by site\n\n"
            for a in sites.prefix(top) { s += "- \(a.name): \(span(a.seconds))\n" }
        }
        return s
    }
}

/// Screen captures: a daily size limit (over it, skip; never delete), and moving old days aside.
enum CaptureFiles {
    /// Bytes in one day's folder.
    static func bytes(_ folder: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.reduce(0) { sum, n in
            sum + ((try? FileManager.default.attributesOfItem(atPath: folder.appending(path: n).path)[.size] as? Int) ?? 0)
        }
    }

    static func count(_ folder: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.count
    }

    /// Room for another capture today.
    static func allows(used: Int, budgetMB: Int) -> Bool { budgetMB > 0 && used < budgetMB * 1_000_000 }

    /// Day folders (`YYYY-MM-DD`) older than `days` days.
    static func older(than days: Int, in captures: URL, now: Date) -> [URL] {
        let cut = ActivityLog.day(Calendar.current.date(byAdding: .day, value: -days, to: now)!)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: captures.path)) ?? []
        return names.filter { $0.count == 10 && $0.first?.isNumber == true && $0 < cut }.sorted().map { captures.appending(path: $0) }
    }

    /// Moves those day folders into `<time folder>/archived-<today>/captures/`, merging into a day
    /// already there. Nothing is deleted. Returns how many days moved.
    @discardableResult
    static func archive(_ folders: [URL], timeFolder: URL, now: Date) throws -> Int {
        let fm = FileManager.default
        let target = timeFolder.appending(path: "archived-\(ActivityLog.day(now))/captures")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        var moved = 0
        for f in folders {
            let dest = target.appending(path: f.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                for n in (try? fm.contentsOfDirectory(atPath: f.path)) ?? [] where !fm.fileExists(atPath: dest.appending(path: n).path) {
                    try fm.moveItem(at: f.appending(path: n), to: dest.appending(path: n))
                }
                if ((try? fm.contentsOfDirectory(atPath: f.path)) ?? []).isEmpty { try? fm.removeItem(at: f) } // only an empty folder
            } else {
                try fm.moveItem(at: f, to: dest)
            }
            moved += 1
        }
        return moved
    }
}
