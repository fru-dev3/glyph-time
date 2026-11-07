import Foundation
#if os(macOS)
import FoundationModels
#endif

/// Claude reads a sentence (`claudePlan`, Glyph Core Intelligence through the hub) and the rules in
/// VoiceParse.swift read it when Claude can't be reached; `Schedule.resolve` works out and checks the
/// dates either way.
///
/// Apple's on-device model is not a reader here (Fru, 2026-10-30, d-mvvc6oj6-j4gnju: one entry-point
/// intelligence powered by Claude; Apple's model transcribes, it never reasons and it is never the
/// fallback). What is left of it below is compiled for the Mac app only, which still falls back to it
/// (`Time/Sources/GlyphTime`, Fru's call); the iPhone cannot reach it at all.
#if os(macOS)
extension VoiceForm {
    @Generable
    struct Heard {
        @Guide(description: "alarm (to wake up or ring loudly), reminder (to be told to do something), timer (only when asked to start or track time, or a countdown), routine (a habit to keep and check off, e.g. every weekday walk at 7, drink water 8 times a day), stop, pause, resume, unclear, or none (talk, a test, a question, or nothing asked)", .anyOf(["alarm", "reminder", "timer", "routine", "stop", "pause", "resume", "unclear", "none"]))
        var action: String
        @Guide(description: "A short title, 1 to 4 words, what it is for, e.g. Take a break, Wake up, Call Ken, Acme deck. Never filler (uh, um, hey), never a time or a day. Leave out if none was said.")
        var title: String?
        @Guide(description: "Only for a delay from now, e.g. 5 minutes, 2 hours, as said after in. Leave out otherwise.")
        var after: String?
        @Guide(description: "The time of day as said, e.g. 7:30 am, 3 pm, 3, noon, half past 7, quarter to 9, 7 in the morning. Leave out if none.")
        var time: String?
        @Guide(description: "A single day it happens on, as said, e.g. today, tonight, tomorrow, next tuesday, november 3, the 15th. Leave out if it repeats or none was said.")
        var day: String?
        @Guide(description: "How it repeats, as said, e.g. every day, weekdays, weekends, monday wednesday friday, every other day, every 2 hours, first monday of the month. Leave out if it happens once.")
        var repeats: String?
        @Guide(description: "When a repeat begins if said, e.g. next monday, tomorrow. Leave out otherwise.")
        var starting: String?
        @Guide(description: "When a repeat stops if said, e.g. for the next month, for 2 weeks, for 3 days, until friday, until december 15, this week only, until 6 pm. Leave out otherwise.")
        var ending: String?
        @Guide(description: "Minutes of warning before it, from e.g. remind me 15 minutes before. Leave out if none.")
        var lead: Int?
        @Guide(description: "For a timer only: its length, e.g. 25 minutes. Leave out otherwise.")
        var length: String?
        @Guide(description: "Only when action is unclear: one short question to ask back. Leave out otherwise.")
        var question: String?
    }

    static var modelReady: Bool { SystemLanguageModel.default.availability == .available }

    static let modelInstructions = """
    You read one sentence someone said to a time app on their phone and fill in what it asks. \
    Copy timing words as they were said; never work out dates yourself. Leave out filler words \
    (uh, um, hey, okay) and leave a field empty when the sentence doesn't say it. \
    "Remind me to X" is a reminder titled X. "Wake me up" is an alarm titled Wake up. \
    "I'm working on X" or "start a timer for X" is a timer titled X. Talk, a test, a question, or anything \
    that asks for nothing is none; never make up a request.
    """

