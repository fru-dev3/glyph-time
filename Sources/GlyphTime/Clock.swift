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
    /// Every named project, most recently started first, from every month on disk, hidden ones flagged.
    private(set) var projects: [TimeProject] = []
    var recent: [TimeProject] { projects.filter { !$0.hidden } }
    var hidden: [TimeProject] { projects.filter(\.hidden) }

    var running: Bool { session != nil && session?.pausedSince == nil }
    var paused: Bool { session?.pausedSince != nil }
    var elapsed: TimeInterval { session?.active(at: now) ?? 0 }
    /// What the clock shows: time so far, or time left on a countdown ("+" once it is over).
    var display: String {
        guard let target = session?.countdown else { return TimeLog.clock(elapsed) }
        let left = Double(target) * minute - elapsed
        return left >= 0 ? TimeLog.clock(left) : "+" + TimeLog.clock(-left)
    }
    /// 0 to 1: toward the next nudge, or toward a countdown's end.
    var progress: Double {
        guard session != nil else { return 0 }
        if let t = session?.countdown { return min(1, elapsed / (Double(t) * minute)) }
        guard nudgeMinutes > 0 else { return 0 }
        let every = Double(nudgeMinutes) * minute
        return elapsed.truncatingRemainder(dividingBy: every) / every
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

    static let idleKey = "idleMinutes", nudgeKey = "nudgeMinutes", autoHideKey = "autoHideProjects", chimeKey = "chimes"
    static let autoStartKey = "autoStart"
    /// A sound every 15 minutes: a tick, a different one on the half hour, a bigger one on the hour.
    var chimes: Bool { UserDefaults.standard.object(forKey: Self.chimeKey) as? Bool ?? true }
    private var lastQuarter = 0
    private var quarter: Int { Int(elapsed / (15 * minute)) }
    /// How long this session has run: 0 under an hour, 1 under two, 2 after. The green warms with it.
    var heat: Int { min(2, Int(elapsed / (60 * minute))) }
    var nudgeMinutes: Int { UserDefaults.standard.object(forKey: Self.nudgeKey) as? Int ?? 30 }
    var idleMinutes: Int { UserDefaults.standard.object(forKey: Self.idleKey) as? Int ?? 5 }
    /// Start timing by itself when work starts, so an hour is not lost to having forgotten to press
    /// Start (Fru, 2026-11-07: "detect activity as i start workign or typing and begin detecting or
    /// tracking time so it all fits into my analytics report").
    var autoStart: Bool { UserDefaults.standard.object(forKey: Self.autoStartKey) as? Bool ?? true }
    /// Stopped by hand means stopped: the same work does not start itself again inside this.
    static var autoStartPause: TimeInterval = 15 * 60 // a var so the check can watch the window close
    private(set) var stoppedProject: String?
    private(set) var stoppedAt: Date?
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
        lastQuarter = quarter
        countdownDone = session?.countdown.map { elapsed >= Double($0) * minute } ?? false
        refreshToday()
        tick()
        Store.writeSummary()
    }

    // MARK: Actions (every one appends a line)

    func start(project name: String? = nil, countdown: Int? = nil) {
        if session != nil { stop() }
        stoppedProject = nil // started on purpose: nothing to hold back from starting itself
        let guess = name.map { (project: $0, source: "named", app: Optional<String>.none) } ?? Guess.front()
        write(TimeEvent("start", host: Store.host, device: Store.device, project: guess.project,
                        source: guess.source, app: guess.app, countdown: countdown))
        lastBoundary = 0
        lastQuarter = 0
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

    /// `byHand` is the difference between "I am done with this" and the clock closing a session
    /// you walked away from: only the first holds the auto-start back.
    func stop(at date: Date = .now, byHand: Bool = true) {
        guard let s = session else { return }
        if byHand { stoppedProject = s.project; stoppedAt = .now }
        write(TimeEvent("stop", at: date, host: Store.host, minutes: Int((s.active(at: date) / 60).rounded())))
        endNudge()
        Store.writeSummary()
    }

    /// A line written somewhere else (History's rename, edit or delete): fold this Mac's open
    /// session again, so the edge clock and the menu show what the file now says.
    func reload() {
        session = TimeLog.sessions(Store.recent().filter { $0.host == Store.host }).last { $0.end == nil }
        refreshToday()
        Edge.shared.update()
    }

    func rename(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session != nil, !clean.isEmpty, clean != session?.project else { return }
        write(TimeEvent("name", host: Store.host, project: String(clean.prefix(80)), source: "named"))
    }

    /// Off the Recent list, or back on it: a line, so every device agrees. History keeps it either way.
    func hide(_ name: String) { write(TimeEvent("hide", host: Store.host, project: name)) }
    func unhide(_ name: String) { write(TimeEvent("show", host: Store.host, project: name)) }

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
        if HistoryWindow.window?.isVisible == true { MacHistory.refresh() }
    }

    func refreshToday() {
        let start = Calendar.current.startOfDay(for: .now)
        today = TimeLog.totals(TimeLog.sessions(Store.recent()), from: start, to: start.addingTimeInterval(86_400))
        let auto = UserDefaults.standard.bool(forKey: Self.autoHideKey)
        projects = TimeLog.projects(Store.all(), autoHideDays: auto ? 30 : nil)
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

    /// Requests this Mac has already acted on, so a line is never obeyed twice.
    private var answered: Set<String> = []

    /// Reads a request's `ts` (GlyphVault's `localStamp`).
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    /// What Glyph Native asked of the timer, from anywhere.
    ///
    /// Fru, 2026-11-11, with the Now card's Pause and Stop doing nothing to a timer running on
    /// this Mac: "buttons don't work". They were reaching the vault — the lines were there, with
    /// the right commands and the right times — and nothing on this Mac ever read them. The phone
    /// has polled this queue since October; the Mac never has, so a command from the phone could
    /// only ever reach a timer the phone itself was running.
    ///
    /// Read straight from the vault rather than over HTTP, because this app already has the vault
    /// open and writes its own sessions there: the hub drops each request into the same folder.
    private func takeRequests() {
        guard !UITest.on, let vault = Store.vault else { return }
        let folder = vault.appending(path: "data/apps/time")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in files where name.hasPrefix("requests.") && name.hasSuffix(".jsonl") {
            guard let text = try? String(contentsOf: folder.appending(path: name), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let r = try? JSONDecoder().decode(TimeRequest.self, from: Data(line.utf8)),
                      r.event == "request", let command = r.command?.lowercased(),
                      !answered.contains(r.id) else { continue }
                // Only the three a running clock can obey. Anything else is the driver's business
                // (alarms, reminders) and the phone's Time answers those as it always has.
                let act: () -> Void
                if command.contains("pause") { act = { self.pause(reason: "asked") } }
                else if command.contains("resume") || command.contains("continue") { act = { self.resume() } }
                else if command.contains("stop") || command.contains("end") { act = { self.stop() } }
                else { continue }
                answered.insert(r.id)
                guard let open = session else { continue }   // nothing running here: leave it for whoever has it
                // A command is about the timer that was running when it was tapped. This queue
                // held 23 unanswered pauses and a stop from hours earlier, and the first timer
                // started after that was paused and stopped two seconds later by them, which
                // reads as the clock broken rather than obeyed. A line sent before this session
                // began belongs to one that is already over.
                guard let sent = Self.stamp.date(from: r.ts), sent >= open.start else { continue }
                act()
                let taken = TimeRequest(id: r.id, event: "taken", kind: r.kind, text: "Glyph Time on this Mac")
                if let d = try? JSONEncoder().encode(taken) {
                    var body = d
                    body.append(0x0A)
                    let answers = folder.appending(path: "requests.\(Store.host).jsonl")
                    if let h = try? FileHandle(forWritingTo: answers) {
                        h.seekToEndOfFile(); h.write(body); try? h.close()
                    } else {
                        try? body.write(to: answers)
                    }
                }
            }
        }
    }

    private func second() {
        now = .now
        seconds += 1
        if seconds % 5 == 0 { Watch.checkIdle() }
        // Every two seconds while something runs: fast enough that a tap on the phone feels
        // immediate, slow enough that it is a directory read and not a spin.
        if seconds % 2 == 0 { takeRequests() }
        guard running else { return }
        chime()
        guard nudge == nil else { return }
        if let target = session?.countdown, !countdownDone, elapsed >= Double(target) * minute {
            countdownDone = true
            show("Time is up on \(project)")
            ring()
            return
        }
        let b = boundary
        guard b > lastBoundary else { return }
        lastBoundary = b
        if skipNext { skipNext = false; return }
        show("\(TimeLog.span(Double(b * nudgeMinutes * 60))) on \(project)")
    }

    /// A countdown's end rings, always (it was asked for), every 5 seconds for up to a minute
    /// while "Time is up" is still showing.
    private func ring() {
        guard !UITest.on else { return } // the check asserts the words, never the sound
        Task { @MainActor in
            for _ in 0..<12 {
                guard nudge?.hasPrefix("Time is up") == true else { return }
                NSSound(named: "Submarine")?.play()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func chime() {
        let q = quarter
        guard q > lastQuarter else { return }
        lastQuarter = q
        guard chimes else { return }
        NSSound(named: q % 4 == 0 ? "Hero" : q % 2 == 0 ? "Glass" : "Tink")?.play()
    }

    /// The nudge slides out, stays 8 seconds, then fades back. Ignored once: the next one is skipped.
    /// A countdown's "Time is up" stays until answered.
    func show(_ text: String) {
        nudge = text
        Edge.shared.update()
        nudgeTask?.cancel()
        if text.hasPrefix("Time is up") { return }
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

    /// A short note on the edge clock (what a spoken command did), gone after a few seconds.
    /// Set while the note is what a spoken command did: the card offers Undo instead of a nudge's answers.
    private(set) var undo: (() -> Void)?

    func say(_ text: String, undo: (() -> Void)? = nil) {
        nudge = text
        self.undo = undo
        Edge.shared.update()
        nudgeTask?.cancel()
        nudgeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(UITest.nudgeSeconds ?? 5))
            guard !Task.isCancelled, nudge == text else { return }
            endNudge()
        }
    }

    /// Undo what was said, or just close the note.
    func closeSaid(undoing: Bool) {
        let u = undo
        endNudge()
        if undoing { u?() }
    }

    private func endNudge() {
        undo = nil
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
