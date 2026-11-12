import GlyphCapture
import GlyphVault
import SwiftUI

// The Tally Stone (design council, 2026-10-30): Glyph Time's signature. A running timer is a rough
// stone; Time's runner carves one office-green tally a minute into it (one per 5 minutes past an
// hour), every fifth a slash across the group. Strokes still to come are faint scratches, so what is
// left reads at a glance. Paused, the runner sits; at the end the last slash goes in and the stone
// settles. Shared, so the Mac app can use it too. Drawn here, no images.

/// What the stone needs from a session: when it started, its pauses, and a countdown's length.
struct TallyRun: Equatable {
    var start: Date
    /// Seconds of a countdown, nil for a count-up.
    var total: TimeInterval?
    var paused: TimeInterval = 0
    var pausedSince: Date?
    /// Seconds in a minute (a UI test makes it shorter).
    var minute: TimeInterval = 60
    /// Keeps each session's strokes its own, the same on every redraw.
    var seed = ""

    init(start: Date, total: TimeInterval?, paused: TimeInterval = 0, pausedSince: Date? = nil, minute: TimeInterval = 60, seed: String = "") {
        self.start = start; self.total = total; self.paused = paused; self.pausedSince = pausedSince; self.minute = minute
        self.seed = seed.isEmpty ? "\(start.timeIntervalSinceReferenceDate)" : seed
    }

    init(_ s: TimeSession, minute: TimeInterval = 60) {
        self.init(start: s.start, total: s.countdown.map { Double($0) * minute }, paused: s.paused, pausedSince: s.pausedSince,
                  minute: minute, seed: s.id)
    }

    var isPaused: Bool { pausedSince != nil }

    func elapsed(at now: Date) -> TimeInterval {
        let open = pausedSince.map { max(0, now.timeIntervalSince($0)) } ?? 0
        return max(0, now.timeIntervalSince(start) - paused - open)
    }

    /// A countdown's seconds left (a count-up's elapsed): what the big digits show.
    func shown(at now: Date) -> TimeInterval { total.map { max(0, $0 - elapsed(at: now)) } ?? elapsed(at: now) }
    func ended(at now: Date) -> Bool { total.map { elapsed(at: now) >= $0 } ?? false }

    /// Seconds per stroke and how many strokes the stone holds. A countdown: one a minute, one per
    /// 5 minutes past an hour (15 past ten hours). A count-up: the half hour, then the hour, then
    /// hours of 5-minute strokes.
    func layout(at now: Date) -> (unit: TimeInterval, count: Int) {
        if let total {
            let unit = total <= 60 * minute ? minute : total <= 600 * minute ? 5 * minute : 15 * minute
            return (unit, max(1, Int((total / unit).rounded(.up))))
        }
        let e = elapsed(at: now)
        if e < 60 * minute { return (minute, e < 30 * minute ? 30 : 60) }
        let unit = 5 * minute
        return (unit, (Int(e / unit) / 12 + 1) * 12)
    }
}

/// Stone, strokes and inks for light and dark: warm stone, never a black tile.
struct StonePalette {
    let dark: Bool
    init(_ scheme: ColorScheme) { dark = scheme == .dark }
    var face: Color { dark ? Color(red: 0.33, green: 0.31, blue: 0.29) : Color(red: 0.925, green: 0.902, blue: 0.86) }
    var shade: Color { dark ? Color(red: 0.24, green: 0.225, blue: 0.21) : Color(red: 0.84, green: 0.81, blue: 0.755) }
    var ink: Color { dark ? Color(red: 0.88, green: 0.85, blue: 0.8) : Color(red: 0.36, green: 0.32, blue: 0.28) }
    /// #008000, a brighter cut on the dark stone.
    var cut: Color { dark ? Color(red: 0.3, green: 0.8, blue: 0.3) : Color(red: 0, green: 128 / 255, blue: 0) }
    var rim: Color { dark ? .white.opacity(0.1) : .white.opacity(0.65) }
}

