import AppKit
import GlyphVault

/// The timer. Its state is the session file (`Store`): every action appends a line, and the open
/// session is folded back from the lines at launch, so a crash, a reboot or sleep loses nothing.
@MainActor @Observable
final class Clock {
    static let shared = Clock()

    /// This Mac's open session, if any.
    private(set) var session: TimeSession?
    /// Ticks once a second while a session is open, so the views redraw.
    private(set) var now = Date.now
    /// Showing a nudge: what it says.
    private(set) var nudge: String?
    /// Today's sessions on every device, for the menu.
    private(set) var today: [(project: String, seconds: TimeInterval)] = []

    var running: Bool { session != nil && session?.pausedSince == nil }
    var paused: Bool { session?.pausedSince != nil }
    var elapsed: TimeInterval { session?.active(at: now) ?? 0 }
    /// What the clock shows: time so far, or time left on a countdown ("+" once it is over).
    var display: String {
        guard let target = session?.countdown else { return TimeLog.clock(elapsed) }
        let left = Double(target) * minute - elapsed
        return left >= 0 ? TimeLog.clock(left) : "+" + TimeLog.clock(-left)
    }
    var project: String { session?.project?.isEmpty == false ? session!.project! : "Unnamed" }
    var guessed: Bool { session?.source == "repo" || session?.source == "app" }

    /// When this Mac's last line was written: an automatic pause is never dated before it.
    private(set) var lastLine = Date.distantPast
    private var timer: Timer?
    private var lastBoundary = 0
    private var skipNext = false
    private var countdownDone = false
    private var nudgeTask: Task<Void, Never>?

    static let idleKey = "idleMinutes", nudgeKey = "nudgeMinutes"
    var nudgeMinutes: Int { UserDefaults.standard.object(forKey: Self.nudgeKey) as? Int ?? 30 }
    var idleMinutes: Int { UserDefaults.standard.object(forKey: Self.idleKey) as? Int ?? 5 }
    /// Away longer than this and an idle pause ends the session where you left instead of resuming.
    let awayLimit: TimeInterval = 30 * 60
    /// Seconds in a minute: 60, except in the UI test, which runs nudges and countdowns fast.
    var minute: Double { UITest.minute ?? 60 }

    func load() {
        let mine = Store.recent().filter { $0.host == Store.host }
        lastLine = mine.last?.ts ?? .distantPast
        session = TimeLog.sessions(mine).last { $0.end == nil }
        now = .now
        // No storm of nudges after a relaunch or a long sleep: start counting from here.
        lastBoundary = boundary
        countdownDone = session?.countdown.map { elapsed >= Double($0) * minute } ?? false
        refreshToday()
        tick()
        Store.writeSummary()
    }

    // MARK: Actions (every one appends a line)

    func start(project name: String? = nil, countdown: Int? = nil) {
        if session != nil { stop() }
        let guess = name.map { (project: $0, source: "named", app: Optional<String>.none) } ?? Guess.front()
        write(TimeEvent("start", host: Store.host, device: Store.device, project: guess.project,
                        source: guess.source, app: guess.app, countdown: countdown))
        lastBoundary = 0
        skipNext = false
        countdownDone = false
        Edge.shared.update()
    }

    func pause(reason: String = "user", at date: Date = .now) {
        guard running else { return }
        write(TimeEvent("pause", at: date, host: Store.host, reason: reason))
    }

    func resume() {
        guard paused else { return }
        write(TimeEvent("resume", host: Store.host))
    }

    func toggle() { running ? pause() : paused ? resume() : start() }

    func stop(at date: Date = .now) {
        guard let s = session else { return }
        write(TimeEvent("stop", at: date, host: Store.host, minutes: Int((s.active(at: date) / 60).rounded())))
        endNudge()
        Store.writeSummary()
    }

    func rename(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session != nil, !clean.isEmpty, clean != session?.project else { return }
        write(TimeEvent("name", host: Store.host, project: String(clean.prefix(80)), source: "named"))
    }

    func answer(_ keep: Bool) {
        nudgeTask?.cancel()
        let minutes = Int(elapsed / 60)
        write(TimeEvent("nudge", host: Store.host, minutes: minutes, answer: keep ? "keep" : "stop"))
        nudge = nil
        if !keep { stop() }
        Edge.shared.update()
    }

    private func write(_ event: TimeEvent) {
        Store.write(event)
        lastLine = max(lastLine, event.ts)
        session = TimeLog.sessions(Store.recent().filter { $0.host == Store.host }).last { $0.end == nil }
        now = .now
        refreshToday()
        tick()
        StatusMenu.shared.update()
        Edge.shared.update()
    }

    func refreshToday() {
        let start = Calendar.current.startOfDay(for: .now)
        today = TimeLog.totals(TimeLog.sessions(Store.recent()), from: start, to: start.addingTimeInterval(86_400))
    }

    // MARK: The tick: display, nudges, idle

    private var boundary: Int { nudgeMinutes > 0 ? Int(elapsed / (Double(nudgeMinutes) * minute)) : 0 }

    private func tick() {
        timer?.invalidate()
        guard session != nil else { timer = nil; return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { Clock.shared.second() }
        }
        timer?.tolerance = 0.2
    }

    private var seconds = 0

    private func second() {
        now = .now
        seconds += 1
        if seconds % 5 == 0 { Watch.checkIdle() }
        guard running, nudge == nil else { return }
        if let target = session?.countdown, !countdownDone, elapsed >= Double(target) * minute {
            countdownDone = true
            show("Time is up on \(project)")
            return
        }
        let b = boundary
        guard b > lastBoundary else { return }
        lastBoundary = b
        if skipNext { skipNext = false; return }
        show("\(TimeLog.span(Double(b * nudgeMinutes * 60))) on \(project)")
    }

    /// The nudge slides out, stays 8 seconds, then fades back. Ignored once: the next one is skipped.
    func show(_ text: String) {
        nudge = text
        Edge.shared.update()
        nudgeTask?.cancel()
        nudgeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(UITest.nudgeSeconds ?? 8))
            guard !Task.isCancelled, nudge != nil else { return }
            if !Edge.shared.hovering {
                write(TimeEvent("nudge", host: Store.host, minutes: Int(elapsed / 60), answer: "ignored"))
                skipNext = true
                endNudge()
            }
        }
    }

    private func endNudge() {
        nudgeTask?.cancel()
        nudge = nil
        Edge.shared.update()
    }

    /// The pointer left a nudge that it had held open.
    func hoverEnded() {
        guard nudge != nil else { return }
        show(nudge!)
    }
}
