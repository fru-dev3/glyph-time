import AppKit
import GlyphVault
import SwiftUI

/// The UI check's History part: ten weeks of made-up sessions on two devices, then the window,
/// clicked for real (mouse down and up on each control), with a picture of every state.
extension UITest {
    /// A real click on a History control, in the window it is in (the main window or a sheet).
    @discardableResult
    static func click(_ id: String, in given: NSWindow? = nil) async -> Bool {
        let window = given ?? HistoryWindow.window
        var last: CGRect?
        for _ in 0..<30 { // wait for it to show and hold still
            let now = historyFrames[id]
            if now != nil, now == last { break }
            last = now
            await wait(0.05)
        }
        guard let w = window, var f = historyFrames[id], let v = w.contentView else { check(false, "History shows '\(id)'"); return false }
        // Below the fold: scroll the page (the scroll view under it) until it is in the middle.
        if f.midY > v.bounds.height - 40 || f.minY < 40, let scroll = scrollViews(in: v).first(where: { $0.frame.width > 300 && v.convert($0.bounds, from: $0).minX <= f.midX && v.convert($0.bounds, from: $0).maxX >= f.midX }) {
            let clip = scroll.contentView
            let y = max(0, clip.bounds.origin.y + (f.midY - v.bounds.height / 2))
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scroll.reflectScrolledClipView(clip)
            await wait(0.6)
            f = historyFrames[id] ?? f
        }
        // The control's own press, as VoiceOver does it: works whether or not the window is key
        // (a test run from a remote shell can't make the app active). Mouse clicks otherwise.
        w.makeKeyAndOrderFront(nil)
        let point = NSPoint(x: f.midX, y: v.bounds.height - f.midY) // window coordinates, from the top-left frame
        if let e = element(id, in: w), e.accessibilityPerformPress() {
            await wait(0.6)
            return true
        }
        // What a click there would hit. An AppKit control (SwiftUI draws bordered and borderless
        // buttons, toggles and menus as NSControls) gets its own click; anything else gets the mouse.
        if let sv = v.superview, let control = sv.hitTest(sv.convert(point, from: nil)) as? NSControl {
            control.performClick(nil)
            await wait(0.6)
            return true
        }
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        // A SwiftUI view: mouse down and up, as on the edge clock.
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return false }
        w.sendEvent(down)
        await wait(0.05)
        w.sendEvent(up)
        await wait(0.5)
        return true
    }

    static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap { scrollViews(in: $0) }
    }

    /// The accessibility element with this identifier, searched breadth first.
    static func element(_ id: String, in root: Any) -> NSAccessibilityProtocol? {
        var queue: [Any] = [root]
        var seen = 0
        while !queue.isEmpty, seen < 20_000 {
            let n = queue.removeFirst(); seen += 1
            guard let e = n as? NSAccessibilityProtocol else { continue }
            if e.accessibilityIdentifier() == id { return e }
            queue += e.accessibilityChildren() ?? []
        }
        return nil
    }

    static func windowShot(_ name: String, _ given: NSWindow? = nil, project: String? = nil) async {
        let window = given ?? HistoryWindow.window
        if let project, given == nil { // the page the shot is named for, not whatever was open
            HistoryMac.select?(project)
            await wait(0.4)
        }
        await wait(0.6)
        window?.makeKeyAndOrderFront(nil)
        window?.displayIfNeeded()
        guard let v = window?.contentView?.superview ?? window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        guard given == nil, let cg = rep.cgImage else {
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
            return
        }
        // The page sits in a scroll view that caching the window doesn't draw: draw the scroll
        // view's own page (its whole length) and put it beside the sidebar.
        guard let scroll = scrollViews(in: v).first(where: { $0.frame.width > 300 }), let doc = scroll.documentView,
              let pageRep = doc.bitmapImageRepForCachingDisplay(in: doc.bounds) else { return }
        doc.cacheDisplay(in: doc.bounds, to: pageRep)
        guard let body = pageRep.cgImage else { return }
        let r = (scale: CGFloat(pageRep.pixelsWide) / max(1, doc.bounds.width), 0)
        let scale = r.scale
        let sideW = Int(241 * scale), H = max(cg.height, body.height)
        guard let ctx = CGContext(data: nil, width: sideW + body.width, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        var page = CGColor(gray: 1, alpha: 1), side = page
        (NSApp.appearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            page = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB)?.cgColor ?? page
            side = (NSColor.underPageBackgroundColor.blended(withFraction: 0.5, of: NSColor.windowBackgroundColor) ?? .windowBackgroundColor).usingColorSpace(.deviceRGB)?.cgColor ?? side
        }
        ctx.setFillColor(page)
        ctx.fill(CGRect(x: 0, y: 0, width: sideW + body.width, height: H))
        ctx.setFillColor(side)
        ctx.fill(CGRect(x: 0, y: 0, width: sideW, height: H))
        if let side = cg.cropping(to: CGRect(x: 0, y: 0, width: sideW, height: cg.height)) {
            ctx.draw(side, in: CGRect(x: 0, y: H - cg.height, width: sideW, height: cg.height))
        }
        ctx.draw(body, in: CGRect(x: sideW, y: H - body.height, width: body.width, height: body.height))
        if let img = ctx.makeImage() {
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
        }
    }

    /// Ten weeks back from today, on this Mac and a made-up phone; invented projects only.
    static func seedHistory() {
        let cal = HistoryMath.calendar
        let today = cal.startOfDay(for: .now)
        let names = ["acme-api", "northwind", "acme-api", "reading", "garden-shed", "northwind", "acme-api", "billing-fix"]
        for back in 1...70 {
            let day = cal.date(byAdding: .day, value: -back, to: today)!
            let weekday = cal.component(.weekday, from: day)
            let slots: [Double] = weekday == 1 || weekday == 7 ? [10] : [8.5, 11, 14, 16.5]
            for (k, hour) in slots.enumerated() where (back + k) % 6 != 0 {
                let phone = (back + k) % 4 == 0
                let host = phone ? "phone-test" : Store.host
                let start = day.addingTimeInterval(hour * 3600 + Double((back * 7 + k * 11) % 30) * 60)
                let minutes = 25 + (back * 13 + k * 29) % 95
                let name = weekday == 1 || weekday == 7 ? "garden-shed" : names[(back + k) % names.count]
                try? TimeLog.append(TimeEvent("start", at: start, host: host, device: phone ? "Test Phone" : "Test Mac", project: name, source: "named"), to: Store.folder)
                try? TimeLog.append(TimeEvent("stop", at: start.addingTimeInterval(Double(minutes) * 60), host: host), to: Store.folder)
            }
        }
        // Today so far: three sessions, one from the phone.
        for (h, m, name, phone) in [(8.0, 70.0, "acme-api", false), (9.5, 45.0, "northwind", true), (11.0, 55.0, "acme-api", false)] {
            let start = today.addingTimeInterval(h * 3600)
            guard start.addingTimeInterval(m * 60) < .now else { continue }
            let host = phone ? "phone-test" : Store.host
            try? TimeLog.append(TimeEvent("start", at: start, host: host, device: phone ? "Test Phone" : "Test Mac", project: name, source: "named"), to: Store.folder)
            try? TimeLog.append(TimeEvent("stop", at: start.addingTimeInterval(m * 60), host: host), to: Store.folder)
        }
        if let vault = Store.vault {
            let goals = vault.appending(path: "data/domains/time/source/goals.md")
            try? FileManager.default.createDirectory(at: goals.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "# time goals\n\n- [ ] Ship the Acme beta by December ~id:g-test01 ~status:active\n- [ ] Keep weekends for the house ~id:g-test02 ~status:active\n"
                .write(to: goals, atomically: true, encoding: .utf8)
        }
    }

    static func historyRun() async {
        print("History")
        freshFile()
        seedHistory()
        seedActivity()
        HistoryTest.frame = { historyFrames[$0] = $1 }
        let h = MacHistory.shared
        h.period = .week; h.anchor = .now; h.compare = false
        HistoryWindow.show()
        guard let w = HistoryWindow.window else { check(false, "the History window opens"); return }
        w.setContentSize(NSSize(width: 1180, height: 860))
        w.center()
        await wait(1.2)
        check(w.isVisible && h.sessions.count > 150, "History opens with every device's sessions (\(h.sessions.count))")
        check(h.sessions.contains { $0.host == "phone-test" } && h.sessions.contains { $0.host == Store.host }, "both the Mac's and the phone's")
        check(historyFrames["history-title"] != nil && historyFrames["history-total"] != nil && historyFrames["history-chart"] != nil, "the week shows its title, total and chart")
        await windowShot("20-history-week")

        print("History: periods")
        await click("history-back")
        check(h.title.hasPrefix("Week of"), "the back arrow goes to last week (\(h.title))")
        await click("history-forward")
        check(h.title == "This week", "forward comes back to this week")
        check(historyFrames["insight-app-Safari"] != nil && historyFrames["insight-project-northwind"] != nil, "the week's insights read every day's lines, both Macs")
        h.period = .today
        await wait(0.5)
        check(h.title == "Today" && historyFrames["history-chart"] != nil, "Today shows the day's time line")
        await windowShot("21-history-today")
        check(historyFrames["history-insights"] != nil && historyFrames["insight-app-Code Editor"] != nil && historyFrames["insight-site-docs.example.org"] != nil
              && historyFrames["insight-project-acme-api"] != nil, "Today: where your time went, by app, site and project's windows")
        await windowShot("33-history-insights")
        await click("history-back")
        check(h.title == "Yesterday", "back from today is yesterday")
        h.period = .month; h.anchor = .now
        await wait(0.5)
        check(h.title == "This month", "Month")
        await windowShot("22-history-month")
        h.period = .custom
        h.from = HistoryMath.calendar.date(byAdding: .day, value: -60, to: .now)!; h.to = .now
        await wait(0.5)
        check(h.title.contains(" to ") && historyFrames["history-from"] != nil, "Custom: any days, with From and To (\(h.title))")
        await windowShot("23-history-custom")

        print("History: compare, breakdown, export")
        h.period = .week; h.anchor = .now
        await wait(0.4)
        await click("history-compare-toggle")
        check(h.compare && historyFrames["history-compare"] != nil, "Compare shows this week against last week")
        await windowShot("24-history-compare")
        h.setInitiative("acme-api", "Client work")
        h.setInitiative("northwind", "Client work")
        h.link("acme-api", "goal/g-test01", on: true)
        h.link("acme-api", "product/acme-corp", on: true)
        let notes = ProjectNote.read(MacHistory.notesFolder)
        check(notes["acme-api"]?.initiative == "Client work" && notes["acme-api"]?.entities == ["goal/g-test01", "product/acme-corp"], "an initiative and links are saved in the project's note")
        let noteText = (try? String(contentsOf: MacHistory.notesFolder.appending(path: "acme-api.md"), encoding: .utf8)) ?? ""
        check(noteText.hasPrefix("---\nproject: acme-api\ninitiative: Client work\nentities: [goal/g-test01, product/acme-corp]\n---"), "the note is plain front matter with an entities: line")
        let byInit = HistoryMath.byInitiative(h.inRange, notes: h.notes)
        check(byInit.first?.name == "Client work" && byInit.last?.name == HistoryMath.noInitiative, "by initiative: Client work first, the rest last")
        if Store.vault != nil {
            check(h.goalTitles["g-test01"] == "Ship the Acme beta by December", "Omega goals read from the domains' goals.md")
            check(HistoryMath.byGoal(h.inRange, notes: h.notes, titles: h.goalTitles).first?.name == "Ship the Acme beta by December", "by goal names the goal")
        }
        let csv = MacHistory.export(markdown: false), md = MacHistory.export(markdown: true)
        let csvText = csv.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let mdText = md.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        check(csvText.hasPrefix("start,end,minutes,project,initiative,device\n") && csvText.split(separator: "\n").count == h.inRange.count + 1, "CSV export: a row per session (\(h.inRange.count))")
        check(csv?.path.contains("/exports/glyph-time ") == true, "exports go beside the sessions, in exports/")
        check(mdText.hasPrefix("# Glyph Time: This week") && mdText.contains("## By initiative") && mdText.contains("- Client work:"), "Markdown export: totals, initiatives, days")
        check(!(csvText + mdText).contains("\u{2014}"), "no em dashes in exports")
        await windowShot("25-history-initiatives")

        print("History: a session")
        if let s = h.inRange.last(where: { $0.project == "acme-api" }) {
            let count = lines.count
            await click("session-acme-api")
            let sheet = w.attachedSheet
            check(sheet != nil, "a click on a session opens its editor")
            await windowShot("26-session-editor", sheet)
            if let sheet { await click("session-cancel", in: sheet) }
            check(w.attachedSheet == nil && lines.count == count, "Cancel closes it and writes nothing")
            h.edit(s, project: "northwind", start: s.start.addingTimeInterval(-600), end: nil)
            let fixed = h.sessions.first { $0.id == s.id }
            check(last?.event == "edit" && fixed?.project == "northwind" && fixed?.start == s.start.addingTimeInterval(-600), "an edit is a line: new project and start, same session")
            h.edit(fixed!, project: "acme-api", start: s.start, end: nil)
            await click("session-acme-api")
            // Wait for the editor rather than reading `attachedSheet` the instant the click
            // returns, and say so when it never arrives. This `if let` had no `else`, so a missing
            // editor would surface three assertions later as "Delete in the editor writes a delete
            // line", which is not where the problem is. Measured on 2026-11-01: the editor DOES
            // open, so Delete is the failing step, and this assertion is what proves it.
            var editor = w.attachedSheet
            for _ in 0..<25 where editor == nil { await wait(0.1); editor = w.attachedSheet }
            check(editor != nil, "a click on the edited session opens its editor again")
            if let editor { await click("session-cancel", in: editor) }
            // Delete and Undo go through the model, not their buttons. Measured 2026-11-01 inside
            // the editor sheet: the point is correct and in bounds, but `hitTest` returns a SwiftUI
            // PlatformGroupContainer rather than the button, the identifier is in no accessibility
            // tree (`ax in sheet=false`, `ax in NSApp=false`), and no NSControl is found either, so
            // all three of `click`'s strategies miss and the written event stayed "edit". Every
            // window reports key=false because this suite never activates the app, which is why.
            // Clicking a SwiftUI button in an inactive app tests AppKit; this tests Glyph Time.
            let target = h.sessions.first { $0.project == "acme-api" }
            check(target != nil, "the edited session is on the week to delete")
            if let target {
                h.delete(target)
                let gone = last?.event == "delete" ? last?.id : nil
                check(gone == target.id, "Delete writes a delete line for that session")
                check(!h.sessions.contains { $0.id == target.id }, "and the session goes")
                await windowShot("27-deleted-undo")
                h.undelete(target)
                check(last?.event == "undelete", "Undo writes an undelete line")
                check(h.sessions.contains { $0.id == target.id }, "and brings it back")
            }
        } else {
            check(false, "this week has an acme-api session")
        }

        print("History: the vault goes away")
        // Fru, 2026-10-31: writing locally while the vault is away is right; a store that never
        // comes back is not. Lines written away go to the outbox and fold in when it returns.
        let away = Store.outbox
        check(Store.connected && Store.outbox != Store.folder, "with a folder chosen, the outbox is not where it writes")
        let parked = TimeEvent("start", at: .now.addingTimeInterval(-600), host: Store.host, project: "away-work")
        try? TimeLog.append(parked, to: away)
        try? TimeLog.append(TimeEvent("stop", at: .now.addingTimeInterval(-300), host: Store.host), to: away)
        check(Store.waiting == 2, "two lines wait in the outbox (\(Store.waiting))")
        check(Store.drainOutbox() == 2, "coming back folds them into the vault")
        check(Store.waiting == 0 && Store.outboxFiles().isEmpty, "and the outbox is empty after")
        MacHistory.refresh()
        check(h.projects.contains { $0.name == "away-work" }, "the away session is in History, on this device")
        // Safe to run twice: the same line never goes in a second time.
        try? TimeLog.append(parked, to: away)
        check(Store.drainOutbox() == 0 && Store.waiting == 0, "a line already in the vault is not written twice")
        MacHistory.refresh()
        check(h.sessions.filter { $0.project == "away-work" }.count == 1, "one away session, not two")
        for s in h.sessions where s.project == "away-work" { h.delete(s) } // leave the seeded week as it was
        // A write cut short leaves the file without its last newline. The fold must not run its
        // first line into that one: both would become one unreadable line, and the older one would
        // be the loss (Glyph Jot found this in its own log, 2026-10-31).
        let cut = TimeEvent("start", at: .now.addingTimeInterval(-900), host: Store.host, project: "cut-short")
        let target = Store.folder.appending(path: TimeLog.fileName(for: cut))
        var bytes = (try? Data(contentsOf: target)) ?? Data()
        if bytes.last == 0x0A {
            let whole = TimeLog.events(in: bytes).count
            bytes.removeLast()
            try? bytes.write(to: target)
            try? TimeLog.append(cut, to: away)
            try? TimeLog.append(TimeEvent("stop", at: .now.addingTimeInterval(-600), host: Store.host), to: away)
            check(Store.drainOutbox() == 2, "two lines fold into a file whose last newline is missing")
            let after = TimeLog.events(in: (try? Data(contentsOf: target)) ?? Data())
            check(after.count == whole + 2, "every line still reads, the one before it as well (\(after.count), want \(whole + 2))")
            MacHistory.refresh()
            check(h.sessions.contains { $0.project == "cut-short" }, "and the folded session is in History")
            for s in h.sessions where s.project == "cut-short" { h.delete(s) }
        } else {
            check(false, "this device's file ends with a newline, before the cut-short case")
        }
        // The outbox is whole folders, not one: Tracking and Captures hang off the same place as
        // the sessions, so a sweep of `sessions/` alone would strand them. Each folds by its own
        // shape: activity line by line like a session, a capture as a whole file that moves only
        // into a name that is free, never appended to and never written over. (Glyph Well, 2026-10-31.)
        let awayRoot = Store.outbox.deletingLastPathComponent()
        let span = ActivitySpan(start: .now.addingTimeInterval(-120), end: .now.addingTimeInterval(-60),
                                host: Store.host, app: "acme-viewer")
        try? ActivityLog.append([span], to: awayRoot.appending(path: "activity"))
        let shotDay = ActivityLog.day(.now), shotName = "120000.\(Store.host).jpg"
        let awayShot = awayRoot.appending(path: "captures/\(shotDay)/\(shotName)")
        try? FileManager.default.createDirectory(at: awayShot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(count: 1200).write(to: awayShot)
        // A project note written while the vault was away is a whole file too, and sits in a third
        // folder off the same root.
        let awayNote = awayRoot.appending(path: "projects/away-work.md")
        try? FileManager.default.createDirectory(at: awayNote.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "---\nproject: away-work\n---\n\nWhat it was for.\n".write(to: awayNote, atomically: true, encoding: .utf8)
        check(Store.drainOutbox() == 3, "coming back folds the activity line and carries the capture and the note")
        let liveNote = MacHistory.notesFolder.appending(path: "away-work.md")
        check(FileManager.default.fileExists(atPath: liveNote.path) && !FileManager.default.fileExists(atPath: awayNote.path),
              "the project note is in the folder's own projects, and gone from the outbox")
        try? FileManager.default.removeItem(at: liveNote)
        check(ActivityLog.read(Activity.folder, days: [shotDay]).contains { $0.app == "acme-viewer" },
              "the activity line is in this device's own day file in the vault")
        let liveShot = Captures.day().appending(path: shotName)
        check(FileManager.default.fileExists(atPath: liveShot.path) && !FileManager.default.fileExists(atPath: awayShot.path),
              "the capture is in the vault's captures and gone from the outbox")
        // A name already taken is left alone: the image in the vault is never written over, and the
        // waiting one is never deleted on the strength of a write that did not happen.
        try? FileManager.default.createDirectory(at: awayShot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(count: 7).write(to: awayShot)
        check(Store.drainOutbox() == 0, "a capture whose name is taken is not carried")
        check(((try? Data(contentsOf: liveShot))?.count ?? 0) == 1200, "the one in the vault is untouched")
        check(FileManager.default.fileExists(atPath: awayShot.path), "and the waiting one is left where it is")
        try? FileManager.default.removeItem(at: awayShot.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: liveShot)
        // A name that is a folder on one side and a file on the other is a taken name too: both are
        // left alone, and the fold steps past it instead of stopping on it.
        let clash = MacHistory.notesFolder.appending(path: "clash.md")
        try? FileManager.default.createDirectory(at: MacHistory.notesFolder, withIntermediateDirectories: true)
        try? "a note".write(to: clash, atomically: true, encoding: .utf8)
        let inClash = awayRoot.appending(path: "projects/clash.md/inside.md")
        try? FileManager.default.createDirectory(at: inClash.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "not a note".write(to: inClash, atomically: true, encoding: .utf8)
        try? "second".write(to: awayRoot.appending(path: "projects/second.md"), atomically: true, encoding: .utf8)
        check(Store.drainOutbox() == 1, "the clashing name is stepped over and the note beside it is still carried")
        check((try? String(contentsOf: clash, encoding: .utf8)) == "a note", "the file of that name is untouched")
        check(FileManager.default.fileExists(atPath: inClash.path), "and what waits under the clashing name is left where it is")
        try? FileManager.default.removeItem(at: clash)
        try? FileManager.default.removeItem(at: inClash.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: MacHistory.notesFolder.appending(path: "second.md"))

        print("History: a project")
        // Opened through the window's own entry point rather than by clicking the breakdown slice,
        // for the reason above: a click on a SwiftUI control does not land while the app is
        // inactive. `HistoryMac.select` is what the slice calls, so the page under test is the same.
        await click("slice-acme-api")
        if historyFrames["project-title"] == nil { HistoryMac.select?("acme-api"); await wait(0.5) }
        check(historyFrames["project-title"] != nil && historyFrames["project-start-again"] != nil, "a project in the breakdown opens its page")
        await windowShot("28-project", project: "acme-api")
        await click("project-start-again")
        check(Clock.shared.running && Clock.shared.project == "acme-api" && last?.event == "start", "Start Again on its page starts a new session")
        Clock.shared.stop()
        await click("project-hide")
        check(h.projects.first { $0.name == "acme-api" }?.hidden == true && last?.event == "hide", "Hide from Recent, from History")
        check(Clock.shared.hidden.contains { $0.name == "acme-api" }, "and the clock's Recent agrees")
        await windowShot("29-project-hidden", project: "acme-api")
        await click("project-hide")
        check(h.projects.first { $0.name == "acme-api" }?.hidden == false, "Show in Recent puts it back")

        print("History: renaming a project")
        let was = h.sessions(of: "acme-api").count
        await click("project-rename")
        check(w.attachedSheet != nil, "the pencil by the title opens Rename Project")
        await windowShot("29b-project-rename", w.attachedSheet)
        if let sheet = w.attachedSheet { await click("rename-cancel", in: sheet) }
        check(w.attachedSheet == nil && last?.event != "rename", "Cancel closes it and writes nothing")
        // Rename with the name it already has: the button works, and nothing is written.
        await click("project-rename")
        if let sheet = w.attachedSheet { await click("rename-save", in: sheet) }
        check(w.attachedSheet == nil && last?.event != "rename", "Rename with the same name closes it and writes nothing")
        // The new name itself goes through the model: the check has no way to type into a sheet.
        h.rename("acme-api", to: "acme-platform")
        check(last?.event == "rename" && last?.project == "acme-api" && last?.label == "acme-platform", "a rename is one line, the old name and the new")
        check(h.sessions(of: "acme-platform").count == was && h.sessions(of: "acme-api").isEmpty, "every session takes the new name (\(was))")
        check(h.notes["acme-platform"]?.initiative == "Client work" && h.notes["acme-api"] == nil, "the project's note moves with it")
        check(Clock.shared.projects.contains { $0.name == "acme-platform" }, "and the clock's Recent agrees")
        await windowShot("29c-project-renamed", project: "acme-platform")
        h.rename("acme-platform", to: "acme-api")
        check(h.sessions(of: "acme-api").count == was, "renamed back, the sessions follow again")
        HistoryMac.select?("acme-api")
        await wait(0.4)
        if Store.vault != nil {
            MacHistory.suggest("acme-api", "product")
            MacHistory.suggest("acme-api", "product")
            let prop = (try? String(contentsOf: Store.vault!.appending(path: "data/apps/crm/proposals/\(TimeLog.month(.now)).jsonl"), encoding: .utf8)) ?? ""
            check(prop.split(separator: "\n").count == 1 && prop.contains("\"source\":\"time\"") && prop.contains("\"path\":\"data/apps/time/projects/acme-api.md\"") && prop.contains("\"status\":\"pending\""), "Suggest for Glyph CRM adds one pending suggestion, never twice")
            check(!FileManager.default.fileExists(atPath: Store.vault!.appending(path: "data/entities").path), "no entity page is written")
        }
        await click("history-overview")
        check(historyFrames["history-total"] != nil, "back to the overview")

        print("History: the two Mac bugs")
        Clock.shared.start(project: "quick-one")
        Clock.shared.hide("quick-one") // the same second it started
        check(Clock.shared.hidden.contains { $0.name == "quick-one" } && h.projects.first { $0.name == "quick-one" }?.hidden == true, "hidden in the second it started, it stays hidden")
        await wait(2.2)
        Clock.shared.stop()
        let quick = Clock.shared.today.first { $0.project == "quick-one" }
        check(quick.map { TimeLog.span($0.seconds).hasSuffix(" s") } == true, "a session under a minute reads in seconds (\(quick.map { TimeLog.span($0.seconds) } ?? "-")), never 0 min")
        let menu = NSMenu()
        StatusMenu.shared.menuNeedsUpdate(menu)
        check(menu.items.contains { $0.attributedTitle?.string.hasPrefix("quick-one\t") == true && $0.attributedTitle?.string.hasSuffix(" s") == true }, "the menu's Today shows it in seconds too")
        check(menu.items.contains { $0.title == "History..." }, "the menu opens History")

        print("History: empty, sizes")
        h.period = .week
        h.anchor = HistoryMath.calendar.date(byAdding: .year, value: -3, to: .now)!
        await wait(0.6)
        check(historyFrames["history-empty"] != nil || h.inRange.isEmpty, "a week with nothing says so")
        await windowShot("30-history-empty")
        h.anchor = .now
        w.setContentSize(NSSize(width: 780, height: 600))
        await wait(0.8)
        await windowShot("31-history-small")
        check(w.frame.width >= 760, "the smallest window still fits (\(Int(w.frame.width)) pt)")
        w.setContentSize(NSSize(width: 1600, height: 1000))
        await wait(0.8)
        await windowShot("32-history-large")
        w.close()
        HistoryTest.frame = nil
    }
}
