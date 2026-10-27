import AppKit
import SwiftUI
import GlyphVault

/// A panel that can take typing when asked, yet never makes Glyph Time the active app.
final class EdgePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The clock on the right edge of the screen: a thin tab when nothing runs, a small count while
/// it runs, the controls on hover, a nudge that slides out and fades back. It never takes focus:
/// a non-activating panel over every Space and full-screen app.
@MainActor @Observable
final class Edge {
    static let shared = Edge()

    var hovering = false
    @ObservationIgnored private var leaving: Task<Void, Never>?
    @ObservationIgnored private(set) var panel: EdgePanel!

    static let showKey = "showEdge"
    var shown: Bool {
        get { access(keyPath: \.shown); return UserDefaults.standard.object(forKey: Self.showKey) as? Bool ?? true }
        set { withMutation(keyPath: \.shown) { UserDefaults.standard.set(newValue, forKey: Self.showKey) }; update() }
    }

    func setUp() {
        panel = EdgePanel(contentRect: NSRect(x: 0, y: 0, width: 8, height: 44),
                          styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the view draws its own, softer
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        let host = NSHostingView(rootView: EdgeView())
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Edge.shared.fit() }
        }
        update()
    }

    func update() {
        guard let panel else { return }
        if shown || Clock.shared.nudge != nil {
            fit()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    /// Sized to the view, flush with the right edge of the main display, a little above centre.
    func fit(_ size: CGSize? = nil) {
        guard let panel, let screen = NSScreen.screens.first?.visibleFrame else { return }
        let size = size ?? panel.contentView?.fittingSize ?? .zero
        guard size.width > 0 else { return }
        let frame = NSRect(x: screen.maxX - size.width, y: (screen.midY + screen.height * 0.08 - size.height / 2).rounded(),
                           width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    func hover(_ inside: Bool) {
        leaving?.cancel()
        if inside {
            withAnimation(.smooth(duration: 0.22)) { hovering = true }
        } else {
            // A short grace, so passing over the edge doesn't make it flicker.
            leaving = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.28)) { hovering = false }
                Clock.shared.hoverEnded()
            }
        }
    }
}

extension Color {
    /// Office green #008000, and a brighter cut for small marks on a dark panel.
    static let office = Color(red: 0, green: 128 / 255, blue: 0)
    static let officeOnDark = Color(red: 0.2, green: 0.72, blue: 0.2)
}

/// The panel's colours, light and dark: quiet glass, ink, and office green for what matters.
struct Palette {
    let dark: Bool
    init(_ scheme: ColorScheme) { dark = scheme == .dark }
    var fill: Color { dark ? Color(white: 0.09).opacity(0.94) : Color(white: 0.985).opacity(0.97) }
    var hairline: Color { dark ? .white.opacity(0.09) : .black.opacity(0.09) }
    var ink: Color { dark ? .white : Color(white: 0.1) }
    var soft: Color { ink.opacity(0.5) }
    var track: Color { ink.opacity(dark ? 0.14 : 0.09) }
    var green: Color { dark ? .officeOnDark : .office }
}

/// The family mark: Glyph Time's own icon, the runner.
private struct Mark: View {
    var size: CGFloat = 20
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable().interpolation(.high)
            .frame(width: size * 1.24, height: size * 1.24) // the icon's tile is 824 of 1024
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct EdgeView: View {
    private let clock = Clock.shared
    private let edge = Edge.shared
    @Environment(\.colorScheme) private var scheme

    private var open: Bool { edge.hovering || clock.nudge != nil }

    var body: some View {
        let p = Palette(scheme)
        Group {
            if open {
                Card(clock: clock, p: p)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if clock.session != nil {
                Count(clock: clock, p: p)
                    .transition(.opacity)
            } else {
                Tab(p: p)
            }
        }
        .fixedSize()
        .onHover { edge.hover($0) }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { edge.fit($0) }
        .animation(.smooth(duration: 0.25), value: open)
        .animation(.smooth(duration: 0.25), value: clock.session == nil)
    }
}

/// Rounded on the screen side only: it grows out of the edge.
private struct EdgeShape: InsettableShape {
    var radius: CGFloat
    var inset: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        let r = max(0, radius - inset)
        return UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r, style: .continuous)
            .path(in: rect.insetBy(dx: inset, dy: inset))
    }
    func inset(by amount: CGFloat) -> EdgeShape { var s = self; s.inset += amount; return s }
}

private extension View {
    /// Glass in the panel's colours, a hairline (green while a session runs), a soft shadow.
    func edgeBackground(_ radius: CGFloat, _ p: Palette, live: Bool = false) -> some View {
        background(EdgeShape(radius: radius).fill(p.fill))
            .overlay(EdgeShape(radius: radius).strokeBorder(live ? p.green.opacity(0.55) : p.hairline, lineWidth: live ? 1 : 0.5))
            .clipShape(EdgeShape(radius: radius))
            .padding(.vertical, 6).padding(.leading, 6) // room for the shadow
            .shadow(color: .black.opacity(p.dark ? 0.28 : 0.14), radius: 6, x: -1, y: 1)
    }
}

/// Nothing running: a thin tab with a green line, to reach for.
private struct Tab: View {
    let p: Palette
    var body: some View {
        Capsule().fill(p.green)
            .frame(width: 2.5, height: 18)
            .frame(width: 8, height: 40)
            .edgeBackground(4, p)
            .accessibilityElement()
            .accessibilityLabel("Glyph Time")
            .accessibilityIdentifier("tab")
    }
}

