import AppKit
import GlyphVault

/// The UI check's voice part: words injected in place of the microphone (the registration
/// domain, in memory only), then the real controls: the edge clock's mic, the History editor's
/// record bar, the name prompt's Talk.
extension UITest {
    static func hear(_ words: String) { UserDefaults.standard.register(defaults: ["glyphDictationText": words]) }

    static func voiceRun() async {
        print("Voice")
        freshFile()
        let clock = Clock.shared
        if clock.session != nil { clock.stop() }
        hear("I'm working on the Acme deck for the next 10 minutes, remind me")
        await open(true)
        await press("Start by Voice")
        await wait(0.6)
        await shot("40-listening")
        await press("Done Talking")
        check(await until(3) { clock.running }, "saying it on the edge clock starts a timer")
        check(clock.project == "Acme deck" && clock.session?.countdown == 10, "Fru's sentence: Acme deck, a 10-minute countdown (\(clock.project), \(clock.session?.countdown ?? 0))")
        check(clock.nudge?.hasPrefix("Timer: Acme deck") == true, "it says what it understood (\(clock.nudge ?? "-"))")
        await shot("41-said-acme")
        let said = clock.session?.id
        await press("Undo")
        check(clock.session == nil && !MacHistory.shared.sessions.contains { $0.id == said } && !TimeLog.sessions(lines).contains { $0.id == said },
              "Undo stops it and takes it out of History")
        hear("I'm working on the Acme deck for the next 10 minutes, remind me")
        Voice.shared.toggle(); await wait(0.4); Voice.shared.toggle()
        check(await until(3) { clock.running && clock.project == "Acme deck" }, "said again, it runs")
        hear("stop")
        Voice.shared.toggle(); await wait(0.4); Voice.shared.toggle()
        check(await until(3) { clock.session == nil }, "saying stop stops it")
        hear("set a reminder for 3 PM today, studying, remind me 15 minutes before")
        Voice.shared.toggle(); await wait(0.4); Voice.shared.toggle()
        await wait(0.5)
        let marks = lines.filter { $0.event == "reminder" }.compactMap(\.label)
        check(marks.contains("Studying") && marks.contains("Studying in 15 min"), "Fru's reminder sentence: a reminder line and its 15-minute warning (\(marks))")
        let r = lines.last { $0.label == "Studying" }?.at.map { Calendar.current.component(.hour, from: $0) }
        check(r == 15, "at 3 PM (\(r ?? -1))")
        hear("wake me up at 6 AM on weekdays")
        Voice.shared.toggle(); await wait(0.4); Voice.shared.toggle()
        await wait(0.4)
        check(lines.last?.event == "alarm" && lines.last?.days == [1, 2, 3, 4, 5] && lines.last?.label == "Wake up", "Fru's alarm sentence: weekdays, Wake up")
        // Fru's sentences of 2026-10-28: one item each, the right time, repeat, end and a short name.
        func say(_ words: String) async -> TimeEvent? {
            let before = lines.count
            hear(words)
            Voice.shared.toggle(); await wait(0.4); Voice.shared.toggle()
            _ = await until(5) { lines.count > before }
            await wait(0.3)
            let new = lines.dropFirst(before)
            check(new.count == 1, "one sentence, one line (\(new.count)): \(words)")
            return new.last
        }
        var got = await say("Hey, remind me to take a break in 5 minutes")
        let mins = got?.at.map { $0.timeIntervalSinceNow / 60 } ?? 0
        check(got?.event == "alarm" && got?.label == "Take a break" && mins > 4.5 && mins <= 5.1 && got?.days == nil,
              "a break in 5 minutes: one alarm, Take a break (\(got?.label ?? "-"), \(mins) min)")
        check(clock.nudge?.hasPrefix("Alarm: Take a break") == true, "it says so (\(clock.nudge ?? "-"))")
        got = await say("Set an alarm to wake me up every day at 7:30 a.m.")
        let hm = got?.at.map { Calendar.current.dateComponents([.hour, .minute], from: $0) }
        check(got?.event == "alarm" && got?.label == "Wake up" && got?.days == [1, 2, 3, 4, 5, 6, 7] && hm?.hour == 7 && hm?.minute == 30 && got?.end == nil,
              "every day at 7:30 AM, Wake up (\(got?.label ?? "-") \(String(describing: hm)) \(got?.days ?? []))")
        await shot("43-said-wake-every-day")
        got = await say("set an alarm to wake me up at 6:45 every Monday, Wednesday, and Friday for the next month")
        let end = got?.end.map { Calendar.current.dateComponents([.month, .day], from: $0) }
        let expected = Calendar.current.dateComponents([.month, .day], from: Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.date(byAdding: .month, value: 1, to: .now)!)!)
        check(got?.days == [1, 3, 5] && end == expected && clock.nudge?.contains("Mon Wed Fri at 6:45") == true && clock.nudge?.contains("until") == true,
              "Mon Wed Fri for the next month carries its end (\(String(describing: end)), \(clock.nudge ?? "-"))")
        await shot("44-said-mwf-month")
        // Something missing: one question, and the answer completes it.
        let before = lines.count
        hear("remind me to call Ken")
        Voice.shared.toggle(); await wait(0.4); Voice.shared.toggle()
        _ = await until(5) { clock.nudge?.contains("What time") == true }
        check(lines.count == before && clock.nudge?.contains("What time") == true, "it asks instead of guessing (\(clock.nudge ?? "-"))")
        got = await say("at 4 pm")
        check(got?.event == "reminder" && got?.label == "Call Ken" && got?.at.map { Calendar.current.component(.hour, from: $0) } == 16, "the answer completes it (\(got?.label ?? "-"))")
        await open(false)
        let menu = NSMenu()
        StatusMenu.shared.menuNeedsUpdate(menu)
        check(menu.items.contains { $0.title == "Start by Voice" }, "the menu bar has Start by Voice")

