import AppKit
import GlyphVault

/// `GlyphTime --uitest <out dir> -folder <empty dir>`: drives the real app the way a person would.
/// It presses the edge clock's own buttons through their accessibility actions (what VoiceOver
/// does: the button's real action), reads the session file after every step, and saves a picture
/// of each state in <out dir>. Nudges, countdowns and idle run on a fast clock. Needs no permission.
@MainActor
enum UITest {
    static let on = CommandLine.arguments.contains("--uitest")
    /// Test hooks: seconds in a minute, seconds idle, seconds a nudge stays.
    static var minute: Double?
    /// Someone is at the Mac unless a step says otherwise (the test Mac itself sits idle).
    static var idle: Double? = on ? 0 : nil
    static var nudgeSeconds: Double?

    static var out = URL(fileURLWithPath: NSTemporaryDirectory())
    static var failures = 0

    static func start() {
        guard on, let i = CommandLine.arguments.firstIndex(of: "--uitest") else { return }
        if i + 1 < CommandLine.arguments.count { out = URL(fileURLWithPath: CommandLine.arguments[i + 1]) }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        if let a = CommandLine.arguments.firstIndex(of: "--appearance"), a + 1 < CommandLine.arguments.count {
            NSApp.appearance = NSAppearance(named: CommandLine.arguments[a + 1] == "dark" ? .darkAqua : .aqua)
        }
        Task {
            try? await Task.sleep(for: .seconds(1))
            await run()
            print(failures == 0 ? "UI ALL PASSED" : "UI \(failures) FAILED")
            fflush(stdout)
            exit(failures == 0 ? 0 : 1)
        }
    }

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "  PASS  \(what)" : "  FAIL  \(what)")
        fflush(stdout)
        if !ok { failures += 1 }
    }

    static func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    /// Waits up to `limit` seconds for a condition.
    static func until(_ limit: Double, _ ok: () -> Bool) async -> Bool {
        for _ in 0..<Int(limit * 10) {
            if ok() { return true }
            await wait(0.1)
        }
        return ok()
    }

    static var lines: [TimeEvent] { TimeLog.read(Store.folder, months: TimeLog.recentMonths()).filter { $0.host == Store.host } }
    static var last: TimeEvent? { lines.last }

    // MARK: Finding and clicking

    /// Each control's frame in the panel, kept up to date by the views (`testFrame`).
    static var frames: [String: CGRect] = [:]

    /// The control is on screen now: its frame lies inside the panel's current content.
    static func find(_ text: String) -> CGRect? {
        guard let f = frames[text], let v = Edge.shared.panel.contentView, v.bounds.contains(CGPoint(x: f.midX, y: f.midY)) else { return nil }
        return f
    }

    /// A real click: mouse down and up at the control's centre, sent to the panel the way the
    /// window server would. The panel stays non-activating, so nothing else loses focus.
    @discardableResult
    static func press(_ text: String) async -> Bool {
        guard let f = find(text), let v = Edge.shared.panel.contentView else { check(false, "the edge shows '\(text)'"); return false }
        let panel = Edge.shared.panel!
        let point = NSPoint(x: f.midX, y: v.bounds.height - f.midY) // SwiftUI measures from the top
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                panel.sendEvent(e)
            }
            await wait(0.05)
        }
        await wait(0.4)
        return true
    }

    /// Moves this run's files aside (inside the test folder), so back-dated lines start clean.
    static func freshFile() {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: Store.folder.path)) ?? [] where !name.hasPrefix("earlier-") {
            try? FileManager.default.moveItem(at: Store.folder.appendingPathComponent(name),
                                              to: Store.folder.appendingPathComponent("earlier-\(UUID().uuidString.prefix(6))-" + name))
        }
    }

    static func shot(_ name: String) async {
        await wait(0.45) // let the animation settle
        guard let v = Edge.shared.panel.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
    }

    static func open(_ on: Bool) async {
        Edge.shared.hover(on)
        await wait(on ? 0.4 : 0.9)
    }

    // MARK: The run

    static func run() async {
        let clock = Clock.shared, edge = Edge.shared
        let screen = NSScreen.screens[0].visibleFrame
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        print("UI test: host \(Store.host), folder \(Store.folder.path), front \(front ?? "-")")

        print("Nothing running")
        check(clock.session == nil && lines.isEmpty, "starts with nothing running and an empty folder")
        check(edge.panel.isVisible && edge.panel.frame.width < 30, "a thin tab on the edge (\(Int(edge.panel.frame.width)) pt)")
        check(abs(edge.panel.frame.maxX - screen.maxX) < 1, "flush with the right edge of the screen")
        check(!edge.panel.canBecomeMain && edge.panel.styleMask.contains(.nonactivatingPanel), "the panel can't take the app's focus")
        await shot("01-tab")
        await open(true)
        check(find("Start") != nil && find("More") != nil, "hover shows Start and More")
        await shot("02-open-idle")

        print("Start, pause, resume")
        await press("Start")
        check(clock.running && last?.event == "start", "Start runs the clock and writes a start line")
        check(["repo", "app"].contains(last?.source ?? "") && !(last?.project ?? "").isEmpty, "the project is guessed (\(last?.project ?? "-"), from \(last?.source ?? "-"))")
        check(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == front && !NSApp.isActive, "the front app is still in front; Glyph Time never became active")
        await wait(2.1)
        check(clock.elapsed >= 2 && clock.display.hasPrefix("0:0"), "it counts up (\(clock.display))")
        await shot("03-open-running")
        await press("Pause")
        check(clock.paused && last?.event == "pause" && last?.reason == "user", "Pause pauses and writes why (user)")
        let held = clock.display
        await wait(1.2)
        check(clock.display == held, "the clock stands still while paused")
        await shot("04-open-paused")
        await open(false)
        await shot("05-count-paused")
        await open(true)
        await press("Resume")
        check(clock.running && last?.event == "resume", "Resume carries on")
        await open(false)
        check(edge.panel.frame.width < 140 && edge.panel.frame.width > 60, "at rest it is a small count (\(Int(edge.panel.frame.width)) pt)")
        await shot("06-count")

        print("Naming")
        clock.rename("acme-api")
        check(clock.project == "acme-api" && last?.event == "name" && !clock.guessed, "a name replaces the guess and is written")
        await open(true)
        await shot("07-open-named")
        await open(false)

        print("Nudges")
        nudgeSeconds = 2.5
        minute = 0.1 // 30 minutes = 3 seconds
        check(await until(5) { clock.nudge != nil }, "a nudge slides out at the boundary")
        await wait(0.5)
        check(clock.nudge?.contains("on acme-api") == true && edge.panel.isVisible && edge.panel.frame.width > 200, "it says how long and on what (\(clock.nudge ?? "-"))")
        await shot("08-nudge")
        await press("Keep going")
        check(clock.nudge == nil && last?.event == "nudge" && last?.answer == "keep" && clock.running, "Keep going answers it and the clock runs on")
        check(await until(5) { clock.nudge != nil }, "the next boundary nudges again")
        check(await until(5) { clock.nudge == nil }, "left alone, it fades back by itself")
        check(lines.last { $0.event == "nudge" }?.answer == "ignored", "an ignored nudge is written as ignored")
        let before = lines.filter { $0.event == "nudge" }.count
        await wait(2.2) // the skipped boundary passes; the one after is still a second away
        check(clock.nudge == nil && lines.filter { $0.event == "nudge" }.count == before, "after an ignored nudge the next boundary stays quiet")
        minute = nil
        check(await until(4) { clock.nudge == nil }, "back on a real clock, no more nudges")
        if clock.nudge != nil { await press("Keep going") }

        print("Count down")
        clock.start(project: "acme-api", countdown: 25)
        check(lines.suffix(2).map(\.event) == ["stop", "start"] && last?.countdown == 25, "a countdown stops the last session and starts a new one")
        check(clock.display == "25:00" || clock.display == "24:59", "it counts down from 25:00 (\(clock.display))")
        await shot("09-countdown")
        await open(true)
        await shot("10-countdown-open")
        await open(false)
        minute = 0.1
        check(await until(6) { clock.nudge == "Time is up on acme-api" }, "at zero it says the time is up")
        check(clock.display.hasPrefix("+"), "past zero it shows the time over (\(clock.display))")
        await shot("11-countdown-done")
        await press("Stop")
        check(clock.session == nil && last?.event == "stop" && lines.last { $0.event == "nudge" }?.answer == "stop", "Stop in the nudge ends the session")
        minute = nil
        await shot("12-tab-again")

        print("Menu bar")
        let menu = NSMenu()
        StatusMenu.shared.menuNeedsUpdate(menu)
        let titles = menu.items.map(\.title)
        for t in ["Start", "Start Named...", "Count Down", "Today", "Show Clock on the Edge", "Open Sessions Folder", "Settings...", "Quit Glyph Time"] {
            check(titles.contains(t), "the menu has \(t)")
        }
        check(menu.items.contains { $0.attributedTitle?.string.hasPrefix("acme-api\t") == true }, "Today lists acme-api with its time")
        if let start = menu.items.first(where: { $0.title == "Start" }) { menu.performActionForItem(at: menu.index(of: start)) }
        check(clock.running, "Start in the menu starts")
        if let b = StatusMenu.shared.item.button, let rep = b.bitmapImageRepForCachingDisplay(in: b.bounds) {
            b.cacheDisplay(in: b.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("14-menubar.png"))
        }
        check(NSImage(named: "MenuBar") != nil, "the menu bar shows the runner")
        check(menu.items.first?.title == "Glyph Time" && menu.items.first?.image != nil, "the menu is headed by the icon and Glyph Time")
        check(StatusMenu.shared.item.button?.title.contains("0:0") == true, "the menu bar shows the time (\(StatusMenu.shared.item.button?.title ?? "-"))")
        StatusMenu.shared.menuNeedsUpdate(menu)
        check(menu.items.contains { $0.title == "Pause" } && menu.items.contains { $0.title == "Name This Session..." }, "running, the menu offers Pause and Name")
        if let stop = menu.items.first(where: { $0.title == "Stop" }) { menu.performActionForItem(at: menu.index(of: stop)) }
        check(clock.session == nil, "Stop in the menu stops")
        Clock.shared.toggle()
        check(clock.running, "the shortcut's action starts")
        Clock.shared.toggle()
        check(clock.paused, "and pauses")
        clock.stop()

        freshFile()
        print("Away: idle, lock, sleep")
        try? TimeLog.append(TimeEvent("start", at: .now.addingTimeInterval(-6000), host: Store.host, project: "northwind", source: "named"), to: Store.folder)
        clock.load()
        idle = 400
        check(await until(7) { clock.paused }, "five idle minutes pause the clock")
        let pausedAt = lines.last { $0.event == "pause" }
        check(pausedAt?.reason == "idle" && abs((pausedAt?.ts.timeIntervalSinceNow ?? 0) + 400) < 10, "the pause is dated when you left, not when it noticed")
        idle = 0
        check(await until(7) { clock.running }, "back within 30 minutes, it resumes")
        clock.stop()
        freshFile()
        try? TimeLog.append(TimeEvent("start", at: .now.addingTimeInterval(-6000), host: Store.host, project: "northwind", source: "named"), to: Store.folder)
        clock.load()
        idle = 4000
        check(await until(7) { clock.paused }, "away for over an hour")
        let left = lines.last { $0.event == "pause" }?.ts
        idle = 0
        check(await until(7) { clock.session == nil }, "back after more than 30 minutes, the session has ended")
        check(last?.event == "stop" && last?.ts == left, "and it ended when you left")
        idle = 0

        clock.start()
        DistributedNotificationCenter.default().postNotificationName(.init("com.apple.screenIsLocked"), object: nil, deliverImmediately: true)
        check(await until(3) { clock.paused && clock.session?.pauseReason == "lock" }, "locking the screen pauses")
        DistributedNotificationCenter.default().postNotificationName(.init("com.apple.screenIsUnlocked"), object: nil, deliverImmediately: true)
        check(await until(3) { clock.running }, "unlocking resumes")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        check(clock.paused && clock.session?.pauseReason == "sleep", "sleep pauses")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        idle = 0
        check(await until(7) { clock.running }, "the first touch after waking resumes")
        idle = 0
        await open(true)
        await press("Stop")
        await open(false)
        check(clock.session == nil, "Stop on the edge stops")

        print("The file is the timer")
        freshFile()
        let t = Date.now.addingTimeInterval(-13) // as if the app had quit 13 seconds after a start
        try? TimeLog.append(TimeEvent("start", at: t, host: Store.host, project: "beta", source: "named"), to: Store.folder)
        minute = 0.2 // 30 minutes = 6 seconds: 2 boundaries have passed, the next is 4 seconds away
        clock.load()
        check(clock.running && clock.project == "beta" && abs(clock.elapsed - Date.now.timeIntervalSince(t)) < 1.5, "a session left open in the file is picked up with its time (\(clock.display))")
        await wait(1.5)
        check(clock.nudge == nil, "no storm of missed nudges on launch")
        check(await until(6) { clock.nudge != nil }, "the next boundary still nudges")
        minute = nil
        clock.stop()

        print("Edge on and off, settings")
        edge.shown = false
        check(!edge.panel.isVisible, "Hide takes the clock off the edge")
        edge.shown = true
        check(edge.panel.isVisible, "Show puts it back")
        SettingsWindow.show()
        await wait(1)
        if let w = SettingsWindow.current, let v = w.contentView?.superview, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("13-settings.png"))
            check(w.isVisible && w.frame.height > 300, "Settings opens (\(Int(w.frame.width))x\(Int(w.frame.height)))")
            w.close()
        }

        print("The file")
        let all = lines
        let raw = (try? String(contentsOf: Store.folder.appendingPathComponent(TimeLog.fileName(for: all[0])), encoding: .utf8)) ?? ""
        check(raw.split(separator: "\n").count == all.count, "every line in the file reads back (\(all.count) lines)")
        check(TimeLog.sessions(all).allSatisfy { $0.end != nil }, "every session is closed")
        check(!raw.contains("title") && !raw.contains("http"), "no window titles or URLs are kept")
        if let vault = Store.vault {
            check(Store.folder.path.hasSuffix("data/apps/time/sessions"), "in a vault, sessions go to data/apps/time/sessions")
            // A 20-minute session on another device (the phone, say), then a stop here rewrites the summary.
            let start = Calendar.current.startOfDay(for: .now).addingTimeInterval(60)
            try? TimeLog.append(TimeEvent("start", at: start, host: "phone-test", device: "Test Phone", project: "acme-api", source: "named"), to: Store.folder)
            try? TimeLog.append(TimeEvent("stop", at: start.addingTimeInterval(1200), host: "phone-test"), to: Store.folder)
            clock.start(project: "northwind")
            clock.stop()
            let summary = (try? String(contentsOf: vault.appending(path: "data/domains/time/source/apps/time/summary.md"), encoding: .utf8)) ?? ""
            check(summary.hasPrefix("# Glyph Time") && summary.contains("## Today") && summary.contains("- acme-api: 20 min (1 session)") && summary.contains("- Test Phone: 20 min"), "the time domain's summary has every device's sessions")
        }
    }
}