/// A small deterministic random source (the same strokes every redraw and every launch).
struct TallyRandom {
    private var state: UInt64
    init(_ seed: String, _ salt: Int = 0) {
        var h: UInt64 = 1469598103934665603
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        state = h ^ (UInt64(truncatingIfNeeded: salt) &* 0x9E3779B97F4A7C15)
    }
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
    /// -1 ... 1
    mutating func wobble() -> Double { next() * 2 - 1 }
}

/// The stone's outline: a rounded slab with a little noise on its edge.
struct StoneShape: Shape {
    var seed: String
    func path(in r: CGRect) -> Path {
        var rnd = TallyRandom(seed, 7)
        let n = 18
        let cx = r.midX, cy = r.midY, a = r.width / 2, b = r.height / 2
        let pts: [CGPoint] = (0..<n).map { i in
            let t = Double(i) / Double(n) * 2 * .pi
            // A superellipse (squarish slab), each point nudged in or out by up to 3.5%.
            let c = cos(t), s = sin(t), p = 0.5
            let x = (c < 0 ? -1 : 1) * pow(abs(c), p), y = (s < 0 ? -1 : 1) * pow(abs(s), p)
            let k = 1 - 0.07 * abs(rnd.wobble()) - 0.01
            return CGPoint(x: cx + a * x * k, y: cy + b * y * k)
        }
        var path = Path()
        func mid(_ p: CGPoint, _ q: CGPoint) -> CGPoint { CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2) }
        path.move(to: mid(pts[n - 1], pts[0]))
        for i in 0..<n { path.addQuadCurve(to: mid(pts[i], pts[(i + 1) % n]), control: pts[i]) }
        path.closeSubpath()
        return path
    }
}

/// The stone with its strokes and the runner, alive at 60 fps while it runs.
struct TallyStone: View {
    let run: TallyRun
    /// A countdown that finished: every stroke cut, the runner's arms up.
    var done = false
    /// Nothing runs: no strokes, the runner resting in the middle.
    var blank = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = StonePalette(scheme)
        let still = reduceMotion || FaceFeatures.forceStill
        ZStack {
            // The shadow it sits on, then the slab: lit from the top left, a pale rim, a few grains.
            Ellipse().fill(.black.opacity(p.dark ? 0.35 : 0.12)).blur(radius: 10)
                .scaleEffect(x: 0.86, y: 0.16).offset(y: 6).frame(maxHeight: .infinity, alignment: .bottom)
            StoneShape(seed: run.seed)
                .fill(LinearGradient(colors: [p.face, p.shade], startPoint: .topLeading, endPoint: .bottomTrailing))
            Canvas { ctx, size in
                var rnd = TallyRandom(run.seed, 3)
                ctx.clip(to: StoneShape(seed: run.seed).path(in: CGRect(origin: .zero, size: size)))
                for _ in 0..<70 {
                    let d = 0.8 + rnd.next() * 1.8
                    let r = CGRect(x: rnd.next() * size.width, y: rnd.next() * size.height, width: d, height: d)
                    ctx.fill(Path(ellipseIn: r), with: .color(p.ink.opacity(0.05 + rnd.next() * 0.09)))
                }
            }
            StoneShape(seed: run.seed).stroke(p.rim, lineWidth: 1.2).offset(x: 0.6, y: 0.8).mask(StoneShape(seed: run.seed))
            if blank {
                Canvas { g, size in
                    let h = min(120, size.height * 0.42)
                    Tally.drawRunner(&g, feet: CGPoint(x: size.width / 2 + h * 0.1, y: size.height * 0.5 + h * 0.5), height: h, pose: .sit,
                                     swing: 0.5, ink: p.ink, chisel: p.cut, halo: p.face)
                }
            } else {
                TimelineView(.animation(minimumInterval: still ? 1 : nil, paused: run.isPaused || done)) { ctx in
                    Canvas { g, size in
                        Tally.draw(&g, size: size, run: run, now: ctx.date, done: done, still: still, p: p)
                    }
                }
            }
        }
        .scaleEffect(done ? 1 : 0.975) // the settle: a bounce when the last slash goes in
        .animation(still ? nil : .spring(response: 0.4, dampingFraction: 0.4), value: done)
    }
}

