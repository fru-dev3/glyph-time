import AppKit
import Carbon.HIToolbox
import GlyphCapture
import UserNotifications
import GlyphVault
import os
import ServiceManagement
import SwiftUI

let log = Logger(subsystem: "dev.fru.time", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: HotKey?
    private var minimizeKey: HotKey?
    private var filedTimer: Timer?
    private var requestTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        // One clock per Mac.
        let me = ProcessInfo.processInfo.processIdentifier
        if !UITest.on, NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0.processIdentifier != me }) {
            NSApp.terminate(nil)
            return
        }
        Clock.shared.load()
        Edge.shared.setUp()
        StatusMenu.shared.setUp()
        Presence.apply() // after launch as an accessory, so joining the Dock takes no focus
        Watch.start()
        Activity.start() // apps and tabs (Settings), and what screen captures may see
        Captures.start()
        // Filed documents' deadlines (the filer's notes): armed now and every 6 hours.
        Reminders.armFiled()
        filedTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in MainActor.assumeIsolated { Reminders.armFiled() } }
        // Reminders agents on this Mac asked for (glyphcore-report run time ...): armed here within a minute.
        Reminders.armRequests()
        requestTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { Reminders.armRequests() } }
        // Control-Option-T: start, pause or resume from anywhere, without leaving what you're in.
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey)) { Clock.shared.toggle() }
        // Control-Option-M: keep the card open, or fold it to the tile.
        minimizeKey = HotKey(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey)) { Edge.shared.toggleKeepOpen() }
        log.notice("launch: host \(Store.host, privacy: .public), folder \(Store.folder.path, privacy: .public), repo names \(AXIsProcessTrusted()), hotkey \(self.hotKey?.registered ?? false)")
        UITest.start()
    }

    /// A click on the Dock icon: the card if it's closed (and focus goes straight back to the app you
    /// were in), History if the card or a window is already open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if Edge.shared.hovering || SettingsWindow.current?.isVisible == true || HistoryWindow.window?.isVisible == true {
            HistoryWindow.show()
        } else {
            Edge.shared.peek()
            NSApp.hide(nil) // the panel can't hide, so it stays; the front app gets its focus back
        }
        return false
    }

    /// The Dock icon's menu: History and Settings.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [("History", #selector(openHistory)), ("Settings...", #selector(openSettings))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }
    @objc func openHistory() { HistoryWindow.show() }
    @objc func openSettings() { SettingsWindow.show() }
}

/// Where Glyph Time shows besides the edge: the Dock, the menu bar, or both (by default). Never
/// neither, or there'd be no way back to Settings once the edge clock is hidden.
@MainActor
enum Presence {
    static let dockKey = "showInDock", barKey = "showInMenuBar"
    /// The UI check keeps its own settings, so it never changes the real ones.
    private static let store = UITest.on ? UserDefaults(suiteName: "dev.fru.time.uitest")! : .standard

    static var inDock: Bool {
        get { store.object(forKey: dockKey) == nil || store.bool(forKey: dockKey) } // "NO" from the command line too
        set { if newValue || inMenuBar { store.set(newValue, forKey: dockKey); apply() } }
    }
    static var inMenuBar: Bool {
        get { store.object(forKey: barKey) == nil || store.bool(forKey: barKey) } // "NO" from the command line too
        set { if newValue || inDock { store.set(newValue, forKey: barKey); apply() } }
    }

    static func apply() {
        let dock = inDock || !inMenuBar // both off (set by hand) still leaves the Dock
        NSApp.setActivationPolicy(dock ? .regular : .accessory)
        StatusMenu.shared.item?.isVisible = inMenuBar
        // Changing the policy can send Settings behind other windows: bring it back.
        if let w = SettingsWindow.current, w.isVisible {
            DispatchQueue.main.async { NSApp.activate(); w.makeKeyAndOrderFront(nil) }
        }
    }
}

