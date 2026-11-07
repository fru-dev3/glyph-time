// Glyph Time's activity record: spans, away gaps, the exclude list, private windows, the capture
// limit and the file format. Invented apps and sites only.
//     cat Sources/GlyphTime/Activity.swift Shared/FiledReminders.swift ActivityCheck.swift | swift -
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "  PASS  \(what)" : "  FAIL  \(what)")
    if !ok { failures += 1 }
}

let cal = Calendar.current
let t0 = cal.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 9))!
func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
let editor = Front(app: "Code Editor", bundle: "com.example.editor", title: "main.swift - acme-api")
let browser = Front(app: "Safari", bundle: "com.apple.Safari", title: "Docs", domain: "docs.example.org")

print("Spans")
var t = Tracker(host: "laptop-test")
check(t.sample(editor, project: "acme-api", at: at(0)).isEmpty, "the first sample opens a span, writes nothing")
check(t.sample(editor, project: "acme-api", at: at(5)).isEmpty, "the same front keeps it open")
var out = t.sample(browser, project: "acme-api", at: at(65))
check(out.count == 1 && out[0].app == "Code Editor" && out[0].seconds == 65 && out[0].project == "acme-api" && out[0].title == "main.swift - acme-api", "a switch ends the span (65 s on the editor, its project and title)")
out = t.sample(Front(app: "Safari", bundle: "com.apple.Safari", title: "Other", domain: "example.com"), project: "acme-api", at: at(125))
check(out.count == 1 && out[0].domain == "docs.example.org" && out[0].seconds == 60, "a new tab in the same browser is a new span")
out = t.sample(Front(app: "Safari", bundle: "com.apple.Safari", title: "Other", domain: "example.com"), project: nil, at: at(130))
check(out.count == 1 && out[0].project == "acme-api", "the session stopping ends the span too")
out = t.sample(editor, project: nil, at: at(131))
check(out.count == 0, "a one-second flick is dropped")

print("Away")
t = Tracker(host: "laptop-test")
_ = t.sample(editor, project: nil, at: at(0))
_ = t.sample(editor, project: nil, at: at(60))
out = t.sample(editor, project: nil, at: at(400), awaySince: at(100))
check(out.count == 1 && out[0].end == at(100) && out[0].project == nil, "idle: the span ends when input stopped (100 s), not when it was noticed")
check(t.open == nil, "nothing is open while away")
check(t.sample(editor, project: nil, at: at(410), awaySince: at(100)).isEmpty && t.open == nil, "still away: nothing recorded")
_ = t.sample(editor, project: nil, at: at(500))
_ = t.sample(editor, project: nil, at: at(520))
out = t.sample(editor, project: nil, at: at(4000)) // the Mac slept without a word
check(out.count == 1 && out[0].start == at(500) && out[0].end == at(520), "samples stopping (sleep): the span ends at the last sample")
check(t.open?.start == at(4000), "and a new one starts on return")
out = t.flush(at: at(4030))
check(out.count == 1 && out[0].seconds == 30 && t.open == nil, "quit: the open span is written")

print("Midnight")
t = Tracker(host: "laptop-test")
t.gap = 3600
let late = cal.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 23, minute: 50))!
_ = t.sample(editor, project: nil, at: late)
_ = t.sample(editor, project: nil, at: late.addingTimeInterval(60 * 15))
out = t.flush(at: late.addingTimeInterval(60 * 20))
check(out.count == 2 && out[0].seconds == 600 && out[1].seconds == 600 && ActivityLog.day(out[1].start) == "2026-03-05", "a span across midnight is cut in two, one per day")

