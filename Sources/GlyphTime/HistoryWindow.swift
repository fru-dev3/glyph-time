import AppKit
import CryptoKit
import GlyphVault
import SwiftUI

/// The Mac's side of History: every device's lines from the sessions folder, the project notes
/// beside it, and writes through `Store` (a line in this Mac's file, or a project note).
@MainActor
enum MacHistory {
    static let shared: History = {
        History(host: Store.host,
                write: { e in
                    if e.event == "rename", let from = e.project, let to = e.label { moveNote(from, to: to) }
                    Store.write(e)
                    changed()
                },
                startAgain: { p in Clock.shared.start(project: p); refresh() },
                saveNote: { p, n in save(p, n); refresh() },
                suggest: Store.vault == nil ? nil : { p, kind in suggest(p, kind) })
    }()

    /// `data/apps/time/projects/`, beside the sessions folder (or its stand-in outside a vault).
    static var notesFolder: URL { Store.folder.deletingLastPathComponent().appending(path: "projects") }
    static var exportsFolder: URL { Store.folder.deletingLastPathComponent().appending(path: "exports") }

    static func refresh() {
        Store.drainOutbox() // the vault may be back: anything written while it was away goes in first
        shared.load(Store.all(), notes: ProjectNote.read(notesFolder))
        shared.goalTitles = goals()
        InsightsReload.shared.tick += 1
    }

    /// A line was written: the clock's lists and History both read it back.
    private static func changed() {
        Clock.shared.reload()
        StatusMenu.shared.update()
        refresh()
    }

