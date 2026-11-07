import Charts
import GlyphCapture
import GlyphVault
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// History's screens, shared by the Mac window and the iPhone tab. Office green for what matters,
// greys for the rest, SF Symbols, big headers, no emojis.

extension Color {
    /// #008000 office green; a brighter cut in dark mode so it reads on black.
    static let historyGreen: Color = {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.2, green: 0.72, blue: 0.2, alpha: 1) : NSColor(red: 0, green: 128 / 255, blue: 0, alpha: 1)
        })
        #else
        return Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.16, green: 0.66, blue: 0.16, alpha: 1) : UIColor(red: 0, green: 128 / 255, blue: 0, alpha: 1) })
        #endif
    }()

    static var historyCard: Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.17, alpha: 1) : .white })
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }

    static var historyPage: Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.1, alpha: 1) : NSColor(white: 0.955, alpha: 1) })
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }
}

/// Where controls sit on screen, for the Mac's UI check (it clicks them for real). Nil elsewhere.
enum HistoryTest {
    @MainActor static var frame: ((String, CGRect) -> Void)?
}

extension View {
    /// An identifier for UI tests, and on the Mac its frame for the UI check's clicks.
    @ViewBuilder func historyID(_ id: String) -> some View {
        if let report = HistoryTest.frame {
            accessibilityIdentifier(id).onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { report(id, $0) }
        } else {
            accessibilityIdentifier(id)
        }
    }

    func historyCard(padding: CGFloat = 18) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.historyCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// The top projects get greens from full to pale; everything after them is grey.
func historyShades(_ names: [String]) -> [Color] {
    names.enumerated().map { i, n in
        n == "Other" || n == HistoryMath.unnamed ? Color.secondary.opacity(0.35) : Color.historyGreen.opacity(max(0.22, 1 - Double(i) * 0.2))
    }
}

/// iPhone, laptop or desktop, from a session's device name (or its host).
func historyDeviceSymbol(_ s: TimeSession) -> String {
    let d = (s.device ?? s.host).lowercased()
    if d.contains("iphone") { return "iphone" }
    if d.contains("ipad") { return "ipad" }
    if d.contains("mini") || d.contains("studio") || d.contains("imac") { return "desktopcomputer" }
    return "laptopcomputer"
}

/// A card's heading: big enough to read across the room.
struct CardTitle: View {
    let text: String
    var detail: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.title3.weight(.semibold))
            Spacer(minLength: 8)
            if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary).monospacedDigit() }
        }
    }
}

// MARK: - The dashboard

/// Everything for one period: the numbers, where the time went, by project or initiative, the
/// trend, a comparison, and the sessions themselves.
struct HistoryDashboard: View {
    @Bindable var history: History
    /// Opens a project's page (the Mac's sidebar, the iPhone's navigation).
    let open: (String) -> Void
    var wide = false
    /// The Mac's "Where your time went" (apps, sites, windows), under the day or the bars.
    var insights: AnyView?
    @State private var editing: TimeSession?
    @State private var undo: TimeSession?

    var body: some View {
        let list = history.inRange
        VStack(alignment: .leading, spacing: 16) {
            PeriodHeader(history: history)
            Tiles(history: history, list: list, wide: wide)
            if list.isEmpty {
                EmptyCard(title: history.atNow ? "Nothing timed yet" : "Nothing timed then")
                insights
            } else {
                WhereItWent(history: history, list: list).historyCard()
                insights
                if wide {
                    HStack(alignment: .top, spacing: 16) {
                        Breakdown(history: history, list: list, open: open).historyCard()
                        VStack(spacing: 16) {
                            if history.compare { Compare(history: history).historyCard() }
                            Trend(history: history).historyCard()
                        }
                    }
                } else {
                    Breakdown(history: history, list: list, open: open).historyCard()
                    if history.compare { Compare(history: history).historyCard() }
                    Trend(history: history).historyCard()
                }
                SessionsCard(history: history, list: list, edit: { editing = $0 }, remove: remove, open: open).historyCard()
            }
        }
        .sheet(item: $editing) { s in
            SessionEditor(session: s, history: history, remove: { remove(s) })
        }
        .overlay(alignment: .bottom) { UndoBar(undo: $undo, history: history) }
        .animation(.snappy, value: undo?.id)
    }

