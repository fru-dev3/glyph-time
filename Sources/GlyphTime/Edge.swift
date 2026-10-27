import AppKit
import SwiftUI
import GlyphVault

/// A panel that can take typing when asked, yet never makes Glyph Time the active app.
final class EdgePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Grab it anywhere: past 4pt of movement it follows the mouse, and it stays where it's let go. Below that, the click goes to the control under it. A double click puts it back.
    private var grab: (mouse: NSPoint, origin: NSPoint)?
    private var moving = false
    private func onScreen(_ e: NSEvent) -> NSPoint { NSPoint(x: frame.minX + e.locationInWindow.x, y: frame.minY + e.locationInWindow.y) }
    override func sendEvent(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown:
            if e.clickCount == 2 { Edge.shared.resetPosition(); return }
            grab = (onScreen(e), frame.origin); moving = false
        case .leftMouseDragged:
            if let g = grab {
                let m = onScreen(e), dx = m.x - g.mouse.x, dy = m.y - g.mouse.y
                if !moving, hypot(dx, dy) > 4 { moving = true; Edge.shared.dragging = true }
                if moving { setFrameOrigin(NSPoint(x: g.origin.x + dx, y: g.origin.y + dy)); return }
            }
        case .leftMouseUp:
            grab = nil
            if moving { moving = false; Edge.shared.drop(); return } // a drag is not a click
        default: break
        }
        super.sendEvent(e)
    }
}

/// The clock on the edge of the screen: the Runner tile when nothing runs, the tile and time while
/// it runs, the controls on hover, a nudge that slides out and fades back. It never takes focus:
/// a non-activating panel over every Space and full-screen app.
@MainActor @Observable
final class Edge {
    static let shared = Edge()

    var hovering = false
    @ObservationIgnored private var leaving: Task<Void, Never>?
    @ObservationIgnored private(set) var panel: EdgePanel!

    // Where it sits, per display: the nearer side, how far in from it (0 = docked), and a height.
    enum Side: String { case left, right }
    var side: Side = .right
    var inset: Double = 0
    var docked: Bool { inset < 1 }
    /// Keep the card open while a session runs, or fold it to the tile (and on hover-out).
    var keepOpen = false
    @ObservationIgnored var dragging = false
    @ObservationIgnored private var centerY: Double?
    @ObservationIgnored private var screenID: UInt32?
    private static func id(_ s: NSScreen) -> UInt32 { (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
    private var screen: NSScreen? { NSScreen.screens.first { Self.id($0) == screenID } ?? NSScreen.screens.first }

    /// Where positions are kept; the UI check keeps its own in memory and never moves the real one.
    private var spots: UserDefaults? { UITest.on ? nil : .standard }

    func loadPosition() {
        guard let d = spots else { return }
        screenID = (d.object(forKey: "edgeScreen") as? NSNumber)?.uint32Value
        guard let s = screen else { return }
        side = Side(rawValue: d.string(forKey: "edgeSide.\(Self.id(s))") ?? "") ?? .right
        centerY = d.object(forKey: "edgeY.\(Self.id(s))") as? Double
        inset = d.double(forKey: "edgeInset.\(Self.id(s))")
        keepOpen = d.bool(forKey: "keepOpen")
    }

    func setKeepOpen(_ on: Bool) {
        keepOpen = on
        spots?.set(on, forKey: "keepOpen")
        if !on { withAnimation(.smooth(duration: 0.28)) { hovering = false } }
    }
    func toggleKeepOpen() { setKeepOpen(!keepOpen) }

    /// Released: exactly where it was let go, kept on the display under its centre. It's anchored to
    /// the nearer side, so the card opens toward the free space.
    func drop() {
        guard let panel else { return }
        let c = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let s = NSScreen.screens.first { $0.frame.contains(c) } ?? screen ?? NSScreen.screens[0]
        screenID = Self.id(s); centerY = c.y
        side = c.x < s.visibleFrame.midX ? .left : .right
        let v = s.visibleFrame
        inset = max(0, side == .right ? v.maxX - panel.frame.maxX : panel.frame.minX - v.minX)
        let k = Self.id(s)
        spots?.set(NSNumber(value: k), forKey: "edgeScreen"); spots?.set(side.rawValue, forKey: "edgeSide.\(k)"); spots?.set(c.y, forKey: "edgeY.\(k)"); spots?.set(inset, forKey: "edgeInset.\(k)")
        dragging = false
        fit()
    }

    func resetPosition() {
        if let s = screen { spots?.removeObject(forKey: "edgeSide.\(Self.id(s))"); spots?.removeObject(forKey: "edgeY.\(Self.id(s))"); spots?.removeObject(forKey: "edgeInset.\(Self.id(s))") }
        spots?.removeObject(forKey: "edgeScreen")
        screenID = nil; centerY = nil; side = .right; inset = 0
        fit()
    }

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
        panel.canHide = false // a Dock click hides the app to hand focus back; the clock stays
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        let host = NSHostingView(rootView: EdgeView())
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Edge.shared.fit() }
        }
        loadPosition()
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

