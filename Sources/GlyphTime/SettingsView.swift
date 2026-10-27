import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(Clock.nudgeKey) private var nudge = 30
    @AppStorage(Clock.idleKey) private var idle = 5
    @AppStorage("folder") private var folder = ""
    @State private var trusted = AXIsProcessTrusted()
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var loginProblem: String?

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
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section {
                Picker("Nudge every", selection: $nudge) {
                    Text("Never").tag(0)
                    ForEach([15, 30, 45, 60, 90], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Picker("Pause when away for", selection: $idle) {
                    Text("Never").tag(0)
                    ForEach([2, 5, 10, 15], id: \.self) { Text("\($0) minutes").tag($0) }
                }
            } footer: {
                Text("Back within 30 minutes and the clock carries on. Longer, and the session ends when you left.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Sessions") {
                    Text(Store.folder.path(percentEncoded: false))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Choose Folder...") { choose() }
                    if !folder.isEmpty { Button("Use the Default") { folder = "" } }
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.open(Store.folder) }
                }
            } footer: {
                Text("Plain files, one line per start, pause and stop. In a Glyph Studio vault they go to data/apps/time.")
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
                Toggle("Open at login", isOn: $login)
                    .tint(.office)
                    .onChange(of: login) { _, on in setLogin(on) }
                if let loginProblem { Text(loginProblem).foregroundStyle(.secondary).font(.callout) }
                LabeledContent("Start or pause") { Text("Control Option T").foregroundStyle(.secondary) }
            } footer: {
                Text("Without access, a session is named after the app in front. Only the folder name is kept, never a window title.")
                    .foregroundStyle(.secondary)
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
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = AXIsProcessTrusted()
        }
    }

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