    private func remove(_ s: TimeSession) {
        history.delete(s)
        undo = s
    }
}

/// "This week", its dates, the period picker, and back / forward.
struct PeriodHeader: View {
    @Bindable var history: History
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(history.title).font(.system(size: 30, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
                        .historyID("history-title")
                    Text(history.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                    Button { history.step(-1) } label: { Image(systemName: "chevron.left").frame(width: 34, height: 34) }
                        .accessibilityLabel("Earlier").historyID("history-back")
                    if !history.atNow, history.period != .custom {
                        Button { history.jumpToNow() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 34, height: 34) }
                            .accessibilityLabel("Back to now").help("Back to now").historyID("history-now")
                    }
                    Button { history.step(1) } label: { Image(systemName: "chevron.right").frame(width: 34, height: 34) }
                        .disabled(history.atNow)
                        .accessibilityLabel("Later").historyID("history-forward")
                }
                .font(.body.weight(.semibold))
                .buttonStyle(.borderless)
                .tint(.historyGreen)
            }
            Picker("Period", selection: $history.period) {
                ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .historyID("history-period")
            if history.period == .custom {
                HStack(spacing: 12) {
                    DatePicker("From", selection: $history.from, in: ...Date.now, displayedComponents: .date).historyID("history-from")
                    DatePicker("To", selection: $history.to, in: ...Date.now, displayedComponents: .date).historyID("history-to")
                }
                .datePickerStyle(.compact)
            }
        }
    }
}

/// Total (and how it moved), sessions, the average session, the top project.
private struct Tiles: View {
    let history: History, list: [TimeSession], wide: Bool
    var body: some View {
        let total = HistoryMath.total(list, now: history.now)
        let before = HistoryMath.total(history.inPrevious, now: history.now)
        let top = HistoryMath.byProject(list, now: history.now).first
        let devices = Set(list.map { $0.device ?? $0.host }).count
        TileGrid(columns: wide ? 4 : 2, tiles: [
            AnyView(Tile(label: "Total", value: TimeLog.span(total), note: previousNote(total, before), accent: true).historyID("history-total")),
            AnyView(Tile(label: "Sessions", value: "\(list.count)", note: list.isEmpty ? nil : "\(devices) \(devices == 1 ? "device" : "devices")")),
            AnyView(Tile(label: "Average", value: list.isEmpty ? "None" : TimeLog.span(total / Double(list.count)), note: "a session")),
            AnyView(Tile(label: "Top project", value: top?.name ?? "None", note: top.map { TimeLog.span($0.seconds) })),
        ])
    }

    private func previousNote(_ now: TimeInterval, _ before: TimeInterval) -> String {
        let word = ["Today": "yesterday", "Week": "last week", "Month": "last month", "Custom": "the days before"][history.period.rawValue]!
        return before < 60 && now < 60 ? "nothing \(word) either" : "\(HistoryMath.delta(now, before)) on \(word)"
    }
}

/// Four tiles in rows of `columns`, all drawn (a lazy grid can leave a row out).
struct TileGrid: View {
    let columns: Int
    let tiles: [AnyView]
    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(Array(stride(from: 0, to: tiles.count, by: columns)), id: \.self) { i in
                GridRow { ForEach(i..<min(i + columns, tiles.count), id: \.self) { tiles[$0] } }
            }
        }
    }
}

struct Tile: View {
    let label: String, value: String
    var note: String?
    var accent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                .foregroundStyle(accent ? Color.historyGreen : .primary)
                .lineLimit(1).minimumScaleFactor(0.55)
            Text(note ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.historyCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct EmptyCard: View {
    let title: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 34, weight: .light)).foregroundStyle(Color.historyGreen)
            Text(title).font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity) // centered in the card (it sat on the left)
        .padding(.vertical, 40)
        .historyCard()
        .historyID("history-empty")
    }
}