    /// Sized to the view, flush with its side of its display (by default the right edge of the main
    /// display, a little above centre), never over the menu bar or the Dock.
    func fit(_ size: CGSize? = nil) {
        guard let panel, !dragging, let screen = screen?.visibleFrame else { return }
        let size = size ?? panel.contentView?.fittingSize ?? .zero
        guard size.width > 0 else { return }
        let cy = centerY ?? screen.midY + screen.height * 0.08
        let y = min(max(cy - size.height / 2, screen.minY), screen.maxY - size.height).rounded()
        let x = side == .right ? screen.maxX - size.width - inset : screen.minX + inset
        let frame = NSRect(x: min(max(x, screen.minX), screen.maxX - size.width).rounded(), y: y, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// Opened from the Dock: the card shows, and closes again if the mouse never comes to it.
    func peek() {
        if !shown { shown = true }
        hover(true)
        leaving = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let panel, !panel.frame.contains(NSEvent.mouseLocation) else { return }
            hover(false)
        }
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

    private var open: Bool { edge.hovering || clock.nudge != nil || (edge.keepOpen && clock.session != nil) }

    var body: some View {
        let p = Palette(scheme)
        Group {
            if open {
                Card(clock: clock, p: p)
                .transition(.move(edge: edge.side == .left ? .leading : .trailing).combined(with: .opacity))
            } else if clock.session != nil {
                Count(clock: clock, p: p)
                .transition(.opacity)
            } else {
                Tab(clock: clock, p: p)
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
    var left = false // on the left side of the screen, rounded on the right
    var all = false // floating free: every corner rounded
    var inset: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        let r = max(0, radius - inset)
        if all { return RoundedRectangle(cornerRadius: r, style: .continuous).path(in: rect.insetBy(dx: inset, dy: inset)) }
        return (left ? UnevenRoundedRectangle(bottomTrailingRadius: r, topTrailingRadius: r, style: .continuous)
                     : UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r, style: .continuous))
            .path(in: rect.insetBy(dx: inset, dy: inset))
    }
    func inset(by amount: CGFloat) -> EdgeShape { var s = self; s.inset += amount; return s }
}

private extension View {
    /// Glass in the panel's colours, a hairline (green while a session runs), a soft shadow.
    func edgeBackground(_ radius: CGFloat, _ p: Palette, live: Bool = false) -> some View {
        let left = Edge.shared.side == .left, all = !Edge.shared.docked
        return background(EdgeShape(radius: radius, left: left, all: all).fill(p.fill))
            .overlay(EdgeShape(radius: radius, left: left, all: all).strokeBorder(live ? p.green.opacity(0.55) : p.hairline, lineWidth: live ? 1 : 0.5))
            .clipShape(EdgeShape(radius: radius, left: left, all: all))
            .padding(.vertical, 6).padding(all ? .horizontal : left ? .trailing : .leading, 6) // room for the shadow
            .shadow(color: .black.opacity(p.dark ? 0.28 : 0.14), radius: 6, x: left ? 1 : -1, y: 1)
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
            Button("Reset Clock Position") { Edge.shared.resetPosition() }
            Button("Settings...") { SettingsWindow.show() }
        } label: {
            // Drawn, not a symbol: a menu label recolours symbols to white, unreadable on the light panel.
            HStack(spacing: 3.5) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(p.ink.opacity(0.5)).frame(width: 4, height: 4) }
            }
                .frame(width: 32, height: 32) // no disc, lighter dots: quieter than the main action
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

/// Up to the next multiple of 8.
private func onGrid(_ v: CGFloat) -> CGFloat { (v / 8).rounded(.up) * 8 }
private func width(_ s: String, _ font: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: font]).width) }