    /// A renamed project keeps its note: the `project:` line changes and the file takes the new
    /// name. Everything else in the file stays as it was.
    static func moveNote(_ from: String, to: String) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: notesFolder.path)) ?? []
        guard let file = names.lazy.map({ notesFolder.appending(path: $0) }).first(where: {
            (try? String(contentsOf: $0, encoding: .utf8)).flatMap(ProjectNote.parse)?.project == from
        }), let text = try? String(contentsOf: file, encoding: .utf8), let (_, note) = ProjectNote.parse(text) else { return }
        do { try ProjectNote.render(to, note, over: text).write(to: file, atomically: true, encoding: .utf8) }
        catch { log.error("project note rename failed: \(error.localizedDescription, privacy: .public)"); return }
        let wanted = notesFolder.appending(path: ProjectNote.fileName(to))
        if file != wanted, !fm.fileExists(atPath: wanted.path) { try? fm.moveItem(at: file, to: wanted) }
    }

    /// The project's note: its existing file (found by its `project:` line), else a new one.
    static func save(_ project: String, _ note: ProjectNote) {
        let fm = FileManager.default
        try? fm.createDirectory(at: notesFolder, withIntermediateDirectories: true)
        let names = (try? fm.contentsOfDirectory(atPath: notesFolder.path)) ?? []
        var file = names.lazy.map { notesFolder.appending(path: $0) }.first {
            (try? String(contentsOf: $0, encoding: .utf8)).flatMap(ProjectNote.parse)?.project == project
        }
        if file == nil {
            var name = ProjectNote.fileName(project), n = 2
            while names.contains(name) { name = ProjectNote.fileName(project).replacingOccurrences(of: ".md", with: "-\(n).md"); n += 1 }
            file = notesFolder.appending(path: name)
        }
        let old = try? String(contentsOf: file!, encoding: .utf8)
        do { try ProjectNote.render(project, note, over: old).write(to: file!, atomically: true, encoding: .utf8) }
        catch { log.error("project note failed: \(error.localizedDescription, privacy: .public)") }
    }

    /// Glyph Omega's goals by id, from each domain's `source/goals.md` (`~id:g-...`).
    static func goals() -> [String: String] {
        guard let vault = Store.vault else { return [:] }
        let domains = vault.appending(path: "data/domains")
        var out: [String: String] = [:]
        for d in (try? FileManager.default.contentsOfDirectory(atPath: domains.path)) ?? [] where !d.hasPrefix("_") && !d.hasPrefix(".") {
            guard let text = try? String(contentsOf: domains.appending(path: "\(d)/source/goals.md"), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let r = line.range(of: #"~id:(g-[a-z0-9]+)"#, options: .regularExpression) else { continue }
                let id = String(line[r].dropFirst(4))
                var title = String(line)
                if let cut = title.range(of: #"\s~[a-z]+:"#, options: .regularExpression) { title = String(title[..<cut.lowerBound]) }
                if let box = title.range(of: #"^\s*- \[.\]\s*"#, options: .regularExpression) { title.removeSubrange(box) }
                out[id] = title.trimmingCharacters(in: .whitespaces)
            }
        }
        return out
    }

    /// A suggestion line for Glyph CRM (`data/apps/crm/proposals/<YYYY-MM>.jsonl`, its own format):
    /// this project as a new entity of `kind`, tagging the project's note on accept. Nothing is
    /// written to an entity page; the user accepts it in Glyph CRM.
    static func suggest(_ project: String, _ kind: String) {
        guard let vault = Store.vault else { return }
        if shared.notes[project] == nil { save(project, ProjectNote()); refresh() }
        let file = (try? FileManager.default.contentsOfDirectory(atPath: notesFolder.path))?.first {
            (try? String(contentsOf: notesFolder.appending(path: $0), encoding: .utf8)).flatMap(ProjectNote.parse)?.project == project
        } ?? ProjectNote.fileName(project)
        let st = HistoryMath.stats(shared.sessions(of: project))
        let id = SHA256.hash(data: Data("time|\(kind)|\(project)".utf8)).map { String(format: "%02x", $0) }.joined().prefix(32)
        let iso = ISO8601DateFormatter()
        let line: [String: String] = [
            "at": iso.string(from: .now), "evidence": "Glyph Time project: \(TimeLog.span(st.total)) over \(st.sessions) sessions",
            "id": String(id), "kind": kind, "name": project, "path": "data/apps/time/projects/\(file)",
            "source": "time", "status": "pending",
        ]
        let folder = vault.appending(path: "data/apps/crm/proposals")
        let target = folder.appending(path: "\(TimeLog.month(.now)).jsonl")
        // The same suggestion is never added twice (its id is a hash of what it says).
        if let old = try? String(contentsOf: target, encoding: .utf8), old.contains("\"id\":\"\(id)\"") { return }
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: target.path) { FileManager.default.createFile(atPath: target.path, contents: nil) }
            let h = try FileHandle(forWritingTo: target)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: data)
        } catch {
            log.error("suggestion failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes the period as CSV or Markdown into `data/apps/time/exports/`; returns the file.
    @discardableResult
    static func export(markdown: Bool) -> URL? {
        let h = shared, r = h.range
        let text = markdown ? HistoryMath.markdown(h.inRange, title: h.title, subtitle: h.subtitle, notes: h.notes, now: h.now)
                            : HistoryMath.csv(h.inRange, notes: h.notes, now: h.now)
        let file = exportsFolder.appending(path: HistoryMath.exportName(r) + (markdown ? ".md" : ".csv"))
        do {
            try FileManager.default.createDirectory(at: exportsFolder, withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            log.error("export failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

@MainActor
enum HistoryWindow {
    private(set) static var window: NSWindow?
    private static var timer: Timer?

    static func show(project: String? = nil) {
        MacHistory.refresh()
        if window == nil {
            let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            // The UI check runs from a remote shell, where the app can't become active: there the
            // same window is a non-activating panel, so it takes clicks and keys like the edge clock.
            let w = UITest.on ? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780), styleMask: style.union(.nonactivatingPanel), backing: .buffered, defer: false)
                              : NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780), styleMask: style, backing: .buffered, defer: false)
            (w as? NSPanel)?.becomesKeyOnlyIfNeeded = false
            (w as? NSPanel)?.hidesOnDeactivate = false
            w.title = "Glyph Time History"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .visible // so the window says which app it is
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 760, height: 560)
            w.contentView = NSHostingView(rootView: HistoryMac(history: MacHistory.shared))
            w.setFrameAutosaveName(UITest.on ? "" : "GlyphTimeHistory")
            if !w.setFrameUsingName("GlyphTimeHistory") || UITest.on { w.center() }
            window = w
        }
        if let project { HistoryMac.select?(project) }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // Another device's sessions arrive by sync: read again every half minute while it shows.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard HistoryWindow.window?.isVisible == true else { HistoryWindow.timer?.invalidate(); return }
                MacHistory.refresh()
            }
        }
    }
}

/// The window: a sidebar (Overview, projects by initiative, hidden ones) and the page.
struct HistoryMac: View {
    @Bindable var history: History
    enum Item: Hashable { case overview, project(String) }
    @State private var item: Item? = .overview
    @State private var showHidden = false
    @State private var exported: URL?
    /// Lets the menu and the UI check open a project.
    nonisolated(unsafe) static var select: ((String) -> Void)?