/// A day: each session on a time line. Longer: a bar per day (or week), split by project.
private struct WhereItWent: View {
    let history: History, list: [TimeSession]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(text: history.period == .today ? "Your day" : "Where it went",
                      detail: history.period == .today ? "\(list.count) \(list.count == 1 ? "session" : "sessions")" : nil)
            if history.period == .today { DayTimeline(list: list, now: history.now) } else { RangeBars(history: history, list: list) }
        }
        .historyID("history-chart")
    }
}

/// Sessions as bars on the hours they ran, one row per project.
struct DayTimeline: View {
    let list: [TimeSession], now: Date
    var body: some View {
        let names = HistoryMath.byProject(list, now: now).map(\.name)
        let shades = historyShades(names)
        let from = Calendar.current.date(bySetting: .minute, value: 0, of: list.map(\.start).min()!)!.addingTimeInterval(-1800)
        let to = max(list.map { $0.end ?? now }.max()!.addingTimeInterval(1800), from.addingTimeInterval(4 * 3600))
        Chart(list) { s in
            BarMark(xStart: .value("Start", s.start), xEnd: .value("End", max(s.end ?? now, s.start.addingTimeInterval(120))),
                    y: .value("Project", HistoryMath.name(s)), height: .fixed(20))
                .foregroundStyle(by: .value("Project", HistoryMath.name(s)))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .chartForegroundStyleScale(domain: names, range: shades)
        .chartLegend(.hidden)
        .chartXScale(domain: from...to)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: to.timeIntervalSince(from) > 10 * 3600 ? 3 : 2)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis { AxisMarks { _ in AxisValueLabel().font(.callout) } }
        .frame(height: CGFloat(max(2, names.count)) * 36 + 34)
    }
}

/// Bars per day or week across the range, the top five projects in greens and the rest grey.
private struct RangeBars: View {
    let history: History, list: [TimeSession]
    var body: some View {
        let top = HistoryMath.byProject(list, now: history.now).prefix(5).map(\.name)
        let (raw, unit) = HistoryMath.bars(list, history.range, now: history.now)
        let bars = raw.map { b -> HistoryMath.Bar in var b = b; if !top.contains(b.project) { b.project = "Other" }; return b }
        let names = top + (bars.contains { $0.project == "Other" } ? ["Other"] : [])
        VStack(alignment: .leading, spacing: 12) {
            Chart(bars) { b in
                BarMark(x: .value("Day", b.day, unit: unit), y: .value("Hours", b.seconds / 3600))
                    .foregroundStyle(by: .value("Project", b.project))
            }
            .chartForegroundStyleScale(domain: names, range: historyShades(names))
            .chartLegend(.hidden)
            .chartXScale(domain: history.range.start...history.range.end)
            .chartXAxis {
                if history.period == .week {
                    AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true) }
                } else {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine()
                    AxisValueLabel { if let h = v.as(Double.self) { Text(h == h.rounded() ? "\(Int(h)) h" : String(format: "%.1f h", h)) } }
                }
            }
            .frame(height: 190)
            Legend(names: names)
        }
    }
}

