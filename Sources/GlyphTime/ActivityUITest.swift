import AppKit
import GlyphVault

/// The UI check's activity part: made-up fronts fed through the real tracker (never the real
/// screen), the lines it writes, private windows and the never list, away and lock, the capture
/// limit and the archive, Settings' new controls (pressed for real), and History's insights.
/// No capture is ever taken here. Invented apps and sites only.
extension UITest {
    static var todaySpans: [ActivitySpan] {
        ActivityLog.read(Activity.folder, days: [ActivityLog.day(.now)]).filter { $0.host == Store.host && $0.kind == nil }
    }

    /// A week of spans on this Mac and another, for History's insights.
    static func seedActivity() {
        let cal = HistoryMath.calendar
        let today = cal.startOfDay(for: .now)
        let plan: [(Double, Double, String, String?, String?, String?, String?)] = [
            // hour, minutes, app, bundle, title, site, project
            (8.0, 50, "Code Editor", "com.example.editor", "Router.swift - acme-api", nil, "acme-api"),
            (8.85, 15, "Safari", "com.apple.Safari", "Routing guide", "docs.example.org", "acme-api"),
            (9.1, 25, "Terminal", "com.apple.Terminal", "acme-api: swift test", nil, "acme-api"),
            (9.5, 30, "Safari", "com.apple.Safari", "Northwind board", "tracker.example.com", "northwind"),
            (10.0, 20, "Mail", "com.apple.mail", "Inbox", nil, nil),
            (10.4, 18, "Safari", "com.apple.Safari", "Morning headlines", "news.example", nil),
            (11.0, 40, "Code Editor", "com.example.editor", "Billing.swift - acme-api", nil, "acme-api"),
            (11.7, 12, "Notes", "com.apple.Notes", "Ideas", nil, nil),
        ]
        var spans: [ActivitySpan] = []
        for back in 0...6 {
            let day = cal.date(byAdding: .day, value: -back, to: today)!
            for (i, p) in plan.enumerated() where (back + i) % 5 != 4 {
                let start = day.addingTimeInterval(p.0 * 3600)
                let end = start.addingTimeInterval(p.1 * 60 * (back == 0 ? 1 : 0.6 + Double((back + i) % 4) * 0.2))
                guard end < .now else { continue }
                spans.append(ActivitySpan(start: start, end: end, host: back % 3 == 2 ? "desk-test" : Store.host, app: p.2, bundle: p.3,
                                          title: p.4, domain: p.5, project: p.6))
            }
        }
        try? ActivityLog.append(spans, to: Activity.folder)
    }

    static func activityRun() async {
        print("Activity")
        let d = Activity.defaults
        let keys = [Activity.trackKey, Activity.excludeKey, Captures.everyKey, Captures.clipKey, Captures.budgetKey]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { d.set(v, forKey: k) }; front = nil; idle = 0; Activity.locked = false }
        for k in keys { d.removeObject(forKey: k) }
        check(Activity.on == (Store.vault != nil), "Track apps and tabs is on by default only in a vault (\(Activity.on))")
        check(Captures.every == 0 && Captures.budgetMB == 200 && !Captures.clip, "screen captures are off by default; the limit is 200 MB a day")
        check(Activity.excluded == ["1password", "keychain access", "passwords"], "the never list starts with the password apps")
        d.set(true, forKey: Activity.trackKey)
        try? FileManager.default.removeItem(at: Activity.folder)
        let clock = Clock.shared
        clock.start(project: "acme-api")
        idle = 0

        func show(_ f: Front?) async { front = f; Activity.sample(); await wait(0.4) }
        await show(Front(app: "Code Editor", bundle: "com.example.editor", title: "main.swift - acme-api"))
        await wait(2.2)
        await show(Front(app: "Safari", bundle: "com.apple.Safari", title: "Docs", domain: "docs.example.org"))
        // A span is flushed on a background queue, so wait for it to land, never a fixed sleep.
        check(await until(5) {
            let s = todaySpans
            return s.count == 1 && s[0].app == "Code Editor" && s[0].title == "main.swift - acme-api" && s[0].project == "acme-api" && s[0].seconds >= 2
        }, "a switch writes the editor's span with its title and the session's project (\(todaySpans.count))")
        check(Activity.front?.domain == "docs.example.org", "the browser's site is what captures would see")
        await wait(2.2)
        await show(Front(app: "Chrome", bundle: "com.google.Chrome", title: "Secret plans", domain: "example.com", isPrivate: true))
        check(Activity.front == nil, "a private window: no capture may be taken")
        await wait(2.2)
        await show(Front(app: "1Password", bundle: "com.example.passwords", title: "Vault"))
        check(Activity.front == nil, "an app on the never list: no capture either")
        check(await until(5) {
            let s = todaySpans
            return s.last?.app == "Chrome" && s.last?.private == true && s.last?.title == nil && s.last?.domain == nil
        }, "the private window's span keeps only the app")
        check(todaySpans.contains { $0.domain == "docs.example.org" && $0.title == "Docs" }, "a tab's span has its title and site")
        await wait(2.2)
        await show(Front(app: "Notes", bundle: "com.apple.Notes", title: "Ideas"))
        await wait(1.2) // as above: a negative has nothing to wait for
        check(!todaySpans.contains { $0.app == "1Password" }, "the never-list app leaves no line")

