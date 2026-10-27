import AppKit
import ApplicationServices

/// Sleep, screen lock and idle pause the clock at the moment you left; coming back within 30
/// minutes resumes it, longer ends the session where you left. A pause you made yourself is
/// never undone for you.
@MainActor
enum Watch {
    static func start() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Clock.shared.pause(reason: "sleep") }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Clock.shared.load() } // a fresh read: another day may have begun
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Clock.shared.pause(reason: "lock") }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { back() }
        }
    }

    /// Seconds since the last key press, click or pointer move. Needs no permission.
    static var idle: TimeInterval {
        if let test = UITest.idle { return test }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Every 5 seconds while a session is open.
    static func checkIdle() {
        let clock = Clock.shared
        let idle = idle
        if clock.running, clock.idleMinutes > 0, idle >= Double(clock.idleMinutes * 60) {
            // Dated when you left, but never before the last line written (the start or a resume).
            clock.pause(reason: "idle", at: max(Date.now.addingTimeInterval(-idle), clock.lastLine))
        } else if clock.paused, idle < 5 {
            back()
        }
    }

    /// Input again after an automatic pause.
    static func back() {
        let clock = Clock.shared
        guard let s = clock.session, let since = s.pausedSince, ["idle", "sleep", "lock"].contains(s.pauseReason ?? "") else { return }
        if Date.now.timeIntervalSince(since) < clock.awayLimit {
            clock.resume()
        } else {
            clock.stop(at: since)
        }
    }
}

/// The project a new session is on: the repo or folder of the front terminal or editor window
/// (Glyph Jot's `Rules.project`, from the window's title and folder), else the front app's name.
/// Only the name is kept, never the title.
enum Guess {
    static func front() -> (project: String, source: String, app: String?) {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return ("", "app", nil)
        }
        let bundle = app.bundleIdentifier ?? "", name = app.localizedName ?? "App"
        if AXIsProcessTrusted(), let repo = window(pid: app.processIdentifier, bundle: bundle, app: name) {
            return (repo, "repo", bundle)
        }
        return (name, "app", bundle)
    }

    private static func window(pid: pid_t, bundle: String, app: String) -> String? {
        guard Rules.projectApps.contains(bundle) else { return nil }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.3) // a busy app gives no answer rather than a slow one
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let w = window as! AXUIElement
        var title: CFTypeRef?, document: CFTypeRef?
        AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &title)
        AXUIElementCopyAttributeValue(w, kAXDocumentAttribute as CFString, &document)
        return Rules.project(title: title as? String ?? "", document: document as? String, bundle: bundle, app: app,
                             user: URL.homeDirectory.lastPathComponent)
    }
}
