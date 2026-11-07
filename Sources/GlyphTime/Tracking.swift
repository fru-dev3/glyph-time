import AppKit
import ApplicationServices
import CoreServices
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

/// Track apps and tabs (Settings): every few seconds, what is in front (the app, its window's
/// title with Accessibility, a browser's tab and site with Automation), as spans in
/// `activity/<YYYY-MM-DD>.<host>.jsonl` beside the sessions. Always while you are at the Mac (not
/// idle, locked or asleep), session or not; a running session's project goes on each span.
/// Nothing is read on the main thread but the front app's name: titles and tabs on a queue.
@MainActor
enum Activity {
    static let trackKey = "trackActivity", excludeKey = "activityExclude"
    /// The UI check keeps its own settings, so it never changes the real ones.
    static let defaults = UITest.on ? UserDefaults(suiteName: "dev.fru.time.uitest")! : .standard

    /// On by default only where there is a vault to keep it in.
    static var on: Bool { defaults.object(forKey: trackKey) as? Bool ?? (Store.vault != nil) }
    static var excludeText: String { defaults.string(forKey: excludeKey) ?? ActivityRules.defaultExcluded.joined(separator: "\n") }
    static var excluded: [String] { ActivityRules.list(excludeText) }

    /// `data/apps/time/activity/`, beside the sessions folder.
    static var folder: URL { Store.folder.deletingLastPathComponent().appending(path: "activity") }
    static let every: TimeInterval = 5

    /// What is in front, as last read (after the exclude list and private windows): Captures asks it.
    private(set) static var front: Front?
    private(set) static var away = false
    static var locked = false, asleep = false
    private static var timer: Timer?
    private static var lastSummary = Date.distantPast
    /// Read and written only on `queue`.
    nonisolated(unsafe) private static var tracker = Tracker(host: Store.host)
    nonisolated private static let queue = DispatchQueue(label: "dev.fru.time.activity", qos: .utility)

    static func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { _ in MainActor.assumeIsolated { sample() } }
        timer?.tolerance = 1
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { sample() } // a switch is seen at once, not up to 5 s later
        }
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { asleep = true; flush() }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { asleep = false }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { flush(wait: true) }
        }
    }

    /// Seconds without input that count as away: the clock's own setting, else five minutes.
    static var awayAfter: TimeInterval { Double(Clock.shared.idleMinutes > 0 ? Clock.shared.idleMinutes : 5) * 60 }

    /// One look at the front, then the slow reads on the queue.
    static func sample() {
        guard on || Captures.every > 0 else { front = nil; return }
        let idle = Watch.idle
        away = locked || asleep || idle >= awayAfter
        let awaySince: Date? = away ? Date.now.addingTimeInterval(-(locked || asleep ? 0 : idle)) : nil
        let app = NSWorkspace.shared.frontmostApplication
        let mine = app?.bundleIdentifier == Bundle.main.bundleIdentifier
        let base = app.map { Front(app: $0.localizedName ?? "App", bundle: $0.bundleIdentifier) }
        let pid = app?.processIdentifier ?? 0
        let project = Clock.shared.running ? Clock.shared.session?.project : nil
        let list = excluded, record = on, folder = Self.folder
        let fake = UITest.front // the UI check's made-up front, in place of reading the screen
        if UITest.on && fake == nil { return } // the UI check never reads the real screen
        queue.async {
            var f = fake ?? base
            if fake == nil, var b = f, !mine { Self.read(&b, pid: pid); f = b }
            Self.feed(f, project: project, awaySince: awaySince, record: record, list: list, folder: folder)
        }
    }

    /// Hands a reading to the tracker and writes what ended. The UI check calls it with made-up fronts.
    nonisolated static func feed(_ raw: Front?, project: String?, awaySince: Date?, record: Bool, list: [String], folder: URL) {
        let kept = ActivityRules.keep(raw, excluded: list)
        let spans = record ? tracker.sample(kept, project: project, at: .now, awaySince: awaySince) : tracker.flush(at: .now)
        write(spans, folder)
        let capturable = ActivityRules.mayCapture(raw, excluded: list, away: awaySince != nil)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                front = capturable ? kept : nil
                if !spans.isEmpty, Date.now.timeIntervalSince(lastSummary) > 300 { lastSummary = .now; Store.writeSummary() }
            }
        }
    }

    /// Ends the open span now (sleep, quit, tracking turned off).
    static func flush(wait: Bool = false) {
        let folder = Self.folder
        let work = { write(tracker.flush(at: .now), folder) }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    nonisolated private static func write(_ spans: [ActivitySpan], _ folder: URL) {
        guard !spans.isEmpty else { return }
        do { try ActivityLog.append(spans, to: folder) }
        catch { log.error("activity write failed: \(error.localizedDescription, privacy: .public)") }
    }

    /// A capture's line, beside the spans.
    static func note(_ capture: ActivitySpan) {
        let folder = Self.folder
        queue.async { write([capture], folder) }
    }

    /// The days in a range, every Mac's lines (History's insights).
    nonisolated static func read(_ range: DateInterval, folder: URL) -> [ActivitySpan] {
        ActivityLog.read(folder, days: ActivityLog.days(range.start, range.end)).filter { $0.end > range.start && $0.start < range.end }
    }

    // MARK: Reading the front window (on the queue)

    /// The window's title (Accessibility) or, for a browser, its tab (Apple Events).
    nonisolated private static func read(_ f: inout Front, pid: pid_t) {
        if let bundle = f.bundle, ActivityRules.browsers.contains(bundle) {
            // A browser's title comes only from its tab: if that can't be read, nothing is kept.
            if let tab = Browser.tab(bundle) {
                f.title = tab.title; f.domain = ActivityRules.domain(tab.url); f.isPrivate = tab.isPrivate
                if !f.isPrivate, let w = windowTitle(pid), ActivityRules.isPrivate(title: w) { f.isPrivate = true }
            }
            return
        }
        f.title = windowTitle(pid)
    }

    nonisolated private static func windowTitle(_ pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.3)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        return title as? String
    }
}

