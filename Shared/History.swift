import Foundation
import GlyphVault
import Observation

/// What a project belongs to: an initiative (a plain label, like a tag) and links to Glyph CRM
/// entities and Glyph Omega goals. Kept as a small note per project, front matter only:
///
///     data/apps/time/projects/acme-api.md
///     ---
///     project: acme-api
///     initiative: Client work
///     entities: [product/acme, goal/g-1a2b3c]
///     ---
///
/// The `entities:` line is the family's convention (Jot, Well, Omega), so Glyph CRM can add ids to
/// it when the user accepts a suggestion. Lines it doesn't know are kept as they are.
struct ProjectNote: Equatable, Sendable {
    var initiative: String?
    var entities: [String] = []

    /// The Omega goals it links to ("g-1a2b3c"), from `goal/<id>` entities.
    var goals: [String] { entities.filter { $0.hasPrefix("goal/") }.map { String($0.dropFirst(5)) } }

    static func parse(_ text: String) -> (project: String, note: ProjectNote)? {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else { return nil }
        var project: String?, note = ProjectNote()
        for line in text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = unquote(String(line[line.index(after: colon)...]))
            switch key {
            case "project": project = value
            case "initiative": note.initiative = value.isEmpty ? nil : value
            case "entities": note.entities = list(value)
            default: break
            }
        }
        guard let project, !project.isEmpty else { return nil }
        return (project, note)
    }

    /// The note's text, written over `old` when there is one: only `project`, `initiative` and
    /// `entities` change; any other line and the body stay.
    static func render(_ project: String, _ note: ProjectNote, over old: String? = nil) -> String {
        var lines = ["project: \(quote(project))"]
        if let i = note.initiative, !i.isEmpty { lines.append("initiative: \(quote(i))") }
        if !note.entities.isEmpty { lines.append("entities: [" + note.entities.map(quote).joined(separator: ", ") + "]") }
        var body = "\n"
        if let old, old.hasPrefix("---\n"), let end = old.range(of: "\n---", range: old.index(old.startIndex, offsetBy: 3)..<old.endIndex) {
            for line in old[old.index(old.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false) {
                let key = line.split(separator: ":").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                if !["project", "initiative", "entities"].contains(key), !line.isEmpty { lines.append(String(line)) }
            }
            body = String(old[end.upperBound...])
        }
        return "---\n" + lines.joined(separator: "\n") + "\n---" + (body.hasPrefix("\n") ? body : "\n" + body)
    }

    static func list(_ value: String) -> [String] {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(separator: ",").map { unquote(String($0)) }.filter { !$0.isEmpty }
    }
    static func unquote(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
    static func quote(_ s: String) -> String {
        s.contains(where: { ",:[]#\"'".contains($0) }) || s.hasPrefix(" ") ? "\"" + s.replacingOccurrences(of: "\"", with: "'") + "\"" : s
    }

    /// "acme-api.md": the project's file name, lower case, dashes for anything else.
    static func fileName(_ project: String) -> String {
        let slug = project.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let s = String(slug).split(separator: "-").joined(separator: "-")
        return (s.isEmpty ? "project" : String(s.prefix(60))) + ".md"
    }

    /// Every project note in a folder, by project name.
    static func read(_ folder: URL) -> [String: ProjectNote] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var out: [String: ProjectNote] = [:]
        for n in names where n.hasSuffix(".md") {
            if let text = try? String(contentsOf: folder.appendingPathComponent(n), encoding: .utf8), let (p, note) = parse(text) { out[p] = note }
        }
        return out
    }
}

/// Today, a week (Monday first), a month, or any days chosen.
enum Period: String, CaseIterable, Identifiable, Sendable {
    case today = "Today", week = "Week", month = "Month", custom = "Custom"
    var id: String { rawValue }
}

/// One slice of a breakdown: a project, an initiative or a goal, with its time and sessions.
struct Slice: Identifiable, Equatable, Sendable {
    var name: String
    var seconds: TimeInterval
    var sessions: Int
    var projects: [String] = []
    var id: String { name }
}