/// A ring that fills toward the next nudge (or a countdown's end): green while running, grey paused.
private struct Ring: View {
    let progress: Double, running: Bool, p: Palette
    var size: CGFloat = 13
    var body: some View {
        ZStack {
            Circle().stroke(p.track, lineWidth: 2)
            Circle().trim(from: 0, to: max(0.02, progress))
                .stroke(running ? p.green : p.soft, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.linear(duration: 1), value: progress)
    }
}

/// The resting count: the ring and the time.
private struct Count: View {
    let clock: Clock, p: Palette
    var body: some View {
        HStack(spacing: 8) {
            Ring(progress: clock.progress, running: clock.running, p: p)
            Text(clock.display)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(clock.paused ? p.soft : p.ink)
                .contentTransition(.numericText())
        }
        .padding(.leading, 11).padding(.trailing, 11)
        .frame(height: 30)
        .edgeBackground(9, p, live: clock.running)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("count")
    }
}

/// Open: the mark and project, the time, progress, and the controls (or a nudge and its answers).
private struct Card: View {
    let clock: Clock, p: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Mark(size: 18)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(clock.nudge == nil && (clock.guessed || clock.session == nil) ? p.soft : p.ink.opacity(0.88))
                    .lineLimit(1)
                    .accessibilityIdentifier("title")
            }
            Text(clock.session == nil ? "0:00" : clock.display)
                .font(.system(size: 36, weight: .light).monospacedDigit())
                .tracking(-0.5)
                .foregroundStyle(clock.session == nil || clock.paused ? p.soft : p.ink)
                .contentTransition(.numericText())
                .padding(.top, 6)
                .accessibilityIdentifier("time")
            // Toward the next nudge, or a countdown's end.
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.track)
                    Capsule().fill(clock.running ? p.green : p.soft)
                        .frame(width: max(3, g.size.width * (clock.session == nil ? 0 : clock.progress)))
                }
            }
            .frame(height: 3)
            .padding(.top, 8)
            .animation(.linear(duration: 1), value: clock.progress)
            Group {
                if clock.nudge != nil { answers } else { controls }
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 14)
        .frame(width: 244, alignment: .leading)
        .edgeBackground(14, p, live: clock.running)
    }

    private var title: String {
        if let nudge = clock.nudge { return nudge }
        if clock.session == nil { return "Glyph Time" }
        return clock.project // paused shows in the dimmed time and the play button, not in words
    }

    private var answers: some View {
        HStack(spacing: 8) {
            Button { clock.answer(true) } label: { Text("Keep going").frame(maxWidth: .infinity) }
                .buttonStyle(Pill(fill: p.green, ink: .white))
                .testFrame("Keep going")
            Button { clock.answer(false) } label: { Text("Stop").frame(maxWidth: .infinity) }
                .buttonStyle(Pill(fill: p.track, ink: p.ink))
                .testFrame("Stop")
        }
    }

    /// Three places, one control each: the main action (always green), stop, more.
    private var controls: some View {
        HStack(spacing: 0) {
            if clock.session == nil {
                Round(symbol: "play.fill", label: "Start", fill: p.green, ink: .white) { clock.start() }
            } else if clock.paused {
                Round(symbol: "play.fill", label: "Resume", fill: p.green, ink: .white) { clock.resume() }
            } else {
                Round(symbol: "pause.fill", label: "Pause", fill: p.green, ink: .white) { clock.pause() }
            }
            Spacer()
            if clock.session != nil {
                Round(symbol: "stop.fill", label: "Stop", fill: p.track, ink: p.ink) { clock.stop() }
                Spacer()
            }
            More(clock: clock, p: p)
        }
    }
}

private struct Round: View {
    let symbol: String, label: String, fill: Color, ink: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: 34, height: 34)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
        .testFrame(label)
    }
}

private struct Pill: ButtonStyle {
    let fill: Color, ink: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(ink)
            .frame(height: 30)
            .background(Capsule().fill(fill).opacity(configuration.isPressed ? 0.75 : 1))
            .contentShape(Capsule())
    }
}

/// Name, countdowns, settings: the same choices as the menu bar.
private struct More: View {
    let clock: Clock, p: Palette
    var body: some View {
        Menu {
            if clock.session != nil {
                Button("Name This Session...") { Ask.name() }
            } else {
                Button("Start Named...") { Ask.start() }
            }
            Section("Count down") {
                ForEach(StatusMenu.countdowns, id: \.self) { m in
                    Button("\(m) minutes") { clock.start(project: clock.session?.project, countdown: m) }
                }
            }
            Divider()
            Button("Hide Edge Clock") { Edge.shared.shown = false }
            Button("Settings...") { SettingsWindow.show() }
        } label: {
            // Drawn, not a symbol: a menu label recolours symbols to white, unreadable on the light panel.
            HStack(spacing: 3.5) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(p.ink.opacity(0.7)).frame(width: 4, height: 4) }
            }
                .frame(width: 34, height: 34)
                .background(Circle().fill(p.track))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
        .testFrame("More")
    }
}


extension View {
    /// In the UI test, where a control sits in the panel (top-left points), so the test can click it.
    @ViewBuilder func testFrame(_ name: String) -> some View {
        if UITest.on {
            onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { UITest.frames[name] = $0 }
        } else {
            self
        }
    }
}
