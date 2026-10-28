import AppKit
import Carbon.HIToolbox
import GlyphVault
import os
import ServiceManagement
import SwiftUI

let log = Logger(subsystem: "dev.fru.time", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: HotKey?
    private var minimizeKey: HotKey?

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
        // Control-Option-T: start, pause or resume from anywhere, without leaving what you're in.
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey)) { Clock.shared.toggle() }
        // Control-Option-M: keep the card open, or fold it to the tile.
        minimizeKey = HotKey(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey)) { Edge.shared.toggleKeepOpen() }
        log.notice("launch: host \(Store.host, privacy: .public), folder \(Store.folder.path, privacy: .public), repo names \(AXIsProcessTrusted()), hotkey \(self.hotKey?.registered ?? false)")
        UITest.start()
    }

    /// A click on the Dock icon: the card if it's closed (and focus goes straight back to the app you
    /// were in), Settings if the card or Settings is already open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if Edge.shared.hovering || SettingsWindow.current?.isVisible == true {
            SettingsWindow.show()
        } else {
            Edge.shared.peek()
            NSApp.hide(nil) // the panel can't hide, so it stays; the front app gets its focus back
        }
        return false
    }
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
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
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