print("Exclude list")
let list = ActivityRules.list("1Password, bank.example\ncom.example.Vault\n")
check(list == ["1password", "bank.example", "com.example.vault"], "the list reads commas and lines, any case")
check(ActivityRules.keep(Front(app: "1Password", bundle: "com.example.pw"), excluded: list) == nil, "an excluded app (by name) leaves nothing")
check(ActivityRules.keep(Front(app: "Vault", bundle: "com.example.Vault"), excluded: list) == nil, "an excluded app (by bundle id) leaves nothing")
check(ActivityRules.keep(Front(app: "Safari", title: "Accounts", domain: "secure.bank.example"), excluded: list) == nil, "an excluded site and its subdomains leave nothing")
check(ActivityRules.keep(Front(app: "Safari", title: "Not a bank", domain: "notbank.example"), excluded: list) != nil, "a site that only ends the same way is kept")
check(ActivityRules.keep(Front(app: "Mail", bundle: "com.example.mail"), excluded: ActivityRules.list(ActivityRules.defaultExcluded.joined(separator: ","))) != nil, "other apps are kept")
check(!ActivityRules.mayCapture(Front(app: "1Password"), excluded: list, away: false), "no capture with an excluded app in front")

print("Private windows")
let priv = ActivityRules.keep(Front(app: "Chrome", bundle: "com.google.Chrome", title: "Secret", domain: "example.com", isPrivate: true), excluded: [])
check(priv?.app == "Chrome" && priv?.title == nil && priv?.domain == nil && priv?.isPrivate == true, "incognito: the app only, no title or site")
let marked = ActivityRules.keep(Front(app: "Firefox", title: "Gifts - Private Browsing", domain: "shop.example"), excluded: [])
check(marked?.title == nil && marked?.domain == nil, "a Private Browsing title is dropped with its site")
check(!ActivityRules.mayCapture(Front(app: "Chrome", isPrivate: true), excluded: [], away: false), "no capture of a private window")
check(!ActivityRules.mayCapture(editor, excluded: [], away: true), "no capture while away")
check(ActivityRules.mayCapture(editor, excluded: [], away: false), "a capture of an ordinary window is allowed")
t = Tracker(host: "laptop-test")
_ = t.sample(priv, project: nil, at: at(0))
out = t.flush(at: at(30))
check(out.first?.private == true && out.first?.title == nil, "its span says private, with no title")

print("Sites and titles")
check(ActivityRules.domain("https://www.example.com/a?b=1") == "example.com", "a URL becomes its site, without www")
check(ActivityRules.domain("file:///tmp/x.html") == nil && ActivityRules.domain("") == nil && ActivityRules.domain(nil) == nil, "no site for files or nothing")
check(ActivityRules.keep(Front(app: "Notes", title: String(repeating: "a", count: 400)), excluded: [])?.title?.count == ActivityRules.maxTitle, "long titles are cut")
check(ActivityRules.keep(Front(app: "Notes", title: "   "), excluded: [])?.title == nil, "a blank title is none")