        print("Voice: the name prompt")
        hear("northwind")
        // Opened from a run-loop timer, as a menu click would: a modal run inside this task would
        // hold the main queue, and the dictation needs it.
        func later(_ after: Double, _ body: @escaping @MainActor () -> Void) {
            RunLoop.main.add(Timer(timeInterval: after, repeats: false) { _ in MainActor.assumeIsolated(body) }, forMode: .common)
        }
        func clickTalk() {
            // The Talk button: the hosting view in the accessory row (the alert's own buttons are hosting views too).
            guard let w = NSApp.modalWindow, let talk = hostingViews(in: w.contentView!).first(where: { $0.superview is NSStackView }) else { return }
            let c = talk.convert(NSPoint(x: talk.bounds.midX, y: talk.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: c, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { w.sendEvent(e) }
            }
        }
        var asked = false
        later(0.1) { Ask.start(); asked = true }
        later(1.0) { clickTalk() }
        later(1.6) { clickTalk() }
        later(8) { if NSApp.modalWindow != nil { NSApp.abortModal() } } // never hang the check
        _ = await until(10) { asked }
        check(clock.running && clock.project == "northwind", "Talk in the name prompt: said, and it starts (\(clock.session?.project ?? "-"))")
        clock.stop()

        print("Voice: the session editor")
        hear("that was northwind from 9 to 11")
        HistoryTest.frame = { historyFrames[$0] = $1 }
        let h = MacHistory.shared
        // Yesterday's session: "9 to 11" today is still ahead before 11 AM, and the editor never ends a session in the future.
        let day = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: .now))!
        h.period = .week; h.anchor = day
        try? TimeLog.append(TimeEvent("start", at: day.addingTimeInterval(13 * 3600), host: Store.host, project: "billing-fix", source: "named"), to: Store.folder)
        try? TimeLog.append(TimeEvent("stop", at: day.addingTimeInterval(14 * 3600), host: Store.host), to: Store.folder)
        HistoryWindow.show()
        await wait(1)
        await click("session-billing-fix")
        guard let sheet = HistoryWindow.window?.attachedSheet else { check(false, "the editor opens"); return }
        print("  record bar at \(historyFrames["record-bar"].map { "\($0)" } ?? "none")")
        await click("record-bar", in: sheet)
        await wait(0.4)
        await click("record-bar", in: sheet)
        await wait(0.3)
        await windowShot("42-editor-filled", sheet)
        await click("session-save", in: sheet)
        let e = lines.last
        check(e?.event == "edit" && e?.project?.lowercased() == "northwind" && e?.start.map { Calendar.current.component(.hour, from: $0) } == 9
              && e?.end.map { Calendar.current.component(.hour, from: $0) } == 11, "the record bar fills project, start and end; Save writes them (\(e?.event ?? "-") \(e?.project ?? "-") \(String(describing: e?.start)))")
        HistoryWindow.window?.close()
        HistoryTest.frame = nil
    }

    static func hostingViews(in v: NSView) -> [NSView] {
        (String(describing: type(of: v)).contains("HostingView") ? [v] : []) + v.subviews.flatMap { hostingViews(in: $0) }
    }
}