/// A control in a 32pt frame: a filled disc or a bare glyph.
private struct Key: View {
    let symbol: String, label: String, ink: Color
    var fill: Color = .clear
    var weight: Font.Weight = .semibold
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: weight))
                .foregroundStyle(ink)
                .frame(width: 32, height: 32)
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
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(Capsule().fill(fill).opacity(configuration.isPressed ? 0.75 : 1))
            .contentShape(Capsule())
    }
}

/// Open: the mark and project, the time, progress, and the controls (or a nudge and its answers),
/// one column on an 8pt grid, every gap measured to the ink.
private struct Card: View {
    let clock: Clock, p: Palette

    /// 45pt light digits: their cap height is 32pt, so the ink sits on the grid.
    private let digitSize: CGFloat = 45
    private var digitFont: NSFont { .monospacedDigitSystemFont(ofSize: digitSize, weight: .light) }
    private var digits: String { clock.session == nil ? "0:00" : clock.display }

    private var title: String {
        if let nudge = clock.nudge { return nudge }
        if clock.session == nil { return "Glyph Time" }
        return clock.project
    }

    /// As wide as the widest row, with the digits measured from the longest time they can show
    /// in its current format (so it never jumps as the seconds tick), rounded up to the grid.
    private var contentWidth: CGFloat {
        let time = width(String(digits.map { $0.isNumber ? "8" : $0 }), digitFont) // grows only when the format does
        let header = 20 + 8 + width(title, .systemFont(ofSize: 15, weight: .semibold)) + 44 // gap, spacer, gap, the keep-open control
        let pill = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let answers = clock.nudge == nil ? 0 : width("Keep going", pill) + width("Stop", pill) + 4 * 16 + 8
        let keys: CGFloat = clock.session == nil ? 2 : 3 // primary, stop, More
        return onGrid(max(time, header, answers, keys * 32 + (keys - 1) * 8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Mark(size: 20)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(clock.nudge == nil && (clock.guessed || clock.session == nil) ? p.soft : p.ink.opacity(0.88))
                    .lineLimit(1)
                    .accessibilityIdentifier("title")
                Spacer(minLength: 8)
                KeepOpen(p: p)
            }
            .frame(height: 20)
            Text(digits)
                .font(.system(size: digitSize, weight: .light).monospacedDigit())
                .foregroundStyle(clock.session == nil || clock.paused ? p.soft : p.ink)
                .contentTransition(.numericText())
                // Trimmed to the ink (cap height), so the gaps measured on screen are the gaps set here.
                .padding(.top, -(digitFont.ascender - digitFont.capHeight))
                .padding(.bottom, digitFont.descender)
                .padding(.top, 16)
                .accessibilityIdentifier("time")
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.track)
                    Capsule().fill(clock.running ? p.green : p.soft)
                        .frame(width: max(2, g.size.width * (clock.session == nil ? 0 : clock.progress)))
                }
            }
            .frame(height: 2)
            .padding(.top, 8)
            .animation(.linear(duration: 1), value: clock.progress)
            Group {
                if clock.nudge != nil { answers } else { controls }
            }
            .frame(height: 32)
            .padding(.top, 16)
        }
        .frame(width: contentWidth, alignment: .leading)
        .padding(16)
        .edgeBackground(16, p, live: clock.running)
    }

    private var answers: some View {
        HStack(spacing: 8) {
            Button("Keep going") { clock.answer(true) }
                .buttonStyle(Pill(fill: p.green, ink: .white))
                .testFrame("Keep going")
            Button("Stop") { clock.answer(false) }
                .buttonStyle(Pill(fill: p.track, ink: p.ink))
                .testFrame("Stop")
        }
    }

    private var primary: (symbol: String, label: String, action: () -> Void) {
        if clock.session == nil { return ("play.fill", "Start", { clock.start() }) }
        if clock.paused { return ("play.fill", "Resume", { clock.resume() }) }
        return ("pause.fill", "Pause", { clock.pause() })
    }

    /// Left on the text column, 8pt apart: the main action (green), then stop and More, quieter.
    private var controls: some View {
        let main = primary
        return HStack(spacing: 8) {
            Key(symbol: main.symbol, label: main.label, ink: .white, fill: p.green, action: main.action).id(main.label)
            if clock.session != nil {
                Key(symbol: "stop.fill", label: "Stop", ink: p.ink.opacity(0.6), weight: .regular) { clock.stop() }
            }
            More(clock: clock, p: p)
        }
    }
}