/// The arithmetic behind History, on plain sessions: ranges, breakdowns, trends, text exports.
enum HistoryMath {
    static var calendar: Calendar { var c = Calendar.current; c.firstWeekday = 2; return c }
    static let unnamed = "Unnamed", noInitiative = "No initiative", noGoal = "No goal"

    static func name(_ s: TimeSession) -> String { s.project?.isEmpty == false ? s.project! : unnamed }

    /// [start, end) for a period around `anchor`; custom uses the days given, both included.
    static func range(_ p: Period, anchor: Date, from: Date, to: Date) -> DateInterval {
        let c = calendar
        switch p {
        case .today:
            let d = c.startOfDay(for: anchor)
            return DateInterval(start: d, end: c.date(byAdding: .day, value: 1, to: d)!)
        case .week: return c.dateInterval(of: .weekOfYear, for: anchor)!
        case .month: return c.dateInterval(of: .month, for: anchor)!
        case .custom:
            let a = c.startOfDay(for: min(from, to)), b = c.startOfDay(for: max(from, to))
            return DateInterval(start: a, end: c.date(byAdding: .day, value: 1, to: b)!)
        }
    }

    /// The period just before, for comparing: yesterday, last week, last month, or the same number of days.
    static func previous(_ p: Period, _ r: DateInterval) -> DateInterval {
        let c = calendar
        switch p {
        case .today: return DateInterval(start: c.date(byAdding: .day, value: -1, to: r.start)!, end: r.start)
        case .week: return DateInterval(start: c.date(byAdding: .day, value: -7, to: r.start)!, end: r.start)
        case .month: return c.dateInterval(of: .month, for: c.date(byAdding: .day, value: -1, to: r.start)!)!
        case .custom:
            let days = c.dateComponents([.day], from: r.start, to: r.end).day ?? 1
            return DateInterval(start: c.date(byAdding: .day, value: -days, to: r.start)!, end: r.start)
        }
    }

    static func shift(_ p: Period, _ anchor: Date, by n: Int) -> Date {
        let unit: Calendar.Component = p == .today ? .day : p == .week ? .weekOfYear : .month
        return calendar.date(byAdding: unit, value: n, to: anchor) ?? anchor
    }