/// The front tab of Safari or a Chromium browser, through Apple Events. macOS asks once per
/// browser whether Glyph Time may read it (NSAppleEventsUsageDescription says why); a no is kept.
enum Browser {
    struct Tab { var title: String?; var url: String?; var isPrivate: Bool }
    nonisolated(unsafe) private static var scripts: [String: NSAppleScript] = [:]

    /// Only used on Activity's queue.
    nonisolated static func tab(_ bundle: String) -> Tab? {
        guard !CommandLine.arguments.contains("--uitest"), allowed(bundle) else { return nil } // no Apple Events in the UI check
        let safari = bundle.hasPrefix("com.apple.Safari")
        let source = safari ? """
            with timeout of 2 seconds
              tell application id "\(bundle)"
                if (count of windows) is 0 then return ""
                set t to current tab of front window
                set u to URL of t
                set n to name of t
                if u is missing value then set u to ""
                if n is missing value then set n to ""
                return "normal" & linefeed & u & linefeed & n
              end tell
            end timeout
            """ : """
            with timeout of 2 seconds
              tell application id "\(bundle)"
                if (count of windows) is 0 then return ""
                set w to front window
                if mode of w is not "normal" then return "private"
                set t to active tab of w
                return "normal" & linefeed & (URL of t) & linefeed & (title of t)
              end tell
            end timeout
            """
        let script = scripts[bundle] ?? NSAppleScript(source: source)
        scripts[bundle] = script
        var error: NSDictionary?
        guard let text = script?.executeAndReturnError(&error).stringValue, error == nil, !text.isEmpty else { return nil }
        let parts = text.components(separatedBy: "\n")
        if parts.first == "private" { return Tab(title: nil, url: nil, isPrivate: true) }
        guard parts.count >= 3 else { return nil }
        return Tab(title: parts[2...].joined(separator: " "), url: parts[1], isPrivate: false)
    }

    /// Allowed already, or asked once now. Never asked again after an answer.
    nonisolated private static func allowed(_ bundle: String) -> Bool {
        let askedKey = "askedAutomation." + bundle
        var status = permission(bundle, ask: false)
        if status == OSStatus(errAEEventWouldRequireUserConsent), !UserDefaults.standard.bool(forKey: askedKey), !CommandLine.arguments.contains("--uitest") {
            UserDefaults.standard.set(true, forKey: askedKey)
            status = permission(bundle, ask: true)
        }
        return status == noErr
    }

    nonisolated private static func permission(_ bundle: String, ask: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let id = Array(bundle.utf8)
        guard AECreateDesc(typeApplicationBundleID, id, id.count, &target) == noErr else { return OSStatus(procNotFound) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask)
    }
}

/// Screenshots or short clips every N minutes (Settings; off until you choose), with
/// ScreenCaptureKit. Only while you are at the Mac, never with an excluded app or a private window
/// in front, and never past the day's size limit (then it skips; nothing is ever deleted).
/// `captures/<YYYY-MM-DD>/<HHmmss>.<host>.jpg` (or `.mp4`) beside the sessions, a line in the
/// activity file for each.
@MainActor
enum Captures {
    static let everyKey = "captureMinutes", clipKey = "captureClip", budgetKey = "captureBudgetMB"
    static var every: Int { Activity.defaults.object(forKey: everyKey) as? Int ?? 0 }
    static var clip: Bool { Activity.defaults.bool(forKey: clipKey) }
    static var budgetMB: Int { Activity.defaults.object(forKey: budgetKey) as? Int ?? 200 }
    static let width = 1280, clipSeconds = 12