/// The colours, named: a wrapping row of dots and names.
struct Legend: View {
    let names: [String]
    var body: some View {
        let shades = historyShades(names)
        FlowRow(spacing: 14) {
            ForEach(Array(names.enumerated()), id: \.offset) { i, n in
                HStack(spacing: 6) {
                    Circle().fill(shades[i]).frame(width: 9, height: 9)
                    Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// Lays children left to right, wrapping to the next line.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += line + 6; line = 0 }
            x += s.width + spacing; line = max(line, s.height)
        }
        return CGSize(width: width, height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += line + 6; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; line = max(line, s.height)
        }
    }
}

/// By project, by initiative or by Omega goal: a bar for each, its time and share.
private struct Breakdown: View {
    let history: History, list: [TimeSession]
    let open: (String) -> Void
    enum By: String, CaseIterable, Identifiable { case projects = "Projects", initiatives = "Initiatives", goals = "Goals"; var id: String { rawValue } }
    @State private var by = By.projects

    var body: some View {
        let slices: [Slice] = switch by {
        case .projects: HistoryMath.byProject(list, now: history.now)
        case .initiatives: HistoryMath.byInitiative(list, notes: history.notes, now: history.now)
        case .goals: HistoryMath.byGoal(list, notes: history.notes, titles: history.goalTitles, now: history.now)
        }
        let total = max(1, HistoryMath.total(list, now: history.now))
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(text: ["Projects": "By project", "Initiatives": "By initiative", "Goals": "By goal"][by.rawValue]!)
            // Initiatives and goals live in the project notes, which only the Mac reads.
            if history.saveNote != nil || !history.notes.isEmpty {
                Picker("By", selection: $by) { ForEach(By.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().historyID("history-by")
            }
            VStack(spacing: 4) {
                ForEach(Array(slices.prefix(12).enumerated()), id: \.element.id) { i, s in
                    let tap = by == .projects && s.name != HistoryMath.unnamed
                    Button { if tap { open(s.name) } } label: {
                        SliceRow(slice: s, share: s.seconds / total, rank: i, grey: s.name == HistoryMath.unnamed || s.name == HistoryMath.noInitiative || s.name == HistoryMath.noGoal, chevron: tap)
                    }
                    .buttonStyle(.plain)
                    .disabled(!tap && by == .projects)
                    .historyID("slice-\(s.name)")
                }
            }
            if by != .projects, slices.allSatisfy({ $0.name == HistoryMath.noInitiative || $0.name == HistoryMath.noGoal }) {
                Text(by == .initiatives ? "Give a project an initiative on its page, and its hours gather under it here."
                                        : "Link a project to a Glyph Omega goal on its page to see the hours each goal gets.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SliceRow: View {
    let slice: Slice, share: Double, rank: Int, grey: Bool, chevron: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(slice.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(grey ? .secondary : .primary)
                Spacer(minLength: 8)
                Text(TimeLog.span(slice.seconds)).font(.callout.weight(.medium)).monospacedDigit()
                Text("\(Int((share * 100).rounded()))%").font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 36, alignment: .trailing)
                if chevron { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                    Capsule().fill(grey ? Color.secondary.opacity(0.4) : Color.historyGreen.opacity(max(0.35, 1 - Double(rank) * 0.12)))
                        .frame(width: max(4, g.size.width * min(1, share)))
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// This period against the one before, project by project.
private struct Compare: View {
    let history: History
    var body: some View {
        let now = HistoryMath.byProject(history.inRange, now: history.now)
        let before = Dictionary(uniqueKeysWithValues: HistoryMath.byProject(history.inPrevious, now: history.now).map { ($0.name, $0.seconds) })
        let names = Array((now.map(\.name) + before.keys.sorted()).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(8))
        let mine = Dictionary(uniqueKeysWithValues: now.map { ($0.name, $0.seconds) })
        let word = ["Today": "Yesterday", "Week": "Last week", "Month": "Last month", "Custom": "Before"][history.period.rawValue]!
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(text: "Compared with \(word.lowercased())",
                      detail: HistoryMath.delta(HistoryMath.total(history.inRange, now: history.now), HistoryMath.total(history.inPrevious, now: history.now)))
            Chart {
                ForEach(names, id: \.self) { n in
                    BarMark(x: .value("Hours", (mine[n] ?? 0) / 3600), y: .value("Project", n), height: .fixed(9))
                        .foregroundStyle(Color.historyGreen).position(by: .value("When", "Now"))
                    BarMark(x: .value("Hours", (before[n] ?? 0) / 3600), y: .value("Project", n), height: .fixed(9))
                        .foregroundStyle(Color.secondary.opacity(0.4)).position(by: .value("When", word))
                }
            }
            .chartXAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let h = v.as(Double.self) { Text("\(Int(h)) h") } } } }
            .frame(height: CGFloat(max(2, names.count)) * 30 + 30)
            HStack(spacing: 14) {
                Label { Text(history.title) } icon: { Circle().fill(Color.historyGreen).frame(width: 9, height: 9) }
                Label { Text(word) } icon: { Circle().fill(Color.secondary.opacity(0.4)).frame(width: 9, height: 9) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .historyID("history-compare")
    }
}

/// The last twelve weeks, this one in full green.
struct Trend: View {
    let history: History
    var project: String?
    var body: some View {
        let list = project.map { history.sessions(of: $0) } ?? history.sessions
        let weeks = HistoryMath.weeks(list, now: history.now)
        let avg = weeks.dropLast().reduce(0) { $0 + $1.seconds } / Double(max(1, weeks.count - 1))
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(text: "Twelve weeks", detail: "about \(TimeLog.span(avg)) a week")
            Chart(weeks) { w in
                BarMark(x: .value("Week", w.start, unit: .weekOfYear), y: .value("Hours", w.seconds / 3600))
                    .foregroundStyle(w.id == weeks.last?.id ? Color.historyGreen : Color.historyGreen.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear, count: 3)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) }
            }
            .chartYAxis { AxisMarks(position: .leading) { v in AxisGridLine(); AxisValueLabel { if let h = v.as(Double.self) { Text("\(Int(h)) h") } } } }
            .frame(height: 140)
        }
        .historyID("history-trend")
    }
}

// MARK: - Sessions

/// The period's sessions, newest day first. Click or tap one to fix it.
private struct SessionsCard: View {
    let history: History, list: [TimeSession]
    let edit: (TimeSession) -> Void, remove: (TimeSession) -> Void, open: (String) -> Void
    var body: some View {
        let days = Dictionary(grouping: list) { Calendar.current.startOfDay(for: $0.start) }.sorted { $0.key > $1.key }
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(text: "Sessions", detail: "\(list.count)")
            ForEach(days, id: \.key) { day, rows in
                if days.count > 1 {
                    HStack {
                        Text(day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(TimeLog.span(HistoryMath.total(rows, now: history.now))).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.top, 8)
                }
                ForEach(rows.sorted { $0.start > $1.start }) { s in
                    SessionRow(session: s, now: history.now, edit: edit, remove: remove, startAgain: history.startAgain, open: open)
                    if s.id != rows.min(by: { $0.start < $1.start })?.id { Divider() }
                }
            }
        }
    }
}

/// One session: device, project, start to end, how long. A click edits it; the menu (right-click
/// on the Mac, a long press on the iPhone) starts it again, opens its project or deletes it.
struct SessionRow: View {
    let session: TimeSession, now: Date
    let edit: (TimeSession) -> Void, remove: (TimeSession) -> Void, startAgain: (String) -> Void, open: (String) -> Void

    /// "10:21 AM to 11:30 AM": one line; the symbol says which device.
    private var times: String {
        let f = Date.FormatStyle(date: .omitted, time: .shortened)
        return "\(session.start.formatted(f)) to \(session.end?.formatted(f) ?? "now")" // the device is the symbol (it was cut off)
    }

    var body: some View {
        let name = HistoryMath.name(session)
        Button { edit(session) } label: {
            HStack(spacing: 12) {
                Image(systemName: historyDeviceSymbol(session)).font(.body).foregroundStyle(Color.historyGreen).frame(width: 24)
                    .accessibilityLabel(session.device ?? session.host)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.body.weight(.medium)).lineLimit(1).foregroundStyle(session.project == nil ? .secondary : .primary)
                    Text(times).lineLimit(1).truncationMode(.tail)
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 8)
                Text(TimeLog.span(session.active(at: now))).font(.callout.weight(.medium)).monospacedDigit()
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit Session", systemImage: "pencil") { edit(session) }
            if session.project != nil {
                Button("Start Again", systemImage: "play.fill") { startAgain(name) }
                Button("Open \(name)", systemImage: "chart.bar") { open(name) }
            }
            Divider()
            Button("Delete Session", systemImage: "trash", role: .destructive) { remove(session) }
        }
        .historyID("session-\(name)")
    }
}

/// "Deleted acme-api. Undo": six seconds to take it back.
private struct UndoBar: View {
    @Binding var undo: TimeSession?
    let history: History
    var body: some View {
        if let s = undo {
            HStack(spacing: 12) {
                Image(systemName: "trash").foregroundStyle(.secondary)
                Text("Deleted \(HistoryMath.name(s))").font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer(minLength: 8)
                Button("Undo") { history.undelete(s); undo = nil }
                    .font(.subheadline.weight(.semibold)).buttonStyle(.borderless).tint(.historyGreen)
                    .historyID("history-undo")
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 10, y: 2)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: s.id) {
                try? await Task.sleep(for: .seconds(6))
                if undo?.id == s.id { undo = nil }
            }
        }
    }
}

/// Fix a session: its project, its start, its end; or delete it. Saving writes one edit line.
struct SessionEditor: View {
    let session: TimeSession
    let history: History
    let remove: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var project = ""
    @State private var start = Date.now
    @State private var end = Date.now
    @State private var filled: Set<String> = []

    /// "That was Acme from 9 to 11": the project (matched to one you have) and the times on the
    /// session's own day, then a green flash on what was filled. Save still decides.
    private func heard(_ words: String) {
        let v = VoiceForm.session(words, known: history.projects.map(\.name))
        var got: Set<String> = []
        let day = Calendar.current.startOfDay(for: session.start)
        func at(_ t: (h: Int, m: Int)) -> Date { Calendar.current.date(bySettingHour: t.h, minute: t.m, second: 0, of: day) ?? day }
        if let p = v.project { project = p; got.insert("project") }
        if let s = v.start { start = at(s); got.insert("start") }
        if let e = v.end, session.end != nil { end = max(at(e), start); got.insert("end") }
        filled = got
        Task { try? await Task.sleep(for: .seconds(1.6)); filled = [] }
    }

    var body: some View {
        let form = Form {
            Section {
                RecordBar(tint: .historyGreen) { heard($0) }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            Section {
                TextField("Project", text: $project).historyID("session-project")
                    .filled(filled.contains("project"))
            }
            Section {
                DatePicker("Start", selection: $start, in: ...(session.end == nil ? Date.now : end), displayedComponents: [.date, .hourAndMinute])
                    .historyID("session-start")
                    .filled(filled.contains("start"))
                if session.end != nil {
                    DatePicker("End", selection: $end, in: start...max(start, Date.now), displayedComponents: [.date, .hourAndMinute])
                        .historyID("session-end")
                        .filled(filled.contains("end"))
                }
            } footer: {
                Label("\(session.device ?? session.host), \(TimeLog.span(worked)) worked", systemImage: historyDeviceSymbol(session))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button(role: .destructive) { remove(); dismiss() } label: { Label("Delete Session", systemImage: "trash") }
                    .historyID("session-delete")
            }
        }
        .onAppear {
            project = session.project ?? ""
            start = session.start
            end = session.end ?? .now
        }
        #if os(macOS)
        VStack(spacing: 0) {
            Text("Edit Session").font(.title3.weight(.semibold)).padding(.top, 18)
            form.formStyle(.grouped).frame(width: 440, height: 370)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).historyID("session-cancel")
                Button("Save") { save() }.keyboardShortcut(.defaultAction).tint(.historyGreen).historyID("session-save")
            }
            .padding([.horizontal, .bottom], 18)
        }
        #else
        NavigationStack {
            form
                .navigationTitle("Edit Session")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() }.historyID("session-cancel") }
                    ToolbarItem(placement: .confirmationAction) { Button("Save", systemImage: "checkmark") { save() }.historyID("session-save") }
                }
        }
        .presentationDetents([.large])
        #endif
    }

    private var worked: TimeInterval {
        var s = session
        s.start = start
        if s.end != nil { s.end = max(start, end) }
        s.paused = min(s.paused, (s.end ?? .now).timeIntervalSince(start))
        return s.active()
    }

    private func save() {
        let name = project.trimmingCharacters(in: .whitespacesAndNewlines)
        history.edit(session,
                     project: name == (session.project ?? "") ? nil : name,
                     start: abs(start.timeIntervalSince(session.start)) < 30 ? nil : start,
                     end: session.end.flatMap { abs(end.timeIntervalSince($0)) < 30 ? nil : end })
        dismiss()
    }
}

