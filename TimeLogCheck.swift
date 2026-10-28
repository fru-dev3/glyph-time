// Pure check of the session format (GlyphVault/TimeLog.swift), no app, no vault:
//   cat Packages/GlyphCore/Sources/GlyphVault/TimeLog.swift Time/TimeLogCheck.swift | swift -
// Made-up names only.

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
let h = "laptop-local", p = "phone-1"

// A line round-trips; the time keeps its offset; nil fields are left out.
let start = TimeEvent("start", at: at(0), host: h, project: "acme-api", source: "repo", app: "com.example.term")
let line = String(decoding: TimeLog.line(start), as: UTF8.self)
assert(line.hasSuffix("\n") && !line.contains("reason") && line.contains("\"event\":\"start\""), line)
assert(TimeLog.events(in: TimeLog.line(start)) == [start])

// A torn last line and a foreign line are skipped, not fatal.
var data = TimeLog.line(start)
data.append(Data("{\"ts\":\"nope\"}\n{\"event\":\"st".utf8))
assert(TimeLog.events(in: data).count == 1)

// Pauses come off; a stop while paused counts nothing more.
let day: [TimeEvent] = [
    start,
    TimeEvent("pause", at: at(20), host: h, reason: "idle"),
    TimeEvent("resume", at: at(25), host: h),
    TimeEvent("nudge", at: at(35), host: h, minutes: 30, answer: "keep"),
    TimeEvent("name", at: at(36), host: h, project: "Northwind"),
    TimeEvent("pause", at: at(50), host: h, reason: "user"),
    TimeEvent("stop", at: at(70), host: h, minutes: 45),
    // The phone, interleaved: its own session.
    TimeEvent("start", at: at(10), host: p, project: "Run"),
    TimeEvent("stop", at: at(40), host: p),
]
let s = TimeLog.sessions(day.shuffled())
assert(s.count == 2, "\(s)")
let mac = s.first { $0.host == h }!
assert(mac.active() == 45 * 60, "\(mac.active())")
assert(mac.project == "Northwind" && mac.source == "named" && mac.nudges == 1 && mac.end == at(70))
assert(s.first { $0.host == p }!.active() == 30 * 60)

// Open and paused: the clock stands still; a new start closes a forgotten session.
let open = TimeLog.sessions([start, TimeEvent("pause", at: at(10), host: h, reason: "sleep")])
assert(open.count == 1 && open[0].end == nil && open[0].pauseReason == "sleep" && open[0].active(at: at(500)) == 600)
let twice = TimeLog.sessions([start, TimeEvent("start", at: at(30), host: h, project: "Beta")])
assert(twice.count == 2 && twice[0].end == at(30) && twice[1].end == nil && twice[1].project == "Beta")

// Totals by project, biggest first; unnamed has a name.
let tot = TimeLog.totals(s + [TimeSession(host: h, start: at(100), end: at(110))], from: at(0), to: at(1000))
assert(tot.map(\.project) == ["Northwind", "Run", "Unnamed"], "\(tot)")

// Clock and span text; file name by month and host.
assert(TimeLog.clock(42 * 60) == "42:00" && TimeLog.clock(3909) == "1:05:09" && TimeLog.clock(-3) == "0:00")
assert(TimeLog.span(35 * 60) == "35 min" && TimeLog.span(72 * 60) == "1 h 12 min" && TimeLog.span(120 * 60) == "2 h")
assert(TimeLog.fileName(for: start).hasSuffix(".laptop-local.jsonl") && TimeLog.fileName(for: start).count == "2027-01.laptop-local.jsonl".count)

// Append and read back from a folder, months filtered.
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("timelog-\(UUID().uuidString)")
for e in day { try! TimeLog.append(e, to: dir) }
assert(TimeLog.read(dir, months: [TimeLog.month(t0)]).count == day.count)
assert(TimeLog.read(dir, months: ["1999-01"]).isEmpty)
try? FileManager.default.removeItem(at: dir)
// The summary: today by project with session counts, devices, nothing under a minute.
var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!
let sum = TimeLog.summary(s, now: at(80), calendar: utc)
assert(sum.contains("## Today, ") && sum.contains("- Northwind: 45 min (1 session)") && sum.contains("- Run: 30 min (1 session)"), sum)
assert(sum.contains("## Last week, from") && sum.contains("Nothing timed.") && sum.contains("- laptop-local: 45 min"), sum)
assert(!sum.contains("\u{2014}"), "no em dashes")

// Alarms and reminders: lines in the same file, folded apart; a cancel takes one back; sessions ignore them.
let ph = "iphone-16-pro"
let marks: [TimeEvent] = [
    TimeEvent("alarm", at: at(1), host: ph, at: at(600), label: "Gym", id: "a1"),
    TimeEvent("reminder", at: at(2), host: ph, at: at(120), label: "Call Sam", id: "r1"),
    TimeEvent("reminder", at: at(3), host: ph, at: at(90), label: "Gone", id: "r2"),
    TimeEvent("reminder", at: at(4), host: ph, answer: "cancel", id: "r2"),
]
let rl = TimeLog.line(marks[0])
assert(TimeLog.events(in: rl) == [marks[0]] && String(decoding: rl, as: UTF8.self).contains("\"label\":\"Gym\""))
assert(TimeLog.reminders(marks.shuffled()).map(\.label) == ["Call Sam", "Gym"])
assert(TimeLog.sessions(marks + day).count == 2)
// Recent projects: newest first, hide and show are lines, starting again un-hides, auto-hide by age.
let hp = "laptop-local"
let pl: [TimeEvent] = [
    TimeEvent("start", at: at(0), host: hp, project: "Old"), TimeEvent("stop", at: at(60), host: hp),
    TimeEvent("start", at: at(100), host: hp, project: "Acme"), TimeEvent("stop", at: at(160), host: hp),
    TimeEvent("hide", at: at(170), host: hp, project: "Acme"),
    TimeEvent("start", at: at(200), host: hp, project: "Beta"), TimeEvent("stop", at: at(230), host: hp),
]
var ps = TimeLog.projects(pl, now: at(240))
assert(ps.map(\.name) == ["Beta", "Acme", "Old"] && ps.map(\.hidden) == [false, true, false], "\(ps)")
assert(ps[1].total == 60 * 60)
ps = TimeLog.projects(pl + [TimeEvent("start", at: at(250), host: hp, project: "Acme")], now: at(260))
assert(ps.first?.name == "Acme" && ps.first?.hidden == false, "starting again un-hides")
ps = TimeLog.projects(pl + [TimeEvent("show", at: at(180), host: hp, project: "Acme")], now: at(240))
assert(ps.first(where: { $0.name == "Acme" })?.hidden == false, "show restores")
ps = TimeLog.projects(pl, now: at(240).addingTimeInterval(40 * 86_400), autoHideDays: 30)
assert(ps.allSatisfy(\.hidden), "auto-hide after 30 days")
assert(TimeLog.recentMonths(count: 12).count == 12)
print("TimeLog ok")
