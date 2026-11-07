import AppKit
import SwiftUI

/// History's "Where your time went": the period's top apps, top sites, and each project's top
/// windows, from the activity lines (Track apps and tabs). Mac only; the dashboard shows it under
/// the day or the bars.
struct ActivityInsights: View {
    let range: DateInterval
    var wide = false
    @State private var spans: [ActivitySpan] = []
    @State private var loaded = false

    var body: some View {
        let apps = ActivityMath.apps(spans), sites = ActivityMath.sites(spans), groups = ActivityMath.windows(spans)
        let total = ActivityMath.total(spans)
        VStack(alignment: .leading, spacing: 18) {
            CardTitle(text: "Where your time went", detail: total > 0 ? "\(ActivityMath.span(total)) at the Mac" : nil)
            if !Activity.on && spans.isEmpty {
                Off()
            } else if spans.isEmpty {
                Text(loaded ? "Nothing recorded for these days yet. Apps, windows and sites show here as you use them." : " ")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                if wide {
                    HStack(alignment: .top, spacing: 28) {
                        Column(title: "Apps", rows: apps, total: total, icon: .app)
                        Column(title: "Sites", rows: sites, total: total, icon: .site)
                    }
                } else {
                    Column(title: "Apps", rows: apps, total: total, icon: .app)
                    Column(title: "Sites", rows: sites, total: total, icon: .site)
                }
                Divider()
                Windows(groups: groups)
            }
        }
        .historyCard()
        .historyID("history-insights")
        .task(id: "\(range.start.timeIntervalSince1970)-\(range.end.timeIntervalSince1970)-\(InsightsReload.shared.tick)") {
            let range = range, folder = Activity.folder
            spans = await Task.detached(priority: .userInitiated) { Activity.read(range, folder: folder) }.value
            loaded = true
        }
    }

    /// Tracking is off: what it would show, and the way to turn it on.
    private struct Off: View {
        var body: some View {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "macwindow.on.rectangle").font(.system(size: 26, weight: .light)).foregroundStyle(Color.historyGreen)
                VStack(alignment: .leading, spacing: 4) {
                    Text("See which apps, windows and sites your hours go to").font(.body.weight(.medium))
                    Text("Turn on Track apps and tabs in Settings. It stays on this Mac, in your folder.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Settings...") { SettingsWindow.show() }.historyID("insights-settings")
            }
        }
    }

    enum Icon { case app, site }

    /// A heading and the top eight, each with its time, share and a green bar.
    private struct Column: View {
        let title: String, rows: [ActivityMath.Row], total: TimeInterval, icon: Icon
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                if rows.isEmpty {
                    Text(icon == .site ? "No browser tabs yet. Safari and Chrome tabs show here once allowed." : "None")
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
                }
                ForEach(Array(rows.filter { $0.seconds >= 30 }.prefix(8).enumerated()), id: \.element.id) { i, r in
                    Bar(name: r.name, seconds: r.seconds, share: r.seconds / max(1, total), rank: i) {
                        if icon == .app, let b = r.bundle, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                        } else {
                            Image(systemName: icon == .app ? "app.dashed" : "globe").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 20, height: 20)
                        }
                    }
                    .historyID("insight-\(icon == .app ? "app" : "site")-\(r.name)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private struct Bar<Leading: View>: View {
        let name: String, seconds: TimeInterval, share: Double, rank: Int
        @ViewBuilder let leading: () -> Leading
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    leading()
                    Text(name).font(.body).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(ActivityMath.span(seconds)).font(.callout.weight(.medium)).monospacedDigit()
                    Text("\(Int((share * 100).rounded()))%").font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 36, alignment: .trailing)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.12))
                        Capsule().fill(Color.historyGreen.opacity(max(0.35, 1 - Double(rank) * 0.12))).frame(width: max(4, g.size.width * min(1, share)))
                    }
                }
                .frame(height: 6)
            }
            .padding(.vertical, 3)
        }
    }

    /// Each project's top windows and tabs; time outside a session last.
    private struct Windows: View {
        let groups: [ActivityMath.Group]
        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text("Windows, by project").font(.headline)
                ForEach(groups.prefix(6)) { g in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Circle().fill(g.project == ActivityMath.noSession ? Color.secondary.opacity(0.4) : Color.historyGreen).frame(width: 9, height: 9)
                            Text(g.project).font(.body.weight(.semibold)).lineLimit(1)
                                .foregroundStyle(g.project == ActivityMath.noSession ? .secondary : .primary)
                            Spacer(minLength: 8)
                            Text(ActivityMath.span(g.seconds)).font(.callout.weight(.medium)).monospacedDigit()
                        }
                        ForEach(g.titles) { t in
                            HStack(spacing: 8) {
                                Text(t.name).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(ActivityMath.span(t.seconds)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .padding(.leading, 17)
                        }
                        if g.titles.isEmpty {
                            Text("No window titles (Accessibility is off, or private windows)").font(.callout).foregroundStyle(.tertiary).padding(.leading, 17)
                        }
                    }
                    .historyID("insight-project-\(g.project)")
                }
            }
        }
    }
}

/// Bumped on every History refresh, so the insights read the files again.
@MainActor @Observable
final class InsightsReload {
    static let shared = InsightsReload()
    var tick = 0
}