    /// The model's reading, or nil without the model. Every phrase must be in the sentence and read
    /// by the code (`Schedule`): the small model tends to fill fields with things never said
    /// ("now", "once", today's weekday), and those are dropped.
    static func modelSlots(_ said: String, now: Date = .now, cal: Calendar = .current, preferences: String = "") async -> Slots? {
        guard modelReady else { return nil }
        var f = Date.FormatStyle().weekday(.wide).month(.wide).day().year().hour().minute(); f.timeZone = cal.timeZone
        let session = LanguageModelSession(instructions: modelInstructions + (preferences.isEmpty ? ""
            : "\nThe person's preferences, followed where they fit (never a reason to act):\n" + preferences))
        let prompt = "Now: \(now.formatted(f)), time zone \(cal.timeZone.identifier). Use it only to understand the sentence.\nSentence: \(said)"
        guard let h = try? await session.respond(to: prompt, generating: Heard.self, options: GenerationOptions(sampling: .greedy)).content else { return nil }
        var s = Slots(action: h.action)
        s.title = h.title ?? ""; s.after = h.after ?? ""; s.length = h.length ?? ""; s.time = h.time ?? ""; s.day = h.day ?? ""
        s.repeats = h.repeats ?? ""; s.starting = h.starting ?? ""; s.ending = h.ending ?? ""; s.lead = h.lead ?? 0; s.question = h.question ?? ""
        return grounded(s, said, now: now, cal: cal)
    }
}
#endif

