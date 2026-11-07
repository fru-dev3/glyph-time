import AppKit
import GlyphVault
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(Clock.nudgeKey) private var nudge = 30
    @AppStorage(Clock.idleKey) private var idle = 5
    @AppStorage(Clock.chimeKey) private var chimes = true
    @AppStorage("folder") private var folder = ""
    @AppStorage(Clock.autoHideKey) private var autoHide = false
    @State private var trusted = AXIsProcessTrusted()
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var dock = Presence.inDock
    @State private var bar = Presence.inMenuBar
    @State private var loginProblem: String?
    @State private var track = Activity.on
    @State private var autoStart = Clock.shared.autoStart
    @State private var exclude = Activity.excludeText
    @State private var captureEvery = Captures.every
    @State private var clip = Captures.clip
    @State private var budget = Captures.budgetMB
    @State private var capturesToday = Captures.today()
    @State private var archived: String?
    /// Routines are kept on the phone; here they are read only, with today's count.
    @State private var routines = TimeLog.routines(Store.recent()).filter { $0.on && !$0.archived }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Glyph Time").font(.system(size: 20, weight: .semibold))
                        Text("See where your hours go.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section {
                Picker("Nudge every", selection: $nudge) {
                    Text("Never").tag(0)
                    ForEach([15, 30, 45, 60, 90], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Toggle("Sound every 15 minutes", isOn: $chimes)
                    .tint(.office)
                Picker("Pause when away for", selection: $idle) {
                    Text("Never").tag(0)
                    ForEach([2, 5, 10, 15], id: \.self) { Text("\($0) minutes").tag($0) }
                }
            } footer: {
                Text("Back within 30 minutes and the clock carries on. Longer, and the session ends when you left.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Hide projects untouched for 30 days", isOn: $autoHide)
                    .tint(.office)
                    .onChange(of: autoHide) { _, _ in Clock.shared.refreshToday() }
                if !Clock.shared.hidden.isEmpty {
                    LabeledContent("Hidden") {
                        VStack(alignment: .trailing, spacing: 6) {
                            ForEach(Clock.shared.hidden, id: \.name) { p in
                                HStack(spacing: 8) {
                                    Text(p.name).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                                    Button("Show") { Clock.shared.unhide(p.name) }.controlSize(.small)
                                }
                            }
                        }
                    }
                }
            } footer: {
                Text("For the Recent list. Right-click a project on the clock, or hold Option in the menu, to hide it. Hidden projects keep their sessions and come back when you start them again.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Vault") {
                    Text(Store.vault?.path(percentEncoded: false) ?? "None: not a Glyph Studio vault")
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("Sessions") {
                    Text(Store.folder.path(percentEncoded: false))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("Project notes") {
                    Text(MacHistory.notesFolder.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).textSelection(.enabled)
                }
                LabeledContent("Exports") {
                    Text(MacHistory.exportsFolder.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    Button("Choose Folder...") { choose() }
                    if !folder.isEmpty { Button("Use the Default") { folder = "" } }
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.open(Store.folder) }
                }
            } footer: {
                Text("Plain files, one line per start, pause and stop; History's project notes and exports sit beside them. The vault is the one in Glyph Studio's config unless you choose a folder.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Project names") {
                    if trusted {
                        Label("From your terminal and editor", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.office)
                    } else {
                        Button("Allow...") {
                            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                        }
                    }
                }
                Toggle("Show in Dock", isOn: $dock)
                    .tint(.office)
                    .disabled(!bar)
                    .onChange(of: dock) { _, on in Presence.inDock = on }
                Toggle("Show in menu bar", isOn: $bar)
                    .tint(.office)
                    .disabled(!dock)
                    .onChange(of: bar) { _, on in Presence.inMenuBar = on }
                if !dock || !bar {
                    Text("Glyph Time needs the Dock or the menu bar to stay reachable.")
                        .foregroundStyle(.secondary).font(.callout)
                }
                Toggle("Open at login", isOn: $login)
                    .tint(.office)
                    .onChange(of: login) { _, on in setLogin(on) }
                if let loginProblem { Text(loginProblem).foregroundStyle(.secondary).font(.callout) }
                LabeledContent("Start or pause") { Text("Control Option T").foregroundStyle(.secondary) }
                LabeledContent("Minimize or keep open") { Text("Control Option M").foregroundStyle(.secondary) }
            } footer: {
                Text("Without access, a session is named after the app in front. Only the folder name goes on a session; window titles are kept only with Track apps and tabs.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Start timing when I start working", isOn: Binding(get: { autoStart }, set: { on in
                    UserDefaults.standard.set(on, forKey: Clock.autoStartKey); autoStart = on
                }))
                .tint(.office).historyID("settings-auto-start")
                Text("A minute at the keyboard with nothing running starts a session on what is in front, named by the guess. Stopping by hand keeps it stopped for a quarter of an hour.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Track apps and tabs", isOn: Binding(get: { track }, set: { on in
                    if !on { Activity.flush() }
                    Activity.defaults.set(on, forKey: Activity.trackKey); track = on
                }))
                .tint(.office).historyID("settings-track")
                if track {
                    LabeledContent("Window titles") {
                        if trusted {
                            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(Color.office)
                        } else {
                            Button("Allow...") { _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
                        }
                    }
                    LabeledContent("Browser tabs") {
                        Text("Safari and Chrome ask once").foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Never record")
                    TextField("Never record", text: Binding(get: { exclude }, set: { exclude = $0; Activity.defaults.set($0, forKey: Activity.excludeKey) }), axis: .vertical)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .historyID("settings-exclude")
                    Text("Apps or sites, one per line: a name (1Password), a bundle id, or a site (bank.example and its subdomains). Nothing is kept while one is in front, and no capture is taken.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Activity")
            } footer: {
                Text("While you are at the Mac, session or not: the app in front, its window's title, and a browser's tab and site, as plain lines in activity/ beside the sessions. Private and incognito windows keep only the app. Nothing leaves this Mac but your own folder's sync.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Take a screenshot every", selection: Binding(get: { captureEvery }, set: { m in
                    captureEvery = m; Activity.defaults.set(m, forKey: Captures.everyKey)
                    if m > 0 { Captures.ask() }
                })) {
                    Text("Never").tag(0)
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                .historyID("settings-capture-every")
                if captureEvery > 0 {
                    Toggle("Short clip instead (12 seconds)", isOn: Binding(get: { clip }, set: { clip = $0; Activity.defaults.set($0, forKey: Captures.clipKey) }))
                        .tint(.office).historyID("settings-capture-clip")
                    Picker("Daily limit", selection: Binding(get: { budget }, set: { budget = $0; Activity.defaults.set($0, forKey: Captures.budgetKey) })) {
                        ForEach([100, 200, 500, 1000], id: \.self) { Text($0 >= 1000 ? "1 GB" : "\($0) MB").tag($0) }
                    }
                    .historyID("settings-capture-budget")
                    if !Captures.allowed {
                        LabeledContent("Screen Recording") {
                            Button("Allow...") { Captures.ask() }
                        }
                    }
                }
                LabeledContent("Today") { Text(capturesToday).foregroundStyle(.secondary).historyID("settings-capture-today") }
                HStack {
                    Button("Move Captures Older Than 30 Days to Archive") {
                        let n = Captures.archiveOld()
                        archived = n == 0 ? "Nothing older than 30 days" : "Moved \(n) \(n == 1 ? "day" : "days") to archived-\(ActivityLog.day(.now))"
                    }
                    .historyID("settings-capture-archive")
                    Spacer()
                    Button("Show") {
                        try? FileManager.default.createDirectory(at: Captures.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Captures.folder)
                    }
                }
                if let archived { Text(archived).font(.callout).foregroundStyle(.secondary) }
            } header: {
                Text("Screen captures")
            } footer: {
                Text("Off until you choose. A small picture (1280 wide) or a 2-frames-a-second clip, only while you are at the Mac and never with a private window or a never-record app in front. Over the daily limit it skips; nothing is ever deleted. Kept in captures/ beside the sessions.")
                    .foregroundStyle(.secondary)
            }
            if !routines.isEmpty {
                Section("Routines") {
                    ForEach(routines) { r in
                        LabeledContent {
                            let t = r.target(on: .now)
                            Text(t == 0 ? "Not today" : "\(min(r.done(on: .now), t)) of \(t) today").monospacedDigit()
                        } label: {
                            Text(r.title)
                            Text(r.cadence())
                        }
                    }
                }
            }
            Section {
                HStack {
                    Text("(c) fru.dev")
                    Spacer()
                    Link("glyph.fru.dev/time", destination: URL(string: "https://glyph.fru.dev/time")!)
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: SettingsView.height)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = AXIsProcessTrusted()
            capturesToday = Captures.today()
        }
    }

    /// Tall enough for most of it, never taller than the screen; the rest scrolls.
    static var height: CGFloat { min(900, (NSScreen.main?.visibleFrame.height ?? 900) - 80) }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Where Glyph Time keeps your sessions. A Glyph Studio vault, a notes folder, anywhere."
        if panel.runModal() == .OK, let url = panel.url {
            folder = url.path(percentEncoded: false)
            Clock.shared.load()
        }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginProblem = nil
        } catch {
            loginProblem = "macOS said no: \(error.localizedDescription)"
            login = SMAppService.mainApp.status == .enabled
        }
    }
}