        print("Activity: away and lock")
        idle = 9999
        await show(Front(app: "Notes", bundle: "com.apple.Notes", title: "Ideas"))
        check(Activity.away && Activity.front == nil, "idle past the away time: away, nothing in front for captures")
        idle = 0
        await show(Front(app: "Notes", bundle: "com.apple.Notes", title: "Ideas"))
        await wait(2.2)
        Activity.locked = true
        await show(Front(app: "Notes", bundle: "com.apple.Notes", title: "Ideas"))
        check(await until(5) { Activity.away && todaySpans.last?.app == "Notes" }, "locking ends the span")
        let count = todaySpans.count
        await show(Front(app: "Code Editor", bundle: "com.example.editor", title: "main.swift - acme-api"))
        await wait(1.2) // nothing to wait for: give the writer its chance before saying it wrote nothing
        check(todaySpans.count == count, "nothing is recorded while locked")
        Activity.locked = false
        clock.stop()

        print("Activity: the file")
        let raw = ((try? FileManager.default.contentsOfDirectory(atPath: Activity.folder.path)) ?? []).sorted()
        check(raw == ["\(ActivityLog.day(.now)).\(Store.host).jsonl"], "one file a day for this Mac, in activity/ (\(raw))")
        check(Activity.folder.path.hasSuffix(Store.vault != nil ? "data/apps/time/activity" : ".glyph-time/activity"), "beside the sessions")
        let text = (try? String(contentsOf: Activity.folder.appending(path: raw.first ?? "x"), encoding: .utf8)) ?? ""
        check(!text.contains("Secret") && !text.contains("1Password"), "no private title and no never-list app in the file")
        d.set(false, forKey: Activity.trackKey)
        let before = todaySpans.count
        await show(Front(app: "Mail", bundle: "com.apple.mail", title: "Inbox"))
        await wait(2.2)
        await show(Front(app: "Notes", bundle: "com.apple.Notes", title: "Ideas"))
        await wait(1.2) // as above: a negative has nothing to wait for
        check(todaySpans.count == before, "with tracking off nothing is written")
        d.set(true, forKey: Activity.trackKey)

        print("Activity: captures")
        d.set(5, forKey: Captures.everyKey)
        check(Captures.reason() != nil || CaptureFiles.allows(used: 0, budgetMB: Captures.budgetMB), "captures say why they would skip (\(Captures.reason() ?? "none"))")
        d.set(0, forKey: Captures.budgetKey)
        if Captures.allowed { await show(Front(app: "Notes", bundle: "com.apple.Notes", title: "Ideas")); check(Captures.reason() == "Today's limit reached", "over the daily limit a capture is skipped") }
        d.set(0, forKey: Captures.everyKey)
        let old = Captures.folder.appending(path: ActivityLog.day(Calendar.current.date(byAdding: .day, value: -40, to: .now)!))
        try? FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try? Data(count: 2000).write(to: old.appending(path: "101500.\(Store.host).jpg"))
        try? FileManager.default.createDirectory(at: Captures.day(), withIntermediateDirectories: true)
        try? Data(count: 1500).write(to: Captures.day().appending(path: "101500.\(Store.host).jpg"))
        check(Captures.today() == "under 0.1 MB, 1 capture", "Settings shows today's captures (\(Captures.today()))")
        check(Captures.archiveOld() == 1, "Move to Archive moves the day older than 30")
        let moved = Captures.folder.deletingLastPathComponent().appending(path: "archived-\(ActivityLog.day(.now))/captures/\(old.lastPathComponent)/101500.\(Store.host).jpg")
        check(FileManager.default.fileExists(atPath: moved.path) && !FileManager.default.fileExists(atPath: old.path), "into archived-<date>/captures, the file intact")
        check(FileManager.default.fileExists(atPath: Captures.day().appending(path: "101500.\(Store.host).jpg").path), "today's stay")