/// Rename a project: type the new name or say it. Every session takes it, on every device.
struct RenameProject: View {
    let project: String
    let sessions: Int
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var form: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    TextField("New name", text: $name).labelsHidden().historyID("rename-field")
                        #if os(macOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                    DictateButton(text: $name, tint: .historyGreen) { _ in }.historyID("rename-dictate")
                }
            } footer: {
                Text("\(sessions) \(sessions == 1 ? "session" : "sessions") of \(project) take the new name, on every device.")
            }
        }
        .onAppear { name = project }
    }

    private func done() {
        save(name)
        dismiss()
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            Text("Rename Project").font(.title3.weight(.semibold)).padding(.top, 18)
            form.formStyle(.grouped).frame(width: 440, height: 170)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).historyID("rename-cancel")
                Button("Rename") { done() }.keyboardShortcut(.defaultAction).tint(.historyGreen).historyID("rename-save")
            }
            .padding([.horizontal, .bottom], 18)
        }
        #else
        NavigationStack {
            form
                .navigationTitle("Rename Project")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() }.historyID("rename-cancel") }
                    ToolbarItem(placement: .confirmationAction) { Button("Rename", systemImage: "checkmark") { done() }.historyID("rename-save") }
                }
        }
        .presentationDetents([.height(220)])
        #endif
    }
}

