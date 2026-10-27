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
        Watch.start()
        // Control-Option-T: start, pause or resume from anywhere, without leaving what you're in.
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey)) { Clock.shared.toggle() }
        log.notice("launch: host \(Store.host, privacy: .public), folder \(Store.folder.path, privacy: .public), repo names \(AXIsProcessTrusted()), hotkey \(self.hotKey?.registered ?? false)")
        UITest.start()
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

        menu.addItem(.separator())
        if clock.today.isEmpty {
            note("Nothing timed today")
        } else {
            note("Today")
            for t in clock.today.prefix(8) {
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.attributedTitle = row(t.project, TimeLog.span(t.seconds))
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let edge = NSMenuItem(title: "Show Clock on the Edge", action: #selector(run(_:)), keyEquivalent: "")
        edge.target = self
        edge.state = Edge.shared.shown ? .on : .off
        edge.representedObject = { Edge.shared.shown.toggle() } as AnyObject
        menu.addItem(edge)
        add("Reset Clock Position") { Edge.shared.resetPosition() }
        add("Open Sessions Folder") { NSWorkspace.shared.open(Store.folder) }
        add("Settings...", ",", [.command]) { SettingsWindow.show() }
        menu.addItem(.separator())
        add("Quit Glyph Time", "q", [.command]) { NSApp.terminate(nil) }
    }

    /// "acme-api ........ 1 h 12 min": the time on a right tab stop.
    private func row(_ name: String, _ value: String) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.tabStops = [NSTextTab(textAlignment: .right, location: 220)]
        return NSAttributedString(string: "\(name.prefix(28))\t\(value)", attributes: [
            .paragraphStyle: p, .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
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

    /// Recent names to pick from: today's projects first.
    private static func ask(_ title: String, button: String, value: String) -> String? {
        let before = NSWorkspace.shared.frontmostApplication
        defer { if let before, before.bundleIdentifier != Bundle.main.bundleIdentifier { before.activate() } }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "A project, a client, anything you want to see the hours for."
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let field = NSComboBox(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        field.addItems(withObjectValues: Clock.shared.today.map(\.project).filter { $0 != "Unnamed" })
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
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
