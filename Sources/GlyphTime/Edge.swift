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
    /// Office green #008000, and a brighter cut for small marks on the dark panel.
    static let office = Color(red: 0, green: 128 / 255, blue: 0)
    static let officeOnDark = Color(red: 0.2, green: 0.72, blue: 0.2)
}

private struct EdgeView: View {
    private let clock = Clock.shared
    private let edge = Edge.shared

    private var open: Bool { edge.hovering || clock.nudge != nil }

    var body: some View {
        Group {
            if open {
                Card(clock: clock)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if clock.session != nil {
                Count(clock: clock)
                    .transition(.opacity)
            } else {
                // Nothing running: a thin tab to reach for.
                Tab()
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
    func edgeBackground(_ radius: CGFloat) -> some View {
        background(EdgeShape(radius: radius).fill(Color(white: 0.09).opacity(0.94)))
            .overlay(EdgeShape(radius: radius).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            .clipShape(EdgeShape(radius: radius))
            .padding(.vertical, 6).padding(.leading, 6) // room for the shadow
            .shadow(color: .black.opacity(0.22), radius: 5, x: -1, y: 1)
    }
}

private struct Tab: View {
    var body: some View {
        Rectangle().fill(.clear)
            .frame(width: 6, height: 40)
            .edgeBackground(3)
            .accessibilityElement()
            .accessibilityLabel("Glyph Time")
            .accessibilityIdentifier("tab")
    }
}

/// The resting count: a dot and the time.
private struct Count: View {
    let clock: Clock

    var body: some View {
        HStack(spacing: 7) {
            Mark(clock: clock)
            Text(clock.display)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(clock.paused ? 0.5 : 0.95))
                .contentTransition(.numericText())
        }
        .padding(.leading, 12).padding(.trailing, 11)
        .frame(height: 30)
        .edgeBackground(9)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("count")
    }
}

/// Green while running, a hollow grey ring while paused, a small timer for a countdown.
private struct Mark: View {
    let clock: Clock
    var body: some View {
        if clock.session?.countdown != nil {
            Image(systemName: "timer")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(clock.paused ? .white.opacity(0.45) : .officeOnDark)
        } else if clock.paused {
            Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1.5).frame(width: 7, height: 7)
        } else {
            Circle().fill(Color.officeOnDark).frame(width: 7, height: 7)
        }
    }
}

/// Open: the project, the time, and the controls (or a nudge and its two answers).
private struct Card: View {
    let clock: Clock

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(clock.guessed && clock.nudge == nil ? 0.55 : 0.85))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("title")
            Text(clock.session == nil ? "0:00" : clock.display)
                .font(.system(size: 34, weight: .light).monospacedDigit())
                .foregroundStyle(.white.opacity(clock.session == nil || clock.paused ? 0.45 : 1))
                .contentTransition(.numericText())
                .padding(.top, 2)
                .accessibilityIdentifier("time")
            Group {
                if clock.nudge != nil { answers } else { controls }
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 14)
        .frame(width: 236, alignment: .leading)
        .edgeBackground(14)
    }

    private var title: String {
        if let nudge = clock.nudge { return nudge }
        if clock.session == nil { return "Glyph Time" }
        return clock.project // paused shows in the dimmed time and the play button, not in words
    }

    private var answers: some View {
        HStack(spacing: 8) {
            Button { clock.answer(true) } label: {
                Text("Keep going").frame(maxWidth: .infinity)
            }
            .buttonStyle(Pill(fill: .office))
            .testFrame("Keep going")
            Button { clock.answer(false) } label: {
                Text("Stop").frame(maxWidth: .infinity)
            }
            .buttonStyle(Pill(fill: .white.opacity(0.12)))
            .testFrame("Stop")
        }
    }

    /// Three places, one control each: the main action, stop, more.
    private var controls: some View {
        HStack(spacing: 0) {
            if clock.session == nil {
                Round(symbol: "play.fill", label: "Start", fill: .office) { clock.start() }
            } else if clock.paused {
                Round(symbol: "play.fill", label: "Resume", fill: .office) { clock.resume() }
            } else {
                Round(symbol: "pause.fill", label: "Pause", fill: .white.opacity(0.14)) { clock.pause() }
            }
            Spacer()
            if clock.session != nil {
                Round(symbol: "stop.fill", label: "Stop", fill: .white.opacity(0.14)) { clock.stop() }
                Spacer()
            }
            More(clock: clock)
        }
    }
}

private struct Round: View {
    let symbol: String, label: String, fill: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
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
    let fill: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(height: 30)
            .background(Capsule().fill(fill).opacity(configuration.isPressed ? 0.75 : 1))
            .contentShape(Capsule())
    }
}

/// Name, countdowns, settings: the same choices as the menu bar.
private struct More: View {
    let clock: Clock
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
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(0.08)))
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