extension VoiceForm {
    /// A reader's slots, each phrase kept only when it is in the sentence and the code can read it.
    static func grounded(_ raw: Slots, _ said: String, now: Date, cal: Calendar) -> Slots {
        let heard = Set(normalize(said).split(whereSeparator: { $0 == " " || $0 == ":" }).map(String.init))
        func keep(_ p: String?, _ valid: (String) -> Bool) -> String {
            guard let p, !p.isEmpty else { return "" }
            let words = normalize(p).split(whereSeparator: { $0 == " " || $0 == ":" }).map(String.init)
            let none: Set<String> = ["none", "once", "now", "0", "n/a", "never", "nil", "null"]
            guard !words.isEmpty, !words.allSatisfy(none.contains), words.allSatisfy(heard.contains), valid(p) else { return "" }
            return p
        }
        var s = Slots(action: raw.action)
        s.title = keep(raw.title) { _ in true }
        s.after = keep(raw.after) { duration($0) != nil }
        s.length = keep(raw.length) { duration($0) != nil }
        s.time = keep(raw.time) { clock($0) != nil }
        s.day = keep(raw.day) { day($0, now: now, cal: cal) != nil }
        s.repeats = keep(raw.repeats) { repeats($0) != nil }
        s.starting = keep(raw.starting) { day($0, now: now, cal: cal) != nil }
        s.ending = keep(raw.ending) { ending($0, start: now, now: now, cal: cal, hourly: true) != nil }
        s.lead = max(0, raw.lead)
        if s.lead > 0, !heard.contains(String(s.lead)) { s.lead = 0 }
        s.question = raw.question
        s.reply = raw.reply
        s.wake = first(#"\b(wake (me )?up|wake me|get me up)\b"#, normalize(said)) != nil
        if let c = routineCount(normalize(said)) { s.count = c.count; s.perWeek = c.perWeek }
        return s
    }

    /// Claude's reading, through the hub's POST /understand (the hub's local Claude
    /// proxy). Nil when the hub is away, slow or can't reach Claude; then the rules read it (`read`). Every
    /// phrase must be in the sentence (`grounded`), and the dates are worked out and checked here.
    static func claudePlan(_ said: String, hub: URL, recent: [String], now: Date, cal: Calendar, preferences: String = "") async -> Plan? {
        struct Answer: Decodable {
            struct Suggest: Decodable { var agent: String; var text: String; var reason: String?; var name: String?; var kind: String? }
            var kind: String; var title, after, time, day, repeats, starting, ending, length, question, reply: String?
            var lead: Int?; var suggest: [Suggest]?
        }
        let f = ISO8601DateFormatter(); f.timeZone = cal.timeZone
        f.formatOptions = [.withInternetDateTime]
        var r = URLRequest(url: hub.appending(path: "understand"), timeoutInterval: claudeWait)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["app": "time", "text": said, "now": f.string(from: now), "tz": cal.timeZone.identifier, "recent": recent]
        if !preferences.isEmpty { body["preferences"] = preferences }  // Omega's lines for Time, when there are some
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let a = try? JSONDecoder().decode(Answer.self, from: d) else { return nil }
        var s = Slots(action: a.kind)
        s.title = a.title ?? ""; s.after = a.after ?? ""; s.time = a.time ?? ""; s.day = a.day ?? ""; s.repeats = a.repeats ?? ""
        s.starting = a.starting ?? ""; s.ending = a.ending ?? ""; s.length = a.length ?? ""; s.lead = a.lead ?? 0
        s.question = a.question ?? ""; s.reply = a.reply ?? ""
        guard var p = Schedule.resolve(grounded(s, said, now: now, cal: cal), now: now, cal: cal) else { return nil }
        // A handoff is kept only when it is the person's words (most of them), as Glyph Native checks its jobs.
        if p.kind == .chat, let g = a.suggest?.first, ["jot", "well", "crm", "omega"].contains(g.agent) {
            let heard = Set(normalize(said).split(separator: " ")), words = normalize(g.text).split(separator: " ")
            if !words.isEmpty, Double(words.filter(heard.contains).count) / Double(words.count) >= 0.8 {
                p.handoff = .init(agent: g.agent, text: g.text, reason: g.reason ?? "", name: g.name ?? "", kind: g.kind ?? "")
            }
        }
        return p
    }

    /// How long the phone waits for Claude: the proxy starts the claude CLI for each sentence (about 5 s).
    static let claudeWait: TimeInterval = 10

    /// One sentence to a plan. Said not to do anything: nothing, always. With a hub, Claude reads it
    /// (`claudePlan`); without one, or when that call fails, the rules read it: exact and instant
    /// (stop, pause, resume, a time they can work out, the one question they still need answered).
    /// Nothing guesses. A sentence the rules can't read while the hub is away comes back nil, and the
    /// words wait with a calm note instead (`TimeKeeper.perform`), to be said again when Glyph answers
    /// (Fru, 2026-10-30, d-mvvc6oj6-j4gnju).
    ///
    /// Whoever read it, a timer starts only when one was asked for, and what belongs to another app is
    /// offered to it (`handoff`).
    static func read(_ said: String, now: Date = .now, cal: Calendar = .current, hub: URL? = nil, recent: [String] = [],
                     preferences: String = "") async -> Plan? {
        if declined(meant(said)) { return Plan(kind: .chat, reply: Plan.nothing) }
        let rules = Schedule.resolve(slots(said), now: now, cal: cal)
        // "stop", "pause", "I'm back": the rules know these exactly, at once, hub or no hub.
        if let r = rules, [.stop, .pause, .resume].contains(r.kind) { return r }
        if let hub, let c = await claudePlan(said, hub: hub, recent: recent, now: now, cal: cal, preferences: preferences) { return settled(c, said) }
        // Offline: what the rules read is done; talk, a question and anything they can't make out waits.
        if let r = rules {
            let p = settled(r, said)
            if p.kind != .chat { return p }
        }
        return nil
    }

#if os(macOS)
    /// The Mac app's reading (`Time/Sources/GlyphTime`): `read`, and Apple's on-device model behind it when
    /// the rules can't make a sentence out, as it has been. The iPhone never comes here; whether the Mac
    /// keeps that fallback is Fru's call.
    static func understand(_ said: String, now: Date = .now, cal: Calendar = .current, hub: URL? = nil, recent: [String] = [],
                           preferences: String = "") async -> Plan {
        if let p = await read(said, now: now, cal: cal, hub: hub, recent: recent, preferences: preferences) { return p }
        return settled(await onDevice(said, now: now, cal: cal, preferences: preferences), said)
    }

    /// The rules, then Apple's model: no network. The Mac's last resort only.
    static func onDevice(_ said: String, now: Date, cal: Calendar, preferences: String = "") async -> Plan {
        let rules = Schedule.resolve(slots(said), now: now, cal: cal)
        // A question from the rules (a time missing) is asked, never guessed by the model.
        if let r = rules, r.kind == .ask || r.title.split(separator: " ").count <= 5 { return r }
        if let m = await modelSlots(said, now: now, cal: cal, preferences: preferences), let p = Schedule.resolve(m, now: now, cal: cal), p.kind != .ask || rules == nil {
            return p
        }
        return rules ?? Plan(kind: .ask, question: "Sorry, say that again?")
    }
#endif
}