    var body: some View {
        // One view, not a split view controller: one hosting view, so the UI check's frames are the window's.
        HStack(spacing: 0) {
            List(selection: $item) {
                Label("Overview", systemImage: "chart.bar.xaxis").tag(Item.overview).historyID("sidebar-overview")
                let visible = history.projects.filter { !$0.hidden }
                let groups = Dictionary(grouping: visible) { history.notes[$0.name]?.initiative ?? "" }
                ForEach(groups.keys.sorted { $0.isEmpty ? false : $1.isEmpty ? true : $0 < $1 }, id: \.self) { key in
                    Section(key.isEmpty ? (groups.count == 1 ? "Projects" : "Other projects") : key) {
                        ForEach(groups[key]!, id: \.name) { p in row(p) }
                    }
                }
                let hidden = history.projects.filter(\.hidden)
                if !hidden.isEmpty {
                    Section(isExpanded: $showHidden) {
                        ForEach(hidden, id: \.name) { p in row(p).foregroundStyle(.secondary) }
                    } header: {
                        Text("Hidden (\(hidden.count))")
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .padding(.top, 28) // under the window's buttons
            .historyID("sidebar")
            .safeAreaInset(edge: .bottom, spacing: 0) { vaultFoot }
            .frame(width: 240)
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
            Divider()
            GeometryReader { g in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        toolbar
                        switch item {
                        case .project(let p): ProjectDetail(history: history, project: p, renamed: { item = .project($0) }).id(p)
                        default: HistoryDashboard(history: history, open: { item = .project($0) }, wide: g.size.width > 860,
                                                  insights: AnyView(ActivityInsights(range: history.range, wide: g.size.width > 860)))
                        }
                    }
                    .padding(.horizontal, 28).padding(.top, 34).padding(.bottom, 28)
                    .frame(maxWidth: 1180)
                    .frame(maxWidth: .infinity)
                    .background(Color.historyPage)
                }
                .background(Color.historyPage)
            }
        }
        .tint(.historyGreen)
        .onAppear { HistoryMac.select = { item = .project($0) } }
    }

    private func row(_ p: TimeProject) -> some View {
        HStack {
            Text(p.name).lineLimit(1)
            Spacer(minLength: 6)
            Text(TimeLog.span(p.total)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
        .tag(Item.project(p.name))
        .contextMenu {
            Button("Start Again") { history.startAgain(p.name) }
            Button(p.hidden ? "Show in Recent" : "Hide from Recent") { p.hidden ? history.show(p.name) : history.hide(p.name) }
        }
        .historyID("sidebar-\(p.name)")
    }

    /// Where the lines are going, under the projects: the same line the card and the phone show, so
    /// the answer to "is this being written down" is in sight wherever you are looking.
    private var vaultFoot: some View {
        HStack(spacing: 7) {
            Circle().fill(Store.connected ? Color.office : Color.secondary)
                .frame(width: 7, height: 7)
            Text(Store.connected ? "Vault connected" : "Vault out of reach")
            Text("·").foregroundStyle(.tertiary)
            Text("\(Store.waiting) waiting").monospacedDigit()
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .historyID("sidebar-vault")
    }

    /// Back to the overview, compare, export and refresh: one row above the page.
    private var toolbar: some View {
        HStack(spacing: 10) {
            if case .project = item {
                Button { item = .overview } label: { Label("Overview", systemImage: "chevron.left") }
                    .buttonStyle(.borderless).historyID("history-overview")
            }
            Spacer()
            if exported != nil {
                Button { if let exported { NSWorkspace.shared.activateFileViewerSelecting([exported]) } } label: {
                    Label("Saved \(exported!.lastPathComponent)", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .historyID("history-exported")
            }
            if item == .overview {
                Toggle(isOn: $history.compare) { Label("Compare", systemImage: "arrow.left.arrow.right") }
                    .toggleStyle(.button).historyID("history-compare-toggle")
                Menu {
                    Button("Export as CSV") { exported = MacHistory.export(markdown: false) }
                    Button("Export as Markdown") { exported = MacHistory.export(markdown: true) }
                    Divider()
                    Button("Open Exports Folder") {
                        try? FileManager.default.createDirectory(at: MacHistory.exportsFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(MacHistory.exportsFolder)
                    }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .fixedSize().historyID("history-export")
            }
            Button { MacHistory.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Read the sessions again").accessibilityLabel("Refresh").historyID("history-refresh")
        }
        .controlSize(.large)
    }
}