    static var folder: URL { Store.folder.deletingLastPathComponent().appending(path: "captures") }
    static func day(_ d: Date = .now) -> URL { folder.appending(path: ActivityLog.day(d)) }

    private static var timer: Timer?
    private static var last = Date.distantPast
    private static var busy = false
    /// Why the last one was skipped, for Settings.
    private(set) static var skipped: String?

    static var allowed: Bool { CGPreflightScreenCaptureAccess() }
    /// Asked only when you turn captures on.
    static func ask() { if !allowed, !UITest.on { CGRequestScreenCaptureAccess() } } // never a prompt in the UI check

    static func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        timer?.tolerance = 5
    }

    /// Why a capture can't be taken now, or nil when it can.
    static func reason() -> String? {
        if every == 0 { return "Off" }
        if !allowed { return "Needs Screen Recording" }
        if Activity.away { return "Away" }
        if Activity.front == nil { return "Skipped: a private window or an app on the never list" }
        if !CaptureFiles.allows(used: CaptureFiles.bytes(day()), budgetMB: budgetMB) { return "Today's limit reached" }
        return nil
    }

    static func tick() {
        guard every > 0, !busy, !UITest.on, // the UI check never takes a picture of a shared screen
               Date.now.timeIntervalSince(last) >= Double(every) * 60 - 15 else { return }
        skipped = reason()
        guard skipped == nil, let front = Activity.front else { return }
        last = .now
        busy = true
        Task {
            defer { busy = false }
            do { try await take(front) }
            catch { log.error("capture failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private static func take(_ front: Front) async throws {
        let now = Date.now
        let stamp = now.formatted(.verbatim("\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)", timeZone: .current, calendar: .current))
        let dir = day(now)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "\(stamp).\(Store.host).\(clip ? "mp4" : "jpg")")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let id = (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main)?
            .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else { return }
        let mine = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = Int(Double(width) * Double(display.height) / Double(max(1, display.width)))
        config.showsCursor = false
        if clip {
            config.minimumFrameInterval = CMTime(value: 1, timescale: 2) // 2 frames a second
            try await Clip.record(filter, config, to: file, seconds: clipSeconds)
        } else {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return }
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        Activity.note(ActivitySpan(start: now, end: clip ? now.addingTimeInterval(Double(clipSeconds)) : now, host: Store.host, app: front.app,
                                   bundle: front.bundle, title: Activity.on ? front.title : nil, domain: Activity.on ? front.domain : nil,
                                   project: Clock.shared.running ? Clock.shared.session?.project : nil, kind: clip ? "clip" : "shot",
                                   file: "captures/\(dir.lastPathComponent)/\(file.lastPathComponent)", bytes: bytes))
    }

    /// "12 MB, 9 captures today".
    static func today() -> String {
        let d = day(), n = CaptureFiles.count(d)
        let mb = Double(CaptureFiles.bytes(d)) / 1_000_000
        let size = mb < 0.1 ? "under 0.1 MB" : mb < 10 ? String(format: "%.1f MB", mb) : "\(Int(mb)) MB"
        return n == 0 ? "None yet" : "\(size), \(n) \(n == 1 ? "capture" : "captures")"
    }

    /// Moves days older than 30 into `archived-<date>/captures/`; never deletes. Returns days moved.
    @discardableResult
    static func archiveOld() -> Int {
        let old = CaptureFiles.older(than: 30, in: folder, now: .now)
        guard !old.isEmpty else { return 0 }
        do { return try CaptureFiles.archive(old, timeFolder: folder.deletingLastPathComponent(), now: .now) }
        catch { log.error("archive failed: \(error.localizedDescription, privacy: .public)"); return 0 }
    }
}

/// A short low-frame-rate H.264 clip, written by ScreenCaptureKit's own recorder.
private final class Clip: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    private var done: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    static func record(_ filter: SCContentFilter, _ config: SCStreamConfiguration, to file: URL, seconds: Int) async throws {
        let me = Clip()
        let rc = SCRecordingOutputConfiguration()
        rc.outputURL = file
        rc.outputFileType = .mp4
        rc.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: rc, delegate: me)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()
        try await Task.sleep(for: .seconds(seconds))
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            me.done = c
            stream.stopCapture { error in
                if let error { me.finish(error); return }
                // The recorder says when the file is closed; if it never does, carry on after 5 s.
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { me.finish(nil) }
            }
        }
    }

    private func finish(_ error: Error?) {
        lock.lock()
        let c = done
        done = nil
        lock.unlock()
        guard let c else { return }
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { finish(nil) }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) { finish(error) }
}