/// The menu bar item: the time while it runs, everything the edge does, and today by project.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    static let shared = StatusMenu()
    static let countdowns = [15, 25, 50, 90]
    private(set) var item: NSStatusItem!
    private var timer: Timer?

    func setUp() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        update()
    }

    /// The icon, and the time beside it while a session is open (once a second).
    func update() {
        guard let button = item?.button else { return }
        let clock = Clock.shared
        // The runner, drawn for the menu bar (assets/MenuBar.png, @2x); a template, so it takes the bar's colour.
        let image = NSImage(named: "MenuBar") ?? NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        image?.isTemplate = true
        image?.accessibilityDescription = "Glyph Time"
        button.appearsDisabled = clock.paused
        button.image = image
        button.imagePosition = .imageLeading
        button.attributedTitle = NSAttributedString(string: clock.session == nil ? "" : " " + clock.display, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: clock.paused ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        if clock.session != nil, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { StatusMenu.shared.update() }
            }
            timer?.tolerance = 0.2
        } else if clock.session == nil {
            timer?.invalidate()
            timer = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let clock = Clock.shared
        clock.refreshToday()
        menu.removeAllItems()
        func add(_ title: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = [], _ action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = self
            item.representedObject = action as AnyObject
            menu.addItem(item)
        }
        func note(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        let head = NSMenuItem(title: "Glyph Time", action: nil, keyEquivalent: "")
        head.isEnabled = false
        let icon = NSApp.applicationIconImage.copy() as! NSImage
        icon.size = NSSize(width: 18, height: 18)
        head.image = icon
        head.attributedTitle = NSAttributedString(string: "Glyph Time", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
        menu.addItem(head)
        menu.addItem(.separator())
        if let problem = Store.problem { note(problem) }
        if clock.session != nil {
            note("\(clock.display)  \(clock.project)")
            menu.addItem(.separator())
            if clock.paused { add("Resume", "t", [.control, .option]) { clock.resume() } }
            else { add("Pause", "t", [.control, .option]) { clock.pause() } }
            add("Stop") { clock.stop() }
            add("Name This Session...") { Ask.name() }
        } else {
            add("Start", "t", [.control, .option]) { clock.start() }
            add("Start Named...") { Ask.start() }
            add(Voice.shared.dictation.on ? "Done Talking" : "Start by Voice") { Voice.shared.toggle() }
        }
        let down = NSMenuItem(title: "Count Down", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for m in Self.countdowns {
            let i = NSMenuItem(title: "\(m) minutes", action: #selector(run(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = { clock.start(project: clock.session?.project, countdown: m) } as AnyObject
            sub.addItem(i)
        }
        down.submenu = sub
        menu.addItem(down)

        // Recent: a click starts a new session on that project; hold Option to hide it instead.
        if !clock.projects.isEmpty {
            menu.addItem(.separator())
            note("Recent")
            for p in clock.recent.prefix(5) {
                let start = item(p.name) { clock.start(project: p.name) }
                start.attributedTitle = row(p.name, Self.times(p), ink: .labelColor)
                start.toolTip = "Start a new session on \(p.name)"
                menu.addItem(start)
                let hide = item("Hide \(p.name.prefix(28)) from Recent") { clock.hide(p.name) }
                hide.keyEquivalentModifierMask = [.option]
                hide.isAlternate = true
                menu.addItem(hide)
            }
            add("All Projects...") { Ask.start() }
            if !clock.hidden.isEmpty {
                let hidden = NSMenuItem(title: "Hidden", action: nil, keyEquivalent: "")
                let list = NSMenu()
                let head = NSMenuItem(title: "Choose one to put back on Recent", action: nil, keyEquivalent: "")
                head.isEnabled = false
                list.addItem(head)
                for p in clock.hidden { list.addItem(item(p.name) { clock.unhide(p.name) }) }
                hidden.submenu = list
                menu.addItem(hidden)
            }
        }

        menu.addItem(.separator())
        if clock.today.isEmpty {
            note("Nothing timed today")
        } else {
            note("Today")
            for t in clock.today.prefix(8) {
                // A past session: click to start again (a new session, never the old one reopened).
                let named = t.project != "Unnamed"
                let i = item("") { clock.start(project: t.project) }
                i.isEnabled = named
                if !named { i.action = nil }
                i.attributedTitle = row(t.project, TimeLog.span(t.seconds))
                if named { i.toolTip = "Start again" }
                menu.addItem(i)
            }
        }

        menu.addItem(.separator())
        let edge = NSMenuItem(title: "Show Clock on the Edge", action: #selector(run(_:)), keyEquivalent: "")
        edge.target = self
        edge.state = Edge.shared.shown ? .on : .off
        edge.representedObject = { Edge.shared.shown.toggle() } as AnyObject
        menu.addItem(edge)
        add(Edge.shared.keepOpen ? "Minimize Clock" : "Keep Clock Open") { Edge.shared.toggleKeepOpen() }
        add("Reset Clock Position") { Edge.shared.resetPosition() }
        add("History...", "y", [.command]) { HistoryWindow.show() }
        add("Open Sessions Folder") { NSWorkspace.shared.open(Store.folder) }
        add("Settings...", ",", [.command]) { SettingsWindow.show() }
        menu.addItem(.separator())
        add("Quit Glyph Time", "q", [.command]) { NSApp.terminate(nil) }
    }

    private func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        i.target = self
        i.representedObject = action as AnyObject
        return i
    }

    /// "35 min today · 6 h", or the total alone when nothing today.
    static func times(_ p: TimeProject) -> String {
        p.today >= 60 ? "\(TimeLog.span(p.today)) today · \(TimeLog.span(p.total))" : TimeLog.span(p.total)
    }

    /// "acme-api ........ 1 h 12 min": the name, then the time on a right tab stop in grey.
    private func row(_ name: String, _ value: String, ink: NSColor = .secondaryLabelColor) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.tabStops = [NSTextTab(textAlignment: .right, location: 260)]
        let font = NSFont.menuFont(ofSize: 0)
        let s = NSMutableAttributedString(string: "\(name.prefix(28))\t", attributes: [.paragraphStyle: p, .font: font, .foregroundColor: ink])
        s.append(NSAttributedString(string: value, attributes: [.paragraphStyle: p, .font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        return s
    }

    @objc private func run(_ sender: NSMenuItem) { (sender.representedObject as? () -> Void)?() }
}

/// Start by voice, one control: tap, say the project, tap again and the clock starts on it. The
/// mic on the edge clock and Start by Voice in the menu bar share it.
@MainActor
final class Voice {
    static let shared = Voice()
    let dictation = LiveDictation()
    init() {
        dictation.onFinal = { words in Voice.perform(words) }
    }

    /// The sentence a question was asked about; the answer is read together with it.
    static var pending: (said: String, at: Date)?

    /// One sentence, done (VoiceForm.understand, the same reading as the phone's): a timer on a
    /// project (a countdown with "for 10 minutes"), stop, pause, resume, or an alarm or reminder,
    /// once or repeating until an end, as notifications and a line in the file. What it understood
    /// shows on the edge clock with Undo; when something is missing it asks, and the next words answer.
    static func perform(_ words: String) {
        Task { @MainActor in
            var said = words
            if let p = pending, Date.now.timeIntervalSince(p.at) < 120 { said = p.said + " " + words }
            pending = nil
            let plan = await VoiceForm.understand(said)
            let clock = Clock.shared
            switch plan.kind {
            case .ask:
                pending = (said, .now)
                clock.say(plan.question ?? "Say that again?")
            case .timer:
                clock.start(project: plan.title.isEmpty ? nil : String(plan.title.prefix(80)), countdown: plan.countdown)
                let s = clock.session
                clock.say(Schedule.say(plan)) {
                    clock.stop()
                    if let s { MacHistory.shared.delete(s) } // never happened: out of History too
                }
            case .stop: clock.stop()
            case .chat: clock.say(plan.reply ?? Plan.nothing)
            case .pause: clock.pause(); clock.say("Paused") { clock.resume() }
            case .resume: clock.resume(); clock.say("Going again") { clock.pause() }
            case .routine:
                // A line the phone's Routines page shows (GlyphVault `Routine`); Undo archives it, never deletes.
                var r = Routine(id: UUID().uuidString, title: plan.title, days: plan.days, time: plan.first)
                if let rule = plan.rule, let n = Int(rule.dropFirst()) { if rule.hasPrefix("w") { r.perWeek = n } else { r.perDay = n } }
                Store.write(TimeLog.routineLine(r, host: Store.host, device: Store.device))
                clock.say(Schedule.say(plan)) { r.archived = true; Store.write(TimeLog.routineLine(r, host: Store.host, device: Store.device)) }
            case .alarm, .reminder:
                guard let at = plan.first else { return }
                let kind = plan.kind.rawValue
                var made = [(kind, Reminders.add(kind, at: at, days: plan.days, rule: plan.rule, from: plan.from, until: plan.until, label: plan.title))]
                if let lead = plan.lead, lead > 0 {
                    let shift = -Double(lead) * 60
                    made.append(("reminder", Reminders.add("reminder", at: at.addingTimeInterval(shift), days: plan.days, rule: plan.rule, from: plan.from,
                                                           until: plan.until?.addingTimeInterval(shift), label: "\(plan.title) in \(lead) min")))
                }
                clock.say(Schedule.say(plan)) {
                    for (k, id) in made { Reminders.cancel(k, id) }
                }
            }
        }
    }
    func toggle() { dictation.toggle(); Edge.shared.update() }
}

/// Reminders said to the Mac: a notification (weekly per day when it repeats) and a line in the
/// session file, as the phone writes them, so they are context too.
@MainActor
enum Reminders {
    static let rungKey = "filedRung"

    /// The filer's deadlines (`FiledReminders.plan` over `Filing.index()`), each one notification, once:
    /// what was armed is remembered, and one whose document left (undone, refiled) is taken back.
    static func armFiled() {
        guard !UITest.on, let vault = Store.vault else { return }
        let rung = Set(UserDefaults.standard.stringArray(forKey: rungKey) ?? [])
        Task.detached(priority: .utility) {
            let notes = Filing(root: vault).index().filter { $0.status == "filed" }
            let all = FiledReminders.plan(notes.flatMap { n in n.deadlines.map { (id: n.id, title: n.title, kind: $0.kind, date: $0.date) } }, now: .now)
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("filing-") }
            let want = Set(all.map(\.id))
            center.removePendingNotificationRequests(withIdentifiers: pending.filter { !want.contains($0) })
            let new = all.filter { !rung.contains($0.id) }
            guard !new.isEmpty, (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            for item in new {
                let content = UNMutableNotificationContent()
                content.title = item.label
                content.sound = .default
                try? await center.add(UNNotificationRequest(identifier: item.id, content: content,
                                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, item.at.timeIntervalSinceNow), repeats: false)))
            }
            await MainActor.run {
                // ponytail: grows by one short id per deadline ever armed; prune by date if it ever matters.
                let kept = (UserDefaults.standard.stringArray(forKey: rungKey) ?? []) + new.map(\.id)
                UserDefaults.standard.set(Array(Set(kept)).sorted(), forKey: rungKey)
            }
        }
    }

    /// Reminders an agent on this Mac queued (`glyphcore-report run time request_reminder ...` writes
    /// data/apps/time/requests.<this host>.jsonl): each one nobody answered in any requests file (the phone's
    /// too) is taken, made like a spoken one, and answered on its id. Alarms and timers stay for the iPhone.
    static func armRequests() {
        guard !UITest.on, let vault = Store.vault else { return }
        let folder = vault.appending(path: "data/apps/time")
        let mine = folder.appending(path: "requests.\(Store.host).jsonl")
        guard FileManager.default.fileExists(atPath: mine.path) else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let answered = Set(files.filter { $0.lastPathComponent.hasPrefix("requests.") }
            .flatMap { TimeRequest.all(in: $0) }.filter { $0.event != "request" }.map(\.id))
        let todo = TimeRequest.pending(in: mine).filter { $0.kind == "reminder" && !answered.contains($0.id) }
        for r in todo {
            TimeRequest.append(TimeRequest(id: r.id, event: "taken"), to: mine) // first, so a second pass never makes it twice
            Task { @MainActor in
                let plan = await VoiceForm.understand(r.command ?? "")
                guard plan.kind == .reminder, let at = plan.first else {
                    TimeRequest.append(TimeRequest(id: r.id, event: "failed", text: plan.question ?? "No time in that"), to: mine)
                    return
                }
                add("reminder", at: at, days: plan.days, rule: plan.rule, from: plan.from, until: plan.until, label: plan.title)
                if let lead = plan.lead, lead > 0 {
                    let shift = -Double(lead) * 60
                    add("reminder", at: at.addingTimeInterval(shift), days: plan.days, rule: plan.rule, from: plan.from,
                        until: plan.until?.addingTimeInterval(shift), label: "\(plan.title) in \(lead) min")
                }
                TimeRequest.append(TimeRequest(id: r.id, event: "armed", text: Schedule.say(plan)), to: mine)
                log.notice("armed request \(r.id, privacy: .public)")
            }
        }
    }

    static func cancel(_ kind: String, _ id: String) {
        Store.write(TimeEvent(kind, host: Store.host, answer: "cancel", id: id))
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id] + (1...7).map { "\(id)-\($0)" } + (0..<24).map { "\(id)-x\($0)" })
    }

    @discardableResult
    static func add(_ kind: String, at: Date, days: [Int], rule: String? = nil, from: Date? = nil, until: Date? = nil, label: String) -> String {
        let id = UUID().uuidString
        Store.write(TimeEvent(kind, at: .now, host: Store.host, device: Store.device, at: at, label: label, id: id,
                              days: days.isEmpty ? nil : days, start: from, end: until, rule: rule))
        schedule(id, at, days, rule, until, label)
        return id
    }

    /// Weekly or once: one notification per day or one. With an end or another repeat: each of
    /// its next times.
    // ponytail: the next 24 times only; a long repeat on the Mac needs a top-up at launch if it matters.
    private static func schedule(_ id: String, _ at: Date, _ days: [Int], _ rule: String?, _ until: Date?, _ label: String) {
        guard !UITest.on else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            let content = UNMutableNotificationContent()
            content.title = label
            content.sound = .default
            func once(_ id: String, _ d: Date) async {
                try? await center.add(UNNotificationRequest(identifier: id, content: content,
                                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, d.timeIntervalSinceNow), repeats: false)))
            }
            if rule != nil || until != nil {
                for (i, d) in Schedule.fires(first: at, days: days, rule: rule, until: until, after: .now, limit: 24).enumerated() { await once("\(id)-x\(i)", d) }
            } else if !days.isEmpty {
                let hm = Calendar.current.dateComponents([.hour, .minute], from: at)
                for d in days {
                    var c = hm; c.weekday = d % 7 + 1
                    try? await center.add(UNNotificationRequest(identifier: "\(id)-\(d)", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: c, repeats: true)))
                }
            } else {
                await once(id, at)
            }
        }
    }
}