/// The drawing, kept out of the view so the Live Activity strip can draw the same strokes.
enum Tally {
    struct Slot { var a: CGPoint; var b: CGPoint; var slash: Bool; var row: Int }

    /// Where each stroke sits in a box: rows of groups of five, balanced (25 is 3 + 2 groups).
    static func slots(_ count: Int, in box: CGRect, seed: String, maxPerRow: Int = 4) -> [Slot] {
        let groups = (count + 4) / 5
        let rows = max(1, Int((Double(groups) / Double(maxPerRow)).rounded(.up)))
        let perRow = max(1, Int((Double(groups) / Double(rows)).rounded(.up)))
        let rowH = box.height / CGFloat(rows)
        // A few strokes stay tally-sized (not one group filling the stone).
        let len = min(rowH * 0.8, box.width / CGFloat(perRow) * 1.0, box.height * 0.72)
        let groupW = min(box.width / CGFloat(perRow), len * 1.25)
        let gap = groupW / 5.4
        var rnd = TallyRandom(seed, 11)
        var out: [Slot] = []
        for i in 0..<count {
            let g = i / 5, k = i % 5
            let row = g / perRow, col = g % perRow
            // A short last row sits centred.
            let inRow = row == rows - 1 ? groups - row * perRow : perRow
            let left = box.minX + (box.width - groupW * CGFloat(inRow)) / 2 + groupW * CGFloat(col)
            let top = box.minY + rowH * CGFloat(row) + (rowH - len) / 2
            let x0 = left + groupW * 0.16
            let j = { (s: Double) in CGFloat(rnd.wobble() * s) }
            if k < 4 {
                let x = x0 + gap * CGFloat(k) + j(0.9)
                let l = len * (1 + j(0.07)), tilt = j(0.07) * len // a few degrees either way
                let y = top + (len - l) / 2 + j(1.2)
                out.append(Slot(a: CGPoint(x: x - tilt / 2, y: y), b: CGPoint(x: x + tilt / 2, y: y + l), slash: false, row: row))
            } else {
                let a = CGPoint(x: x0 - gap * 0.55 + j(1), y: top + len * (0.8 + j(0.05)))
                let b = CGPoint(x: x0 + gap * 3.55 + j(1), y: top + len * (0.2 + j(0.05)))
                out.append(Slot(a: a, b: b, slash: true, row: row))
            }
        }
        return out
    }

    /// A stroke as a cut: a lens tapering at both ends, with a pale edge where the chisel went in.
    static func cut(_ g: inout GraphicsContext, _ a: CGPoint, _ b: CGPoint, width w: CGFloat, p: StonePalette) {
        let dx = b.x - a.x, dy = b.y - a.y, l = max(0.01, sqrt(dx * dx + dy * dy))
        let n = CGPoint(x: -dy / l, y: dx / l)
        let m = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        var lens = Path()
        lens.move(to: a)
        lens.addQuadCurve(to: b, control: CGPoint(x: m.x + n.x * w, y: m.y + n.y * w))
        lens.addQuadCurve(to: a, control: CGPoint(x: m.x - n.x * w, y: m.y - n.y * w))
        g.fill(lens, with: .color(p.cut))
        var edge = Path()
        edge.move(to: CGPoint(x: a.x + n.x * w * 0.3, y: a.y + n.y * w * 0.3))
        edge.addQuadCurve(to: CGPoint(x: b.x + n.x * w * 0.3, y: b.y + n.y * w * 0.3),
                          control: CGPoint(x: m.x + n.x * w * 0.75, y: m.y + n.y * w * 0.75))
        g.stroke(edge, with: .color(.white.opacity(p.dark ? 0.18 : 0.35)), lineWidth: max(0.5, w * 0.18))
    }