print("The file")
let dir = FileManager.default.temporaryDirectory.appending(path: "activity-check-\(UUID().uuidString)")
let spans = [
    ActivitySpan(start: at(0), end: at(600), host: "laptop-test", app: "Code Editor", bundle: "com.example.editor", title: "main.swift", project: "acme-api"),
    ActivitySpan(start: at(600), end: at(900), host: "laptop-test", app: "Safari", bundle: "com.apple.Safari", title: "Docs", domain: "docs.example.org", project: "acme-api"),
    ActivitySpan(start: at(900), end: at(1500), host: "laptop-test", app: "Safari", title: "News", domain: "news.example"),
    ActivitySpan(start: at(1000), end: at(1000), host: "laptop-test", app: "Safari", kind: "shot", file: "captures/2026-03-04/091640.laptop-test.jpg", bytes: 1200),
]
try! ActivityLog.append(spans, to: dir)
try! ActivityLog.append([ActivitySpan(start: at(1500), end: at(1800), host: "desk-test", app: "Mail")], to: dir)
let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()) ?? []
check(files == ["2026-03-04.desk-test.jsonl", "2026-03-04.laptop-test.jsonl"], "one file per day per Mac (\(files))")
let raw = (try? String(contentsOf: dir.appending(path: "2026-03-04.laptop-test.jsonl"), encoding: .utf8)) ?? ""
let first = raw.split(separator: "\n").first.map(String.init) ?? ""
check(first.hasPrefix("{\"app\":\"Code Editor\",\"bundle\":\"com.example.editor\",\"end\":\"2026-03-04T09:10:00") && first.contains("\"project\":\"acme-api\"") && first.hasSuffix("\"title\":\"main.swift\"}"), "a line is sorted JSON with local times: \(first)")
check(!raw.contains("\\/") && raw.contains("captures/2026-03-04/"), "slashes are written plain")
let back = ActivityLog.read(dir, days: ["2026-03-04"])
check(back.count == 5 && back.map(\.app).contains("Mail"), "every Mac's lines read back, merged (\(back.count))")
check(back.first.map { abs($0.start.timeIntervalSince(at(0))) < 1 } == true, "times read back")
try? "not json\n".write(to: dir.appending(path: "2026-03-04.broken-test.jsonl"), atomically: true, encoding: .utf8)
check(ActivityLog.read(dir, days: ["2026-03-04"]).count == 5, "a broken line is skipped")
check(ActivityLog.read(dir, days: ["2026-03-05"]).isEmpty, "other days are not read")
check(ActivityLog.days(at(0), cal.startOfDay(for: at(3 * 86_400))) == ["2026-03-04", "2026-03-05", "2026-03-06"], "a range's days")

print("Insights")
let apps = ActivityMath.apps(back)
check(apps.map(\.name) == ["Safari", "Code Editor", "Mail"] && apps[0].seconds == 900, "top apps by time (captures count for nothing)")
check(apps[1].bundle == "com.example.editor", "an app keeps its bundle id, for its icon")
check(ActivityMath.sites(back).map(\.name) == ["news.example", "docs.example.org"], "top sites")
let groups = ActivityMath.windows(back)
check(groups.first?.project == "acme-api" && groups.first?.seconds == 900 && groups.first?.titles.first?.name == "main.swift (Code Editor)", "windows grouped by project, top first")
check(groups.last?.project == ActivityMath.noSession, "time outside a session comes last")
let md = ActivityMath.summary(back)
check(md.contains("## Today by app\n\n- Safari: 15 min\n- Code Editor: 10 min\n- Mail: 5 min\n") && md.contains("## Today by site\n\n- news.example: 10 min\n- docs.example.org: 5 min\n"), "the summary lists apps and sites")
check(ActivityMath.summary([]).isEmpty, "no activity, no summary section")
check(!md.contains("\u{2014}"), "no em dashes")

print("Capture limit and archive")
check(CaptureFiles.allows(used: 199_000_000, budgetMB: 200) && !CaptureFiles.allows(used: 200_000_000, budgetMB: 200), "under 200 MB a capture is taken, at it none")
check(!CaptureFiles.allows(used: 0, budgetMB: 0), "a zero limit takes none")
let time = dir.appending(path: "time")
let caps = time.appending(path: "captures")
let now = cal.date(from: DateComponents(year: 2026, month: 3, day: 31, hour: 12))!
for d in ["2026-01-10", "2026-02-27", "2026-03-30"] {
    try! FileManager.default.createDirectory(at: caps.appending(path: d), withIntermediateDirectories: true)
    try! Data(count: 1000).write(to: caps.appending(path: "\(d)/090000.laptop-test.jpg"))
}
check(CaptureFiles.bytes(caps.appending(path: "2026-03-30")) == 1000 && CaptureFiles.count(caps.appending(path: "2026-03-30")) == 1, "a day's size and count")
let old = CaptureFiles.older(than: 30, in: caps, now: now)
check(old.map(\.lastPathComponent) == ["2026-01-10", "2026-02-27"], "days older than 30 are found (\(old.map(\.lastPathComponent)))")
let moved = try! CaptureFiles.archive(old, timeFolder: time, now: now)
let arch = time.appending(path: "archived-2026-03-31/captures")
check(moved == 2 && FileManager.default.fileExists(atPath: arch.appending(path: "2026-01-10/090000.laptop-test.jpg").path), "they move to archived-<date>/captures, files intact")
check(!FileManager.default.fileExists(atPath: caps.appending(path: "2026-01-10").path) && FileManager.default.fileExists(atPath: caps.appending(path: "2026-03-30/090000.laptop-test.jpg").path), "recent days stay")
try! FileManager.default.createDirectory(at: caps.appending(path: "2026-01-10"), withIntermediateDirectories: true)
try! Data(count: 10).write(to: caps.appending(path: "2026-01-10/100000.laptop-test.jpg"))
try! Data(count: 10).write(to: caps.appending(path: "2026-01-10/090000.laptop-test.jpg")) // same name as one archived
_ = try! CaptureFiles.archive(CaptureFiles.older(than: 30, in: caps, now: now), timeFolder: time, now: now)
check(FileManager.default.fileExists(atPath: arch.appending(path: "2026-01-10/100000.laptop-test.jpg").path), "a second move merges into the archived day")
check(FileManager.default.fileExists(atPath: caps.appending(path: "2026-01-10/090000.laptop-test.jpg").path), "a name already archived is left where it is, never overwritten")
try? FileManager.default.removeItem(at: dir)

