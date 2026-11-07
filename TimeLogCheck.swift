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
    TimeEvent("reminder", at: at(2), host: ph, at: at(120), label: "Call Ken", id: "r1"),
    TimeEvent("reminder", at: at(3), host: ph, at: at(90), label: "Gone", id: "r2"),
    TimeEvent("reminder", at: at(4), host: ph, answer: "cancel", id: "r2"),
]
let rl = TimeLog.line(marks[0])
assert(TimeLog.events(in: rl) == [marks[0]] && String(decoding: rl, as: UTF8.self).contains("\"label\":\"Gym\""))
assert(TimeLog.reminders(marks.shuffled()).map(\.label) == ["Call Ken", "Gym"])
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
// A hide in the same second the project started still hides it (lines are stamped to the second);
// a show in the same second as the hide puts it back. Line order decides.
let same = [TimeEvent("start", at: at(300), host: hp, project: "Fast"), TimeEvent("hide", at: at(300), host: hp, project: "Fast")]
assert(TimeLog.projects(same, now: at(301)).first { $0.name == "Fast" }?.hidden == true, "hide in the start's second")
assert(TimeLog.projects(same + [TimeEvent("show", at: at(300), host: hp, project: "Fast")], now: at(301)).first { $0.name == "Fast" }?.hidden == false)
// Read back from the file (stamped to the second), the same holds.
let dir2 = FileManager.default.temporaryDirectory.appendingPathComponent("timelog-\(UUID().uuidString)")
let sec = Date(timeIntervalSince1970: 1_800_000_000.4)
for e in [TimeEvent("start", at: sec, host: hp, project: "Fast"), TimeEvent("hide", at: sec.addingTimeInterval(0.3), host: hp, project: "Fast")] { try! TimeLog.append(e, to: dir2) }
assert(TimeLog.projects(TimeLog.read(dir2, months: [TimeLog.month(sec)]), now: sec).first?.hidden == true, "hide sticks after a round trip")
try? FileManager.default.removeItem(at: dir2)
// Under a minute reads in seconds, never "0 min".
assert(TimeLog.span(42) == "42 s" && TimeLog.span(0.4) == "1 s" && TimeLog.span(0) == "0 min" && TimeLog.span(60) == "1 min")
// Fixing the record: a session's id is its device and first start; edit, delete and undelete are lines.
let base = [TimeEvent("start", at: at(0), host: hp, project: "Acme"), TimeEvent("pause", at: at(10), host: hp),
            TimeEvent("resume", at: at(20), host: hp), TimeEvent("stop", at: at(60), host: hp)]
let one = TimeLog.sessions(base)[0]
assert(one.id.hasPrefix("laptop-local 20") && one.active() == 50 * 60, one.id)
var fixed = TimeLog.sessions(base + [TimeEvent("edit", at: at(100), host: "iphone-x", project: "Beta", id: one.id, start: at(-30))])
assert(fixed[0].project == "Beta" && fixed[0].start == at(-30) && fixed[0].active() == 80 * 60 && fixed[0].id == one.id, "\(fixed)")
fixed = TimeLog.sessions(base + [TimeEvent("edit", at: at(100), host: hp, id: one.id, end: at(15))])
assert(fixed[0].end == at(15) && fixed[0].active() == 5 * 60, "an earlier end trims the pause too: \(fixed[0].active())")
fixed = TimeLog.sessions(base + [TimeEvent("edit", at: at(100), host: hp, id: one.id, start: at(90))])
assert(fixed[0].active() == 0, "a start after the end never goes negative")
assert(TimeLog.sessions(base + [TimeEvent("delete", at: at(100), host: hp, id: one.id)]).isEmpty)
assert(TimeLog.sessions(base + [TimeEvent("delete", at: at(100), host: hp, id: one.id), TimeEvent("undelete", at: at(101), host: hp, id: one.id)]).count == 1)
assert(TimeLog.sessions(base + [TimeEvent("edit", at: at(100), host: hp, project: "X", id: "nobody")])[0].project == "Acme", "an unknown id changes nothing")
let editLine = TimeLog.line(TimeEvent("edit", at: at(100), host: hp, id: one.id, start: at(-30), end: at(70)))
assert(TimeLog.events(in: editLine).first?.end == at(70) && String(decoding: editLine, as: UTF8.self).contains("\"start\":"))
// Renaming a project: every session of it, whenever it ran, and the hide follows the new name.
let ren = [TimeEvent("start", at: at(0), host: hp, project: "Old Name"), TimeEvent("stop", at: at(30), host: hp),
           TimeEvent("start", at: at(60), host: hp, project: "Old Name"), TimeEvent("stop", at: at(90), host: hp),
           TimeEvent("start", at: at(120), host: hp, project: "Other"), TimeEvent("stop", at: at(130), host: hp),
           TimeEvent("hide", at: at(140), host: hp, project: "Old Name"),
           TimeEvent("rename", at: at(150), host: "iphone-x", project: "Old Name", label: "Acme Corp")]
let rs = TimeLog.sessions(ren)
assert(rs.filter { $0.project == "Acme Corp" }.count == 2 && !rs.contains { $0.project == "Old Name" }, "\(rs)")
let rp = TimeLog.projects(ren, now: at(160))
assert(rp.first(where: { $0.name == "Acme Corp" })?.total == 60 * 60, "both sessions count under the new name")
assert(rp.first(where: { $0.name == "Acme Corp" })?.hidden == true, "the hide follows the rename")
assert(!rp.contains { $0.name == "Old Name" })
// Renamed twice: the last name wins. An empty or unchanged name does nothing.
let renamedTwice = TimeLog.sessions(ren + [TimeEvent("rename", at: at(160), host: hp, project: "Acme Corp", label: "Acme")])
assert(renamedTwice.filter { $0.project == "Acme" }.count == 2, "\(renamedTwice)")
assert(TimeLog.sessions(ren + [TimeEvent("rename", at: at(160), host: hp, project: "Acme Corp", label: "  ")])
    .filter { $0.project == "Acme Corp" }.count == 2, "an empty new name changes nothing")

print("TimeLog ok")