// MARK: - A project

/// One project: its numbers, its twelve weeks, its initiative and links, every session, and
/// Start Again.
struct ProjectDetail: View {
    @Bindable var history: History
    let project: String
    /// Follow the project to its new name after a rename (the page is keyed by the name).
    var renamed: ((String) -> Void)? = nil
    @State private var naming = false
    @State private var editing: TimeSession?
    @State private var undo: TimeSession?
    @State private var initiative = ""
    @State private var suggested: String?

    var body: some View {
        let list = history.sessions(of: project)
        let st = HistoryMath.stats(list, now: history.now)
        let note = history.notes[project] ?? ProjectNote()
        let hidden = history.projects.first { $0.name == project }?.hidden == true
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(project).font(.system(size: 30, weight: .bold)).lineLimit(2).minimumScaleFactor(0.6).historyID("project-title")
                        Button { naming = true } label: { Image(systemName: "pencil").font(.body.weight(.semibold)) }
                            .buttonStyle(.borderless).foregroundStyle(Color.historyGreen)
                            .accessibilityLabel("Rename project").historyID("project-rename")
                    }
                    Text(st.first.map { "Since \($0.formatted(.dateTime.day().month(.wide).year()))" } ?? "No sessions yet")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { history.startAgain(project) } label: {
                    Label("Start Again", systemImage: "play.fill").font(.body.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent).tint(.historyGreen).controlSize(.large)
                .historyID("project-start-again")
            }
            TileGrid(columns: 2, tiles: [
                AnyView(Tile(label: "Total", value: TimeLog.span(st.total), accent: true)),
                AnyView(Tile(label: "Sessions", value: "\(st.sessions)")),
                AnyView(Tile(label: "Average", value: TimeLog.span(st.average), note: "a session")),
                AnyView(Tile(label: "Last worked", value: st.last.map { $0.formatted(.relative(presentation: .named)) } ?? "Never",
                             note: st.last?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))),
            ])
            Trend(history: history, project: project).historyCard()
            links(note: note, hidden: hidden).historyCard()
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(text: "Sessions", detail: "\(list.count)")
                ForEach(list.sorted { $0.start > $1.start }.prefix(200)) { s in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(s.start, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
                        SessionRow(session: s, now: history.now, edit: { editing = $0 }, remove: remove, startAgain: history.startAgain, open: { _ in })
                    }
                }
            }
            .historyCard()
        }
        .sheet(item: $editing) { s in SessionEditor(session: s, history: history, remove: { remove(s) }) }
        .sheet(isPresented: $naming) {
            RenameProject(project: project, sessions: list.count) { name in
                if let now = history.rename(project, to: name) { renamed?(now) }
            }
        }
        .overlay(alignment: .bottom) { UndoBar(undo: $undo, history: history) }
        .onAppear { initiative = note.initiative ?? "" }
        .onChange(of: project) { _, p in initiative = history.notes[p]?.initiative ?? "" }
    }

    private func remove(_ s: TimeSession) { history.delete(s); undo = s }

    /// Initiative, linked entities and goals, hide or show, and a suggestion for Glyph CRM.
    @ViewBuilder private func links(note: ProjectNote, hidden: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(text: "Part of")
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up").foregroundStyle(Color.historyGreen).frame(width: 22)
                if history.saveNote != nil {
                    TextField("Initiative, like Client work", text: $initiative)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { history.setInitiative(project, initiative) }
                        .historyID("project-initiative")
                    DictateButton(text: $initiative, tint: .historyGreen) { _ in history.setInitiative(project, initiative) }
                        .historyID("project-initiative-dictate")
                    if initiative != (note.initiative ?? "") {
                        Button("Save") { history.setInitiative(project, initiative) }.tint(.historyGreen).historyID("project-initiative-save")
                    }
                    let known = history.initiatives.filter { $0 != initiative }
                    if !known.isEmpty {
                        Menu {
                            ForEach(known, id: \.self) { i in Button(i) { initiative = i; history.setInitiative(project, i) } }
                        } label: { Image(systemName: "chevron.down") }
                        .menuIndicator(.hidden).fixedSize().accessibilityLabel("Pick an initiative")
                    }
                } else {
                    Text(note.initiative ?? "No initiative").foregroundStyle(note.initiative == nil ? .secondary : .primary)
                }
            }
            if !note.entities.isEmpty {
                FlowRow(spacing: 8) {
                    ForEach(note.entities, id: \.self) { id in
                        Label(HistoryMath.entityName(id, goals: history.goalTitles), systemImage: HistoryMath.entitySymbol(id))
                            .font(.callout).lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.historyGreen.opacity(0.12), in: Capsule())
                            .contextMenu { if history.saveNote != nil { Button("Remove Link", systemImage: "minus.circle") { history.link(project, id, on: false) } } }
                    }
                }
                .historyID("project-links")
            }
            HStack(spacing: 10) {
                if history.saveNote != nil, !history.goalTitles.isEmpty {
                    Menu {
                        ForEach(history.goalTitles.sorted { $0.value < $1.value }.prefix(80), id: \.key) { id, title in
                            Button(String(title.prefix(70))) { history.link(project, "goal/\(id)", on: true) }
                        }
                    } label: { Label("Link a Goal", systemImage: "target") }
                    .fixedSize().historyID("project-link-goal")
                }
                if let suggest = history.suggest {
                    Menu {
                        ForEach([("Product", "product"), ("Person", "person"), ("Place", "place"), ("Thing", "thing")], id: \.1) { label, kind in
                            Button("As a \(label)") { suggest(project, kind); suggested = label }
                        }
                    } label: { Label("Suggest for Glyph CRM", systemImage: "person.crop.rectangle.stack") }
                    .fixedSize().historyID("project-suggest")
                }
                Spacer(minLength: 0)
                Button(hidden ? "Show in Recent" : "Hide from Recent", systemImage: hidden ? "eye" : "eye.slash") {
                    hidden ? history.show(project) : history.hide(project)
                }
                .historyID("project-hide")
            }
            .buttonStyle(.bordered)
            if let suggested {
                Text("Suggested as a \(suggested.lowercased()). Accept it in Glyph CRM and the link shows here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