print("Filed deadlines")
let noon = cal.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 12))!
let plan = FiledReminders.plan([
    (id: "a1b2c3d4", title: "Acme Insurance Policy", kind: "renews", date: "2026-03-20"),  // 7 days before is ahead
    (id: "e5f6a7b8", title: "Northwind Invoice", kind: "due", date: "2026-03-06"),        // 7 days before has passed
    (id: "c9d0e1f2", title: "Old Bill", kind: "due", date: "2026-03-01"),                 // past
    (id: "a3b4c5d6", title: "Lease", kind: "expires", date: "2026-09-01"),                // past 90 days
    (id: "e7f8a9b0", title: "Today Bill", kind: "due", date: "2026-03-04"),               // today, 09:00 gone
], now: noon)
check(plan.map(\.id) == ["filing-e5f6a7b8-due-2026-03-06", "filing-a1b2c3d4-renews-2026-03-20"], "only coming deadlines in 90 days with a 09:00 still ahead (\(plan.map(\.id)))")
check(plan.first.map { cal.dateComponents([.day, .hour], from: $0.at) == DateComponents(day: 6, hour: 9) } == true, "7 days before has passed: on the day at 09:00")
check(plan.last.map { cal.dateComponents([.day, .hour], from: $0.at) == DateComponents(day: 13, hour: 9) } == true, "else 7 days before at 09:00")
check(plan.last?.label == "Renews Fri Mar 20: Acme Insurance Policy" && plan.first?.label == "Due Fri Mar 6: Northwind Invoice", "it says what and when (\(plan.map(\.label)))")
check(FiledReminders.plan([(id: "a1b2c3d4", title: "Acme Insurance Policy", kind: "renews", date: "2026-03-20")], now: noon, rung: ["filing-a1b2c3d4-renews-2026-03-20"]).isEmpty, "rung once: never again")

// The iPhone reads the Expiring list instead of the vault: the same plan from its lines.
let listed = FiledReminders.parseExpiring("""
# Expiring

- 2026-03-20 renews: [2025-03-20 Acme Insurance Policy](<../../../../data/domains/insurance/source/files/a.md>)
- not a line
- 2026-03-25 due: [Globex Bill](<../../../../data/domains/records/source/files/b.md>)
""")
check(listed.count == 2 && listed[0].kind == "renews" && listed[0].date == "2026-03-20" && listed[1].title == "Globex Bill", "the Expiring list reads back (\(listed))")
check(listed[0].id != listed[1].id && listed[0].id.count == 8, "an id per note")

print(failures == 0 ? "ACTIVITY ALL PASSED" : "ACTIVITY \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