        if let vault = Store.vault {
            Store.writeSummary()
            let summary = (try? String(contentsOf: vault.appending(path: "data/domains/time/source/apps/time/summary.md"), encoding: .utf8)) ?? ""
            check(summary.contains("## Today by app\n\n- ") && summary.contains("- Code Editor:") && summary.contains("## Today by site\n\n- docs.example.org:"), "the summary for agents lists today's apps and sites")
        }

        print("Activity: Settings")
        HistoryTest.frame = { historyFrames[$0] = $1 }
        d.set(true, forKey: Activity.trackKey)
        d.set(10, forKey: Captures.everyKey)
        d.removeObject(forKey: Captures.budgetKey) // back to the default, 200 MB
        SettingsWindow.close()
        SettingsWindow.show()
        await wait(1)
        guard let w = SettingsWindow.current else { check(false, "Settings opens"); return }
        for id in ["settings-track", "settings-exclude", "settings-capture-every", "settings-capture-clip", "settings-capture-budget", "settings-capture-today", "settings-capture-archive"] {
            check(historyFrames[id] != nil, "Settings shows \(id)")
        }
        await settingsShot("14-settings-activity", w)
        await flip("settings-track", in: w)
        check(d.object(forKey: Activity.trackKey) as? Bool == false, "Track apps and tabs turns off with a click")
        await flip("settings-track", in: w)
        check(d.object(forKey: Activity.trackKey) as? Bool == true, "and on again")
        await flip("settings-capture-clip", in: w)
        check(d.bool(forKey: Captures.clipKey), "Short clip turns on with a click")
        d.set(0, forKey: Captures.everyKey)
        w.close()
        HistoryTest.frame = nil
    }

    /// A Form toggle: its switch sits at the row's right end; press that control itself.
    static func flip(_ id: String, in w: NSWindow) async {
        guard var f = historyFrames[id], let v = w.contentView else { check(false, "Settings shows '\(id)'"); return }
        // Below the fold: scroll the form until the row is in the middle.
        if f.midY > v.bounds.height - 40 || f.minY < 40, let scroll = scrollViews(in: v).max(by: { $0.frame.height < $1.frame.height }) {
            let clip = scroll.contentView
            clip.scroll(to: NSPoint(x: 0, y: max(0, clip.bounds.origin.y + (f.midY - v.bounds.height / 2))))
            scroll.reflectScrolledClipView(clip)
            await wait(0.6)
            f = historyFrames[id] ?? f
        }
        // The row's switch: the NSSwitch SwiftUI draws there, found by its height in the window. Only a
        // switch is ever pressed; a popup button would open a menu that waits forever.
        func switches(_ view: NSView) -> [NSSwitch] { ((view as? NSSwitch).map { [$0] } ?? []) + view.subviews.flatMap(switches) }
        // Form rows live in cells of their own, so a row's frame isn't the window's: find the switch by its
        // label, else by place (Track apps and tabs and Short clip are the form's last two switches).
        let label = ["settings-track": "Track apps and tabs", "settings-capture-clip": "Short clip instead (12 seconds)"][id] ?? ""
        let all = switches(v).sorted { $0.convert($0.bounds, to: nil).midY > $1.convert($1.bounds, to: nil).midY } // top first
        let byLabel = all.first { ($0.accessibilityLabel() ?? "") == label || (($0.accessibilityParent() as? NSAccessibilityProtocol)?.accessibilityLabel() ?? "") == label }
        let byPlace: NSSwitch? = all.count >= 2 ? all[id == "settings-track" ? all.count - 2 : all.count - 1] : nil
        guard let s = byLabel ?? byPlace else {
            check(false, "a switch under '\(id)' (\(all.map { $0.accessibilityLabel() ?? "?" }))"); return
        }
        s.performClick(nil)
        await wait(0.6)
    }

    /// Settings' whole form (it scrolls), drawn by the window itself.
    static func settingsShot(_ name: String, _ w: NSWindow) async {
        await wait(0.5)
        guard let v = w.contentView, let scroll = scrollViews(in: v).max(by: { $0.frame.height < $1.frame.height }), let doc = scroll.documentView,
              let rep = doc.bitmapImageRepForCachingDisplay(in: doc.bounds) else { return }
        doc.cacheDisplay(in: doc.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
    }
}