    /// "Today", "Yesterday", "Monday 27 October", "This week", "Week of 20 Oct", "October 2026", "1 Oct to 15 Oct".
    static func title(_ p: Period, _ r: DateInterval, now: Date = .now) -> String {
        let c = calendar
        switch p {
        case .today:
            return c.isDate(r.start, inSameDayAs: now) ? "Today" : c.isDateInYesterday(r.start) ? "Yesterday"
                : r.start.formatted(.dateTime.weekday(.wide).day().month(.wide))
        case .week:
            return r.contains(now) ? "This week" : "Week of " + r.start.formatted(.dateTime.day().month(.abbreviated))
        case .month:
            return r.contains(now) ? "This month" : r.start.formatted(.dateTime.month(.wide).year())
        case .custom:
            let last = r.end.addingTimeInterval(-1)
            if c.isDate(r.start, inSameDayAs: last) { return r.start.formatted(.dateTime.day().month(.abbreviated).year()) }
            return r.start.formatted(.dateTime.day().month(.abbreviated)) + " to " + last.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    /// The dates under the title: "27 Oct to 2 Nov 2026".
    static func subtitle(_ p: Period, _ r: DateInterval) -> String {
        let last = r.end.addingTimeInterval(-1)
        if p == .today { return r.start.formatted(.dateTime.weekday(.wide).day().month(.wide).year()) }
        return r.start.formatted(.dateTime.day().month(.abbreviated)) + " to " + last.formatted(.dateTime.day().month(.abbreviated).year())
    }

    static func within(_ list: [TimeSession], _ r: DateInterval) -> [TimeSession] {
        list.filter { $0.start >= r.start && $0.start < r.end }
    }

    static func total(_ list: [TimeSession], now: Date = .now) -> TimeInterval { list.reduce(0) { $0 + $1.active(at: now) } }

    static func byProject(_ list: [TimeSession], now: Date = .now) -> [Slice] {
        group(list, now: now) { [name($0)] }
    }

    /// By initiative: the label on the project's note; projects without one together at the end.
    static func byInitiative(_ list: [TimeSession], notes: [String: ProjectNote], now: Date = .now) -> [Slice] {
        let out = group(list, now: now) { [notes[name($0)]?.initiative ?? noInitiative] }
        return out.filter { $0.name != noInitiative } + out.filter { $0.name == noInitiative }
    }

    /// By Omega goal: a project linked to two goals counts toward both.
    static func byGoal(_ list: [TimeSession], notes: [String: ProjectNote], titles: [String: String], now: Date = .now) -> [Slice] {
        let out = group(list, now: now) { s in
            let g = notes[name(s)]?.goals ?? []
            return g.isEmpty ? [noGoal] : g.map { titles[$0] ?? $0 }
        }
        return out.filter { $0.name != noGoal } + out.filter { $0.name == noGoal }
    }

    private static func group(_ list: [TimeSession], now: Date, keys: (TimeSession) -> [String]) -> [Slice] {
        var out: [String: Slice] = [:]
        for s in list {
            for k in keys(s) {
                var x = out[k] ?? Slice(name: k, seconds: 0, sessions: 0)
                x.seconds += s.active(at: now)
                x.sessions += 1
                if !x.projects.contains(name(s)) { x.projects.append(name(s)) }
                out[k] = x
            }
        }
        return out.values.sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.name < $1.name }
    }

    /// One bar per day (per week once a range is longer than about two months), split by project.
    struct Bar: Identifiable, Sendable { var day: Date; var project: String; var seconds: TimeInterval; var id: String { "\(day.timeIntervalSince1970)\(project)" } }
    static func bars(_ list: [TimeSession], _ r: DateInterval, now: Date = .now) -> (bars: [Bar], unit: Calendar.Component) {
        let c = calendar
        let unit: Calendar.Component = r.duration > 62 * 86_400 ? .weekOfYear : .day
        var sum: [Date: [String: TimeInterval]] = [:]
        for s in list {
            let k = unit == .day ? c.startOfDay(for: s.start) : c.dateInterval(of: .weekOfYear, for: s.start)!.start
            sum[k, default: [:]][name(s), default: 0] += s.active(at: now)
        }
        return (sum.flatMap { d, m in m.map { Bar(day: d, project: $0.key, seconds: $0.value) } }.sorted { $0.day < $1.day }, unit)
    }

    /// The last `count` weeks up to the one holding `now`, each week's total (zero weeks included).
    struct Week: Identifiable, Sendable { var start: Date; var seconds: TimeInterval; var id: Date { start } }
    static func weeks(_ list: [TimeSession], count: Int = 12, now: Date = .now) -> [Week] {
        let c = calendar
        let this = c.dateInterval(of: .weekOfYear, for: now)!.start
        return (0..<count).reversed().map { back in
            let start = c.date(byAdding: .weekOfYear, value: -back, to: this)!
            let end = c.date(byAdding: .weekOfYear, value: 1, to: start)!
            return Week(start: start, seconds: total(within(list, DateInterval(start: start, end: end)), now: now))
        }
    }

    /// A project's numbers across everything on file.
    struct Stats: Equatable, Sendable {
        var total: TimeInterval = 0, sessions = 0, first: Date?, last: Date?
        var average: TimeInterval { sessions == 0 ? 0 : total / Double(sessions) }
    }
    static func stats(_ list: [TimeSession], now: Date = .now) -> Stats {
        Stats(total: total(list, now: now), sessions: list.count, first: list.map(\.start).min(), last: list.map(\.start).max())
    }

    /// "+1 h 10 min", "-25 min", "same": how a total moved since the period before.
    static func delta(_ now: TimeInterval, _ before: TimeInterval) -> String {
        let d = now - before
        if abs(d) < 60 { return "same" }
        return (d > 0 ? "+" : "-") + TimeLog.span(abs(d))
    }

    // MARK: Export

    /// One row per session: date, start, end, minutes worked, project, initiative, device.
    static func csv(_ list: [TimeSession], notes: [String: ProjectNote], now: Date = .now) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        func cell(_ s: String) -> String { s.contains(where: { ",\"\n".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s }
        var rows = ["start,end,minutes,project,initiative,device"]
        for s in list.sorted(by: { $0.start < $1.start }) {
            rows.append([iso.string(from: s.start), s.end.map(iso.string) ?? "", String(Int((s.active(at: now) / 60).rounded())),
                         cell(name(s)), cell(notes[name(s)]?.initiative ?? ""), cell(s.device ?? s.host)].joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// The period as Markdown: totals by project and initiative, then each day's sessions.
    static func markdown(_ list: [TimeSession], title: String, subtitle: String, notes: [String: ProjectNote], now: Date = .now) -> String {
        var out = "# Glyph Time: \(title)\n\n\(subtitle). \(TimeLog.span(total(list, now: now))) in \(list.count) \(list.count == 1 ? "session" : "sessions").\n\n## By project\n\n"
        out += byProject(list, now: now).map { "- \($0.name): \(TimeLog.span($0.seconds)) (\($0.sessions))" }.joined(separator: "\n")
        let inits = byInitiative(list, notes: notes, now: now)
        if inits.contains(where: { $0.name != noInitiative }) {
            out += "\n\n## By initiative\n\n" + inits.map { "- \($0.name): \(TimeLog.span($0.seconds))" }.joined(separator: "\n")
        }
        out += "\n\n## Sessions\n"
        let c = calendar
        for (day, rows) in Dictionary(grouping: list, by: { c.startOfDay(for: $0.start) }).sorted(by: { $0.key < $1.key }) {
            out += "\n### \(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))\n\n"
            out += rows.sorted { $0.start < $1.start }.map { s in
                let to = s.end.map { $0.formatted(date: .omitted, time: .shortened) } ?? "now"
                return "- \(s.start.formatted(date: .omitted, time: .shortened)) to \(to): \(name(s)), \(TimeLog.span(s.active(at: now)))"
            }.joined(separator: "\n") + "\n"
        }
        return out
    }

    /// "acme-api 2026-10-27 to 2026-11-02": a file name for an export of this range.
    static func exportName(_ r: DateInterval) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let a = f.string(from: r.start), b = f.string(from: r.end.addingTimeInterval(-1))
        return a == b ? "glyph-time \(a)" : "glyph-time \(a) to \(b)"
    }

    /// A CRM entity id read as a name: "product/acme-corp" -> "Acme Corp"; goals by their title.
    static func entityName(_ id: String, goals: [String: String]) -> String {
        if id.hasPrefix("goal/"), let t = goals[String(id.dropFirst(5))] { return t }
        let slug = id.split(separator: "/").last.map(String.init) ?? id
        return slug.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func entitySymbol(_ id: String) -> String {
        switch id.split(separator: "/").first ?? "" {
        case "person": return "person"
        case "place": return "mappin.and.ellipse"
        case "product", "org": return "shippingbox"
        case "goal": return "target"
        case "event": return "calendar"
        default: return "cube"
        }
    }
}

/// What History shows and does, the same on the Mac and the iPhone. Each app hands it every
/// device's lines and the project notes, and the way to write: a new line in its own file, never
/// a rewrite. Everything it changes is a line or a project note; there is no database.
@MainActor @Observable
final class History {
    private(set) var events: [TimeEvent] = []
    private(set) var sessions: [TimeSession] = []
    var notes: [String: ProjectNote] = [:]
    /// Omega goal titles by id ("g-1a2b3c").
    var goalTitles: [String: String] = [:]
    var now = Date.now

    // The view's choices, kept here so the Mac's sidebar and the dashboard agree.
    var period = Period.week
    var anchor = Date.now
    var from = HistoryMath.calendar.date(byAdding: .day, value: -13, to: .now)!
    var to = Date.now
    var compare = false

    let host: String
    /// Appends one line to this device's file.
    let write: (TimeEvent) -> Void
    /// Starts a new session on a project (the app's own timer).
    let startAgain: (String) -> Void
    /// Saves a project note; nil where notes are read only (the iPhone).
    let saveNote: ((String, ProjectNote) -> Void)?
    /// Adds a suggestion for Glyph CRM; nil where it can't (the iPhone, or no vault).
    let suggest: ((String, String) -> Void)?

    init(host: String, write: @escaping (TimeEvent) -> Void, startAgain: @escaping (String) -> Void,
         saveNote: ((String, ProjectNote) -> Void)? = nil, suggest: ((String, String) -> Void)? = nil) {
        self.host = host; self.write = write; self.startAgain = startAgain; self.saveNote = saveNote; self.suggest = suggest
    }

    func load(_ events: [TimeEvent], notes: [String: ProjectNote]? = nil) {
        self.events = events
        sessions = TimeLog.sessions(events)
        if let notes { self.notes = notes }
        now = .now
    }

    var range: DateInterval { HistoryMath.range(period, anchor: anchor, from: from, to: to) }
    var previousRange: DateInterval { HistoryMath.previous(period, range) }
    var inRange: [TimeSession] { HistoryMath.within(sessions, range) }
    var inPrevious: [TimeSession] { HistoryMath.within(sessions, previousRange) }
    var title: String { HistoryMath.title(period, range, now: now) }
    var subtitle: String { HistoryMath.subtitle(period, range) }
    var atNow: Bool { range.contains(now) || range.start > now }

    func step(_ n: Int) {
        if period == .custom {
            let days = HistoryMath.calendar.dateComponents([.day], from: range.start, to: range.end).day ?? 1
            from = HistoryMath.calendar.date(byAdding: .day, value: n * days, to: from)!
            to = HistoryMath.calendar.date(byAdding: .day, value: n * days, to: to)!
        } else {
            anchor = HistoryMath.shift(period, anchor, by: n)
        }
    }

    func jumpToNow() { anchor = .now }

    /// Every named project, most recent first, hidden ones flagged (same rule as Recent).
    var projects: [TimeProject] { TimeLog.projects(events, now: now) }
    var initiatives: [String] { Array(Set(notes.values.compactMap(\.initiative))).sorted() }

    func sessions(of project: String) -> [TimeSession] { sessions.filter { HistoryMath.name($0) == project } }

    // MARK: Fixing the record (lines)

    func edit(_ s: TimeSession, project: String?, start: Date?, end: Date?) {
        guard project != nil || start != nil || end != nil else { return }
        write(TimeEvent("edit", host: host, project: project, id: s.id, start: start, end: end))
    }
    func delete(_ s: TimeSession) { write(TimeEvent("delete", host: host, id: s.id)) }
    func undelete(_ s: TimeSession) { write(TimeEvent("undelete", host: host, id: s.id)) }
    func hide(_ p: String) { write(TimeEvent("hide", host: host, project: p)) }

    /// Renames a project everywhere: one line, every session of it, and its note moves with it.
    /// Returns the name it settled on, or nil when there was nothing to do.
    @discardableResult
    func rename(_ project: String, to name: String) -> String? {
        let new = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !new.isEmpty, new != project else { return nil }
        if let note = notes[project] {
            notes[new] = notes[new] ?? note
            notes[project] = nil
        }
        // The line carries the move; the app writing it moves the project's note on disk.
        write(TimeEvent("rename", host: host, project: project, label: new))
        return new
    }

    func show(_ p: String) { write(TimeEvent("show", host: host, project: p)) }

    func setInitiative(_ project: String, _ label: String?) {
        var n = notes[project] ?? ProjectNote()
        let clean = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        n.initiative = clean?.isEmpty == false ? String(clean!.prefix(60)) : nil
        notes[project] = n
        saveNote?(project, n)
    }

    func link(_ project: String, _ id: String, on: Bool) {
        var n = notes[project] ?? ProjectNote()
        if on, !n.entities.contains(id) { n.entities.append(id) }
        if !on { n.entities.removeAll { $0 == id } }
        notes[project] = n
        saveNote?(project, n)
    }
}