    static func draw(_ g: inout GraphicsContext, size: CGSize, run: TallyRun, now: Date, done: Bool, still: Bool, p: StonePalette) {
        let (unit, count) = run.layout(at: now)
        let e = run.elapsed(at: now)
        let carved = done ? count : min(count, Int(e / unit))
        // Seconds since the newest stroke went in: its draw-in, its dust, the runner's step.
        let since: TimeInterval = (done || still || carved == 0) ? 60 : e - Double(carved) * unit
        let box = CGRect(x: size.width * 0.09, y: size.height * 0.12, width: size.width * 0.82, height: size.height * 0.72)
        let slots = slots(count, in: box, seed: run.seed)
        guard let first = slots.first else { return }
        let len = abs(first.b.y - first.a.y)
        let w = max(2, min(10, len * 0.11))
        let drawIn = 0.45

        for (i, s) in slots.enumerated() {
            if i < carved {
                // The newest stroke draws in from where the chisel starts.
                let k = i == carved - 1 ? CGFloat(min(1, since / drawIn)) : 1
                let b = CGPoint(x: s.a.x + (s.b.x - s.a.x) * k, y: s.a.y + (s.b.y - s.a.y) * k)
                cut(&g, s.a, b, width: w * (0.6 + 0.4 * k), p: p)
            } else {
                // Still to come: a faint scratch.
                var line = Path(); line.move(to: s.a); line.addLine(to: s.b)
                g.stroke(line, with: .color(p.ink.opacity(p.dark ? 0.24 : 0.2)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            }
        }
        // A tiny chip of dust off the new cut (none with Reduce Motion).
        if carved > 0, since < 0.8 {
            let s = slots[carved - 1]
            var rnd = TallyRandom(run.seed, 100 + carved)
            let t = since, fade = 1 - t / 0.8
            for _ in 0..<7 {
                let vx = rnd.wobble() * 38, vy = -18 - rnd.next() * 34
                let x = s.b.x + vx * t, y = s.b.y + vy * t + 90 * t * t
                let d = 1.1 + rnd.next() * 1.6
                g.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)), with: .color(p.ink.opacity(0.55 * fade)))
            }
        }
        // The runner, by the stroke it works on next (by the last one once it's done).
        let at = min(carved, count - 1)
        func stand(_ i: Int) -> CGPoint {
            let s = slots[max(0, i)]
            return CGPoint(x: max(s.a.x, s.b.x) + len * (s.slash ? 0.16 : 0.3), y: max(s.a.y, s.b.y))
        }
        var feet = stand(at)
        if carved > 0, at == carved, since < 0.4 { // a short hop to the next stroke
            let from = stand(at - 1), k = since / 0.4, ease = CGFloat(1 - (1 - k) * (1 - k))
            feet = CGPoint(x: from.x + (feet.x - from.x) * ease, y: from.y + (feet.y - from.y) * ease - CGFloat(sin(.pi * k)) * len * 0.18)
        }
        let pose: RunnerPose = done || run.ended(at: now) ? .cheer : run.isPaused ? .sit : .carve
        let swing = still ? 0.5 : 0.5 + 0.5 * sin(now.timeIntervalSinceReferenceDate * 2 * .pi / 0.7)
        drawRunner(&g, feet: feet, height: min(120, len * 1.0), pose: pose, swing: swing, ink: p.ink, chisel: p.cut, halo: p.face)
    }

    enum RunnerPose { case carve, sit, cheer }

    /// Time's runner, as on its icon: a stopwatch for a head on a stick body. Carving, one arm taps a
    /// chisel at the stroke to its left; sitting, it rests; at the end, both arms go up.
    static func drawRunner(_ g: inout GraphicsContext, feet f: CGPoint, height h: CGFloat, pose: RunnerPose, swing: Double, ink: Color, chisel: Color, halo: Color) {
        let lw = max(1.3, h * 0.075)
        let style = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)
        let drop: CGFloat = pose == .sit ? h * 0.26 : 0
        let hip = CGPoint(x: f.x, y: f.y - h * 0.36 - (pose == .sit ? -h * 0.2 : 0))
        let neck = CGPoint(x: f.x, y: f.y - h * 0.64 + drop)
        let head = CGPoint(x: f.x, y: f.y - h * 0.8 + drop)
        let r = h * 0.15
        var body = Path()
        body.move(to: neck); body.addLine(to: hip)
        switch pose {
        case .sit: // knees up, feet forward
            body.move(to: hip); body.addLine(to: CGPoint(x: f.x - h * 0.22, y: hip.y - h * 0.1)); body.addLine(to: CGPoint(x: f.x - h * 0.3, y: f.y))
            body.move(to: hip); body.addLine(to: CGPoint(x: f.x - h * 0.12, y: hip.y - h * 0.06)); body.addLine(to: CGPoint(x: f.x - h * 0.16, y: f.y))
            body.move(to: neck); body.addLine(to: CGPoint(x: f.x - h * 0.2, y: hip.y - h * 0.1))
            body.move(to: neck); body.addLine(to: CGPoint(x: f.x - h * 0.1, y: hip.y - h * 0.04))
        case .carve, .cheer:
            body.move(to: hip); body.addLine(to: CGPoint(x: f.x - h * 0.17, y: f.y))
            body.move(to: hip); body.addLine(to: CGPoint(x: f.x + h * 0.15, y: f.y))
            if pose == .cheer { // arms up, the icon's U
                for side in [-1.0, 1.0] {
                    body.move(to: CGPoint(x: neck.x, y: neck.y + h * 0.04))
                    body.addQuadCurve(to: CGPoint(x: f.x + CGFloat(side) * h * 0.27, y: head.y - h * 0.08),
                                      control: CGPoint(x: f.x + CGFloat(side) * h * 0.26, y: neck.y + h * 0.02))
                }
            } else {
                // The far arm on the hip; the near arm taps the chisel at the stone.
                body.move(to: neck); body.addLine(to: CGPoint(x: f.x + h * 0.16, y: hip.y - h * 0.04))
                let angle = -0.15 + 0.55 * swing // radians below the horizontal: raised, then struck down
                let hand = CGPoint(x: neck.x - CGFloat(cos(angle)) * h * 0.3, y: neck.y + h * 0.04 + CGFloat(sin(angle)) * h * 0.3)
                body.move(to: neck); body.addLine(to: hand)
                var tool = Path()
                tool.move(to: hand)
                tool.addLine(to: CGPoint(x: hand.x - h * 0.16, y: hand.y + h * 0.06))
                g.stroke(tool, with: .color(chisel), style: StrokeStyle(lineWidth: lw * 0.9, lineCap: .round))
            }
        }
        // A thin outline in the stone's colour first, so the scratches behind never cross the figure.
        let ring = Path(ellipseIn: CGRect(x: head.x - r, y: head.y - r, width: r * 2, height: r * 2))
        g.stroke(body, with: .color(halo), style: StrokeStyle(lineWidth: lw * 3, lineCap: .round, lineJoin: .round))
        g.fill(ring, with: .color(halo)); g.stroke(ring, with: .color(halo), lineWidth: lw * 3)
        g.stroke(body, with: .color(ink), style: style)
        // The stopwatch head: a ring, its crown and one hand.
        g.stroke(ring, with: .color(ink), lineWidth: lw)
        var crown = Path()
        crown.move(to: CGPoint(x: head.x, y: head.y - r)); crown.addLine(to: CGPoint(x: head.x, y: head.y - r - h * 0.06))
        crown.move(to: CGPoint(x: head.x - h * 0.05, y: head.y - r - h * 0.07)); crown.addLine(to: CGPoint(x: head.x + h * 0.05, y: head.y - r - h * 0.07))
        crown.move(to: head); crown.addLine(to: CGPoint(x: head.x + r * 0.5, y: head.y - r * 0.5))
        g.stroke(crown, with: .color(ink), style: StrokeStyle(lineWidth: lw * 0.8, lineCap: .round))
    }
}