/// The one question Glyph Time asks: a name. It comes forward for that, then gives the screen back.
@MainActor
enum Ask {
    static func name() {
        guard let text = ask("Name this session", button: "Name", value: Clock.shared.session?.project ?? "") else { return }
        Clock.shared.rename(text)
    }

    static func start() {
        guard let text = ask("Start a session", button: "Start", value: "") else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Clock.shared.start(project: clean.isEmpty ? nil : clean)
    }

    /// Every project to pick from, typed ahead as you write.
    private static func ask(_ title: String, button: String, value: String) -> String? {
        let before = NSWorkspace.shared.frontmostApplication
        defer { if let before, before.bundleIdentifier != Bundle.main.bundleIdentifier { before.activate() } }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "A project, a client, anything you want to see the hours for."
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let field = NSComboBox(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        // Type-ahead over every project: the Recent ones first, then the hidden ones.
        Clock.shared.refreshToday()
        field.addItems(withObjectValues: (Clock.shared.recent + Clock.shared.hidden).map(\.name))
        field.numberOfVisibleItems = 10
        field.stringValue = value
        field.completes = true
        // Dictate first: Talk, say it, Done, and the alert answers itself with the words.
        // The words go back as said: a field still being edited would put its own text back.
        var said: String?
        let talk = DictateButton.hostingView(label: "Talk", tint: .office) { words in
            said = words.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            NSApp.stopModal(withCode: .alertFirstButtonReturn)
        }
        let row = NSStackView(views: [field, talk])
        row.orientation = .horizontal
        row.spacing = 8
        row.setFrameSize(NSSize(width: 260 + 8 + talk.frame.width, height: max(26, talk.frame.height)))
        alert.accessoryView = row
        alert.window.initialFirstResponder = field
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn ? (said ?? field.stringValue) : nil
    }
}

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Glyph Time Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    static var current: NSWindow? { window }
    /// Closed and let go, so the next show reads the settings afresh (the UI check).
    static func close() { window?.close(); window = nil }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // Presence moves it into the Dock once launched
        app.run()
    }
}