/// The Runner tile, as on the app icon: easy to find on any desktop. While a session runs it carries
/// a ring toward the next nudge; paused, the tile dims and the ring goes grey.
private struct TileMark: View {
    let clock: Clock, p: Palette
    var body: some View {
        let on = clock.session != nil, live = clock.running, green = p.green
        Mark(size: 32)
            .opacity(on && !live ? 0.45 : 1) // paused: calm, the green steps back
            .overlay {
                if on {
                    let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
                    ZStack {
                        shape.stroke(live ? green.opacity(0.3) : p.track, lineWidth: 2)
                        shape.trim(from: 0, to: max(0.03, clock.progress))
                            .stroke(live ? green : p.soft, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90)) // from the top, clockwise
                    }
                    .padding(-3)
                    .animation(.linear(duration: 1), value: clock.progress)
                }
            }
            .frame(width: 40, height: 40)
    }
}

/// Nothing running: the tile alone, docked at the edge with a soft shadow. A click opens the card.
private struct Tab: View {
    let clock: Clock, p: Palette
    var body: some View {
        TileMark(clock: clock, p: p)
            .shadow(color: .black.opacity(p.dark ? 0.5 : 0.25), radius: 4, y: 1)
            .padding(4)
            .contentShape(Rectangle())
            .onTapGesture { Edge.shared.hover(true) }
            .accessibilityElement()
            .accessibilityLabel("Glyph Time")
            .accessibilityIdentifier("tab")
    }
}

/// The resting pill: the tile, then the time. Running reads green at a glance, paused goes calm grey.
private struct Count: View {
    let clock: Clock, p: Palette
    var body: some View {
        let live = clock.running
        HStack(spacing: 8) {
            TileMark(clock: clock, p: p)
            Text(clock.display)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(live ? p.ink : p.soft)
                .contentTransition(.numericText())
        }
        .padding(.leading, 4).padding(.trailing, 16)
        .frame(height: 48)
        .edgeBackground(16, p, live: live)
        .contentShape(Rectangle())
        .onTapGesture { Edge.shared.hover(true) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("count")
    }
}

/// The card's top-right corner, its only control there: keep the card open while a session runs,
/// or fold it to the tile and time.
private struct KeepOpen: View {
    let p: Palette
    var body: some View {
        let on = Edge.shared.keepOpen, label = on ? "Minimize" : "Keep Open"
        Button { Edge.shared.toggleKeepOpen() } label: {
            Image(systemName: on ? "arrow.down.right.and.arrow.up.left" : "pin")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(p.ink.opacity(0.5))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-4) // a 28pt target in the 20pt header row
        .accessibilityLabel(label)
        .help(label)
        .testFrame(label)
        .id(label)
    }
}