/// The stone, then the time left big and one quiet line: a bell and the end ("9:56 AM") for a
/// countdown, "since 9:12" for a count-up. No labels.
struct TallyClock: View {
    let run: TallyRun
    var done = false
    /// The stone's height; the digits scale with it.
    var height: CGFloat = 200

    var body: some View {
        // Re-read each second: the digits, the line, and what VoiceOver (and the UI tests) hear.
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 8) {
                TallyStone(run: run, done: done)
                    .frame(height: height)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement()
                    .accessibilityIdentifier("tally-stone")
                    .accessibilityLabel(Self.spoken(run, at: ctx.date, done: done))
                    .accessibilityValue(Self.strokes(run, at: ctx.date, done: done))
                VStack(spacing: 4) {
                    Text(TimeLog.clock(run.shown(at: ctx.date)))
                        .font(.system(size: min(76, max(44, height * 0.3)), weight: .light, design: .rounded)).monospacedDigit()
                        .foregroundStyle(run.isPaused ? .secondary : .primary)
                        .contentTransition(.numericText(countsDown: run.total != nil))
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .accessibilityIdentifier("time-clock")
                    Self.line(run, at: ctx.date, done: done)
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("time-end")
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// When a countdown ends if it runs on from now.
    static func end(_ run: TallyRun, at now: Date) -> Date? { run.total.map { now.addingTimeInterval(max(0, $0 - run.elapsed(at: now))) } }

    @ViewBuilder static func line(_ run: TallyRun, at now: Date, done: Bool) -> some View {
        if done || run.ended(at: now) {
            Label("Done", systemImage: "checkmark")
        } else if run.isPaused {
            Label("Paused", systemImage: "pause.fill")
        } else if let end = end(run, at: now) {
            Label(end.formatted(date: .omitted, time: .shortened), systemImage: "bell.fill")
        } else {
            Text("since " + run.start.formatted(date: .omitted, time: .shortened))
        }
    }

    /// "12 minutes left, ends at 9:56 AM" / "42 minutes so far, since 9:12 AM".
    static func spoken(_ run: TallyRun, at now: Date, done: Bool) -> String {
        if done || run.ended(at: now) { return "Countdown done" }
        let span = Duration.seconds(run.shown(at: now)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2))
        if let end = end(run, at: now) {
            return "\(span) left, " + (run.isPaused ? "paused" : "ends at \(end.formatted(date: .omitted, time: .shortened))")
        }
        return "\(span) so far, since \(run.start.formatted(date: .omitted, time: .shortened))" + (run.isPaused ? ", paused" : "")
    }

    /// "3 of 25": strokes cut so far (UI tests read it to see the stone grow).
    static func strokes(_ run: TallyRun, at now: Date, done: Bool) -> String {
        let (unit, count) = run.layout(at: now)
        return "\(done ? count : min(count, Int(run.elapsed(at: now) / unit))) of \(count)"
    }
}

/// One row of the stone for the Lock Screen and the Dynamic Island: the strokes cut so far and the
/// faint ones to come, drawn once (the app redraws it at each minute). No runner, no motion.
struct TallyStrip: View {
    let run: TallyRun
    var now: Date = .now
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = StonePalette(scheme)
        Canvas { g, size in
            let (unit, count) = run.layout(at: now)
            let carved = min(count, Int(run.elapsed(at: now) / unit))
            let slots = Tally.slots(count, in: CGRect(x: 6, y: 3, width: size.width - 12, height: size.height - 6), seed: run.seed, maxPerRow: 99)
            let w = max(1.2, min(3, size.height * 0.08))
            for (i, s) in slots.enumerated() {
                if i < carved { Tally.cut(&g, s.a, s.b, width: w, p: p) } else {
                    var l = Path(); l.move(to: s.a); l.addLine(to: s.b)
                    g.stroke(l, with: .color(p.ink.opacity(0.2)), lineWidth: 0.8)
                }
            }
        }
        .background(StoneShape(seed: run.seed).fill(LinearGradient(colors: [p.face, p.shade], startPoint: .top, endPoint: .bottom)))
        .accessibilityHidden(true)
    }
}
