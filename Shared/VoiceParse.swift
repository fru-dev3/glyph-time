import Foundation
#if canImport(GlyphVault)
import GlyphVault  // Spoken: the words, numbers and clock reading shared with the other apps (in a `swift -` check, cat its file first)
#endif

/// Reads what was said. Two steps, shared by the Mac and the iPhone:
///   1. the sentence into `Slots`: what to do, a short title, and the timing as short phrases
///      ("in 5 minutes", "7:30 am", "next tuesday", "monday wednesday friday", "for the next month").
///      Apple's on-device model fills them (VoiceModel.swift); without it, `slots(_:)` here does,
///      with plain rules.
///   2. `Schedule.resolve` turns the phrases into dates against the clock and calendar, and checks
///      them. The calendar is never left to the model.
enum VoiceForm {
    struct Alarm: Equatable { var hour: Int?; var minute = 0; var days: Set<Int>?; var label: String? }
    struct Session: Equatable { var project: String?; var start: (h: Int, m: Int)?; var end: (h: Int, m: Int)?
        static func == (a: Session, b: Session) -> Bool {
            a.project == b.project && a.start?.h == b.start?.h && a.start?.m == b.start?.m && a.end?.h == b.end?.h && a.end?.m == b.end?.m
        }
    }

    /// What one sentence asks, its timing still in words. The model's answer has the same fields.
    struct Slots: Equatable {
        /// alarm, reminder, timer, stop, pause, resume, or unclear.
        var action = ""
        var title = ""
        /// From now: "5 minutes", "2 hours".
        var after = ""
        /// Time of day: "7:30 am", "noon", "half past 7", "3".
        var time = ""
        /// One day: "tomorrow", "next tuesday", "november 3", "the 15th".
        var day = ""
        /// "every day", "weekdays", "monday wednesday friday", "every other day", "every 2 hours",
        /// "first monday of the month".
        var repeats = ""
        /// "next monday", "tomorrow".
        var starting = ""
        /// "for the next month", "for 2 weeks", "until friday", "until december 15", "this week".
        var ending = ""
        /// Minutes of warning before ("remind me 15 minutes before").
        var lead = 0
        /// A timer's length: "25 minutes".
        var length = ""
        var question = ""
        /// Said with "wake me": an unmarked hour is the morning's.
        var wake = false
        /// For "none": the line said back.
        var reply = ""
        /// A routine's count: "8 times a day" is 8, "3 times a week" 3 with `perWeek`.
        var count = 0
        var perWeek = false
    }

    /// "8 times a day", "twice a week", "once a day": the count and whether it is a week's.
    static func routineCount(_ s: String) -> (count: Int, perWeek: Bool, range: Range<String.Index>)? {
        guard let m = first(#"\b(\d{1,2}|once|twice) ?(?:times? |x )?(?:a|per|each|every) (day|week)\b"#, s) else { return nil }
        let n = m[1] == "once" ? 1 : m[1] == "twice" ? 2 : Int(m[1]) ?? 0
        return n > 0 ? (n, m[2] == "week", m.range) : nil
    }

    // MARK: Cleaning

    static let fillers: Set<String> = ["uh", "uhh", "um", "umm", "uhm", "er", "erm", "ah", "hmm", "hm", "mm", "hey", "ok", "okay",
                                        "please", "glyph", "siri", "actually", "basically", "just", "yeah", "well", "oh"]
    /// Lower case, number words as digits, filler words and punctuation out (GlyphVault `Spoken`).
    static func normalize(_ said: String) -> String { Spoken.normalize(said, dropping: fillers) }

    // MARK: Phrases into numbers

    /// "5 minutes", "an hour", "90 seconds", "1 hour 30 minutes": seconds; nil when it isn't one.
    static func duration(_ phrase: String) -> Int? {
        let s = normalize(phrase)
        var total = 0, found = false
        for m in all(#"\b(\d+|an?|one)\s*(seconds?|secs?|minutes?|mins?|hours?|hrs?|h|m|days?|weeks?)\b"#, s) {
            let n = Int(m[1]) ?? 1
            let u = m[2]
            total += n * (u.hasPrefix("s") ? 1 : u.hasPrefix("m") ? 60 : u.hasPrefix("h") ? 3600 : u.hasPrefix("d") ? 86_400 : 604_800)
            found = true
        }
        if s.contains(" and a half") { total += total >= 3600 ? 1800 : 30 }
        return found && total > 0 ? total : nil
    }

    typealias Clock = Spoken.Clock
    typealias Match = Spoken.Match

    static func clock(_ phrase: String) -> Clock? { clockMatch(normalize(phrase))?.0 }
    static func clockMatch(_ s: String) -> (Clock, Range<String.Index>)? { Spoken.clockMatch(s) }
    static let ordinals = Spoken.ordinals
    static let weekdays = Spoken.weekdays
    static let weekdayPattern = Spoken.weekdayPattern
    static func weekday(_ w: String) -> Int? { Spoken.weekday(w) }
    static let months = Spoken.months
    static let monthPattern = Spoken.monthPattern
    static let ordinalPattern = Spoken.ordinalPattern
    static func ordinal(_ s: String) -> Int? { Spoken.ordinal(s) }
    static func first(_ pattern: String, _ s: String) -> Match? { Spoken.first(pattern, s) }
    static func all(_ pattern: String, _ s: String, limit: Int = .max) -> [Match] { Spoken.all(pattern, s, limit: limit) }
    static func sub(_ s: String, _ pattern: String, _ with: String) -> String { Spoken.sub(s, pattern, with) }

    /// One day, as the start of that day: today, tonight, tomorrow, "in 3 days", "next tuesday",
    /// "november 3", "the 15th", "11/3", "next week" (its Monday). Nil when it isn't one.
    static func day(_ phrase: String, now: Date, cal: Calendar) -> Date? {
        let s = normalize(phrase)
        let today = cal.startOfDay(for: now)
        func add(_ d: Int) -> Date { cal.date(byAdding: .day, value: d, to: today)! }
        if first(#"\b(today|tonight|this (morning|afternoon|evening)|now)\b"#, s) != nil { return today }
        if first(#"\btomorrow\b"#, s) != nil { return add(1) }
        if let m = first(#"\bin (\d+|a|an|one) (days?|weeks?|months?)\b"#, s) {
            let n = Int(m[1]) ?? 1
            if m[2].hasPrefix("month") { return cal.date(byAdding: .month, value: n, to: today) }
            return add(m[2].hasPrefix("week") ? n * 7 : n)
        }
        if first(#"\bnext week\b"#, s) != nil { return nextWeekday(1, from: add(1), cal: cal, strictlyNextWeek: true, today: today) }
        if first(#"\bnext month\b"#, s) != nil { return cal.date(from: cal.dateComponents([.year, .month], from: cal.date(byAdding: .month, value: 1, to: today)!)) }
        if let m = first(#"\b(next |this |coming |on )?("# + weekdayPattern + #")\b"#, s), let wd = weekday(m[2]) {
            // "tuesday" or "this tuesday": the coming one (today counts); "next tuesday": the one after today, a week on if it is today.
            let next = m[1].hasPrefix("next")
            let d = nextWeekday(wd, from: next ? add(1) : today, cal: cal, strictlyNextWeek: false, today: today)
            return d
        }
        func date(_ month: Int, _ dayN: Int) -> Date? {
            let y = cal.component(.year, from: today)
            guard var d = cal.date(from: DateComponents(year: y, month: month, day: dayN)), cal.component(.day, from: d) == dayN else { return nil }
            if d < today { d = cal.date(from: DateComponents(year: y + 1, month: month, day: dayN))! }
            return d
        }
        if let m = first(#"\b("# + monthPattern + #") (?:the )?("# + ordinalPattern + #")\b"#, s), let mo = months[m[1]], let d = ordinal(m[2]) { return date(mo, d) }
        if let m = first(#"\b(?:the )?("# + ordinalPattern + #") (?:of )?("# + monthPattern + #")\b"#, s), let mo = months[m[2]], let d = ordinal(m[1]) { return date(mo, d) }
        if let m = first(#"\b(\d{1,2})/(\d{1,2})\b"#, s), let mo = Int(m[1]), let d = Int(m[2]), (1...12).contains(mo) { return date(mo, d) }
        if let m = first(#"\bthe ("# + ordinalPattern + #")\b"#, s), let d = ordinal(m[1]), (1...31).contains(d) {
            // The 15th: this month's, or next month's once it has passed.
            var c = cal.dateComponents([.year, .month], from: today); c.day = d
            for _ in 0..<3 {
                if let x = cal.date(from: c), cal.component(.day, from: x) == d, x >= today { return x }
                c.month! += 1
            }
        }
        return nil
    }

    /// The first `weekday` (1 Monday ... 7 Sunday) on or after `from`.
    static func nextWeekday(_ wd: Int, from: Date, cal: Calendar, strictlyNextWeek: Bool, today: Date) -> Date {
        var d = from
        for _ in 0..<14 {
            if cal.component(.weekday, from: d) == wd % 7 + 1 { return d }
            d = cal.date(byAdding: .day, value: 1, to: d)!
        }
        return d
    }

    /// How it repeats.
    enum Repeat: Equatable {
        case weekly(Set<Int>)
        case days(Int)
        case hours(Int)
        /// The `n`th `weekday` of each month; -1 the last.
        case monthly(Int, Int)
    }

    static func repeats(_ phrase: String) -> Repeat? {
        let s = normalize(phrase)
        if first(#"\bevery other day\b"#, s) != nil { return .days(2) }
        if let m = first(#"\bevery (\d+) days\b"#, s), let n = Int(m[1]), n > 0 { return n == 1 ? .weekly(Set(1...7)) : .days(n) }
        if first(#"\b(every other hour)\b"#, s) != nil { return .hours(2) }
        if let m = first(#"\bevery (\d+) (hours?|hrs?)\b"#, s), let n = Int(m[1]), n > 0 { return .hours(n) }
        if first(#"\b(every hour|hourly|each hour)\b"#, s) != nil { return .hours(1) }
        if let m = first(#"\b(first|second|third|fourth|last|1th|2th|3th|4th|1|2|3|4) ("# + weekdayPattern + #") of (?:the|every|each|a)? ?month\b"#, s), let wd = weekday(m[2]) {
            let n = m[1] == "last" ? -1 : ordinal(m[1]) ?? 1
            return .monthly(n, wd)
        }
        if first(#"\b(every ?day|daily|each day|every (morning|night|evening|afternoon|single day)|each (morning|night|evening)|7 days a week)\b"#, s) != nil { return .weekly(Set(1...7)) }
        if first(#"\b(week ?days?|work ?days?|during the week|monday (through|to|thru) friday|mon (through|to|thru) fri)\b"#, s) != nil { return .weekly(Set(1...5)) }
        if first(#"\bweekends?\b"#, s) != nil { return .weekly([6, 7]) }
        let names = all(#"\b("# + weekdayPattern + #")\b"#, s).compactMap { weekday($0[1]) }
        if !names.isEmpty { return .weekly(Set(names)) }
        return nil
    }

    /// The last moment a repeat may go off: "for the next month" (a month from `start`, that last
    /// day included), "for 2 weeks", "for 3 days", "until friday", "until december 15", "this week",
    /// "this month"; with an hourly repeat, "until 6 pm" or "for the next 8 hours".
    static func ending(_ phrase: String, start: Date, now: Date, cal: Calendar, hourly: Bool) -> Date? {
        let s = normalize(phrase)
        let base = cal.startOfDay(for: start)
        func endOf(_ d: Date) -> Date { cal.date(byAdding: .second, value: 86_399, to: cal.startOfDay(for: d))! }
        if first(#"\b(this|the|rest of the|current) week\b|\bweek only\b"#, s) != nil {
            var d = base
            while cal.component(.weekday, from: d) != 1 { d = cal.date(byAdding: .day, value: 1, to: d)! } // to Sunday
            return endOf(d)
        }
        if first(#"\b(this|the|rest of the|current) month\b"#, s) != nil {
            let next = cal.date(byAdding: .month, value: 1, to: cal.date(from: cal.dateComponents([.year, .month], from: base))!)!
            return endOf(cal.date(byAdding: .day, value: -1, to: next)!)
        }
        if let m = first(#"\b(?:for )?(?:the )?(?:next |coming |following )?(?:(\d+|a|an|one) )?(hours?|days?|weeks?|months?|years?)\b"#, s) {
            let n = Int(m[1]) ?? 1
            let u = m[2]
            if u.hasPrefix("hour") { return hourly ? start.addingTimeInterval(Double(n) * 3600) : nil }
            let comp: Calendar.Component = u.hasPrefix("day") ? .day : u.hasPrefix("week") ? .weekOfYear : u.hasPrefix("month") ? .month : .year
            // N days covers N days, the first included: the last is the day before start + N.
            return endOf(cal.date(byAdding: .day, value: -1, to: cal.date(byAdding: comp, value: n, to: base)!)!)
        }
        if hourly, let (c, _) = clockMatch(s) {
            var h = c.h
            if !c.marked, h < 12, let at = cal.date(bySettingHour: h, minute: c.m, second: 0, of: start), at <= start { h += 12 }
            return cal.date(bySettingHour: h, minute: c.m, second: 0, of: start)
        }
        if let d = day(s, now: now, cal: cal) { return endOf(d) }
        return nil
    }

    // MARK: Nothing to do

    /// What is meant: the words after the last correction ("remind me at 5, actually at 6" is "at 6"), when
    /// there are enough of them to mean something; else the whole sentence ("call Ken at 5, never mind").
    static func meant(_ said: String) -> String {
        guard let r = said.range(of: #"(?i)\b(actually|no wait|wait no|i mean|scratch that|sorry|never ?mind|forget that)\b"#,
                                 options: [.regularExpression, .backwards]) else { return said }
        let tail = String(said[r.upperBound...])
        return normalize(tail).split(separator: " ").count >= 3 ? tail : said
    }

    /// Said not to do anything ("don't do anything", "just testing", "never mind", "ignore that"): this wins
    /// over every reader, Claude's and Apple's model's too.
    static func declined(_ said: String) -> Bool {
        let s = normalize(said)  // "just" is filler: "this is just a test" reads "this is a test"
        return first(#"\b(do ?n'?t|do not|did ?n'?t|did not|no need to|you don'?t (need|have) to)( want you to| need you to)? (do|set|start|make|create|add|change) (anything|nothing|a thing)\b"#
            + #"|\b(did ?n'?t|did not|never) ask(ed)?( you)? (for|to)\b|\b(this is|it's|its|that was) (only )?a test\b"#
            + #"|^ *(only )?testing\b|\btesting (you|your|this|the app|the mic|the microphone|it|1 2 3)\b"#
            + #"|\bnever ?mind\b|\bignore (that|this|me|it)\b|\bforget (it|that|about it)\b|\bnothing to (do|set)\b"#, s) != nil
    }

    /// A question to the app, not a request ("what time is it in Tokyo", "can you hear me"): nothing is set.
    static func question(_ said: String) -> Bool {
        let s = normalize(said).trimmingCharacters(in: .whitespaces)
        let asks = first(#"^(what|what's|whats|when|where|who|why|how|which|is|are|was|were|do|does|did|can you hear|are you)\b"#, s) != nil
        let sets = first(#"\b(remind|reminder|alarm|timer|wake|set|start|track|focus|countdown|routine)\b"#, s) != nil
        return asks && !sets
    }

    /// Asked plainly for a timer: a timing verb or a length ("start", "time my run", "timer", "track",
    /// "focus on Acme", "I'm working on", "for 25 minutes"). A bare phrase ("Acme deck") never starts one.
    static func asksForTimer(_ said: String) -> Bool {
        let s = normalize(said)
        return first(#"\b(start|starting|begin|timer|timing|countdown|count down|stopwatch|track|tracking|focus|focusing|working on|work on|session|clock in)\b"#
                     + #"|\btime (me|my|this|it|the)\b|\bfor (the next |another )?"# + dur + #"|\b\d+ ?(minute|min|hour|second)s? (timer|countdown|session)\b"#, s) != nil
    }

    /// What any reader's plan (Claude's, Apple's model's, the rules') comes to: nothing when told not to do
    /// anything, a timer only when one was asked for, and another app's job offered to it.
    static func settled(_ plan: Plan, _ said: String) -> Plan {
        let meant = meant(said)
        if declined(meant) { return Plan(kind: .chat, reply: Plan.nothing) }
        var plan = plan
        if plan.kind == .timer, !asksForTimer(meant) { plan = Plan(kind: .chat, reply: Plan.nothing) }
        if plan.kind == .chat, plan.handoff == nil, !question(meant) { plan.handoff = handoff(meant) }
        return plan
    }

    /// Another app's job in what was said to Time, by plain rules: a dream, note or idea for Jot; food,
    /// a symptom, mood or sleep for Well; a person met for CRM; a goal for Omega. Nil when none fits.
    static func handoff(_ said: String) -> Plan.Handoff? {
        let s = normalize(said)
        var text = said.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for lead in [#"(?i)^(please )?(jot down|write down|make a note|note|log|track|remember)( that| this)?[:,]? +"#, #"(?i)^idea[:,]? +"#] {
            if let r = text.range(of: lead, options: .regularExpression) { text = String(text[r.upperBound...]) }
        }
        guard !text.isEmpty else { return nil }
        text = text.prefix(1).uppercased() + text.dropFirst()
        func after(_ p: String) -> String {
            guard let m = first(p, s) else { return "" }
            return cased(m[1].split(separator: " ").prefix(4).joined(separator: " "), from: said)
        }
        if first(#"\b(dream|dreams|dreamed|dreamt|dreaming)\b"#, s) != nil { return .init(agent: "jot", text: text, reason: "A dream to keep", kind: "dream") }
        if first(#"\b(goal|goals|mission|vision|values)\b"#, s) != nil { return .init(agent: "omega", text: text, reason: "A goal for Omega") }
        if first(#"\b(met|meet|meeting|talked|spoke|called) (with |to )?([a-z]+)"#, s) != nil {
            let words = said.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" }).map(String.init)
            var name: [String] = []
            for (i, w) in words.enumerated() where i > 0 && w.first?.isUppercase == true && w != "I" {
                if name.isEmpty || words[i - 1] == name.last { name.append(w) } else { break }
            }
            if !name.isEmpty { return .init(agent: "crm", text: text, reason: "Someone you met", name: name.prefix(3).joined(separator: " ")) }
        }
        let kinds: [(String, String)] = [("symptom", #"\b(headache|migraine|nausea|nauseous|pain|ache|aches|cramps|fever|cough|sore|dizzy|symptom)\b"#),
                                         ("sleep", #"\b(slept|sleep|nap|napped)\b"#),
                                         ("mood", #"\b(feeling|feel|felt|mood) (great|good|bad|sad|happy|low|anxious|tired|down|calm|stressed|amazing|awful)\b"#),
                                         ("food", #"\b(ate|eat|eating|drank|drink|had (a |some )?\w+ for (breakfast|lunch|dinner)|breakfast|lunch|dinner|snack|meal|log [a-z])"#)]
        if let k = kinds.first(where: { first($0.1, s) != nil }) {
            var name = k.0 == "food" ? after(#"\b(?:ate|eating|eat|drank|had|log) (?:some |a |an )?(.+?)(?: for (?:breakfast|lunch|dinner)| today| this morning|$)"#) : ""
            if name.isEmpty { name = k.0 == "symptom" ? cased(first(kinds[0].1, s)?[1] ?? "Symptom", from: said) : k.0 == "sleep" ? "Sleep" : k.0 == "mood" ? "Mood" : text }
            return .init(agent: "well", text: text, reason: k.0 == "food" ? "Food for Well" : k.0 == "symptom" ? "A symptom for Well" : k.0 == "sleep" ? "Sleep for Well" : "Your mood for Well",
                         name: name.prefix(1).uppercased() + name.dropFirst(), kind: k.0)
        }
        if first(#"^ *(jot|write|note|idea|remember)\b|\b(jot down|write down|make a note|note that|an idea)\b"#, s) != nil { return .init(agent: "jot", text: text, reason: "A note to keep") }
        return nil
    }

    // MARK: The sentence into slots, by rule (no model)

    private static let stops = ["stop", "stop the timer", "stop timer", "stop it", "stop tracking", "i'm done", "i am done", "done", "finish",
                                "finished", "end it", "end the timer", "stop the clock"]
    private static let pauses = ["pause", "pause the timer", "pause timer", "pause it", "pause the clock", "hold on", "break", "take a break",
                                 "i'm taking a break", "i am taking a break"]
    private static let resumes = ["resume", "continue", "keep going", "resume the timer", "back to work", "unpause", "i'm back", "i am back"]
    private static let dur = #"(?:\d+|an?|one)\s*(?:seconds?|secs?|minutes?|mins?|hours?|hrs?)(?: and (?:\d+|a half) ?(?:minutes?|mins?)?)?"#

    /// "remind me to take a break in 5 minutes" -> reminder, "Take a break", after "5 minutes".
    static func slots(_ said: String) -> Slots {
        // A correction ("in 10 minutes, actually in 13 minutes"): what follows the last one is what's meant.
        let tail = meant(said)
        if tail != said { return slots(tail) }
        var s = normalize(said)
        var out = Slots()
        if declined(said) || question(said) { out.action = "none"; return out }
        let bare = s.trimmingCharacters(in: .whitespaces)
        if stops.contains(bare) { out.action = "stop"; return out }
        if pauses.contains(bare) { out.action = "pause"; return out }
        if resumes.contains(bare) { out.action = "resume"; return out }
        func take(_ pattern: String, group: Int = 0) -> String? {
            guard let m = first(pattern, s) else { return nil }
            let v = m[group].trimmingCharacters(in: .whitespaces)
            s.replaceSubrange(m.range, with: " ")
            return v
        }
        out.wake = first(#"\b(wake (me )?up|wake me|get me up|wakeup|(get|have) me out of bed)\b"#, s) != nil
        // A routine's count, before the clock reads its number as an hour.
        if let c = routineCount(s) { out.count = c.count; out.perWeek = c.perWeek; s.replaceSubrange(c.range, with: " ") }
        // Warning before: "remind me 15 minutes before", "15 minutes early".
        if let m = first(#"\b(?:and )?(?:remind me |warn me |tell me |give me )?(\d{1,3}) ?(?:minutes?|mins?) (?:before|early|ahead|beforehand|in advance|prior)(?: it)?\b"#, s) {
            out.lead = Int(m[1]) ?? 0
            s.replaceSubrange(m.range, with: " ")
        }
        let hourly = first(#"\b(every \d+ (hours?|hrs?)|every hour|hourly|every other hour)\b"#, s) != nil
        // The end and the start of a repeat.
        let endUnits = hourly ? "hours?|days?|weeks?|months?" : "days?|weeks?|months?|years?"
        if let v = take(#"\bfor (?:the )?(?:next |coming |following )?(?:(?:\d+|a|an|one) )?(?:"# + endUnits + #")\b"#) { out.ending = v }
        else if let v = take(#"\b(?:for |just |only )?(?:this|the rest of the) (?:week|month)(?: only)?\b"#) { out.ending = v }
        else if let v = take(#"\b(?:until|till|til|through|thru|up until|ending|ends) (?:the )?(.+?)(?=\s+(?:at|every|starting|from|and|to|remind)\b|\s*$)"#, group: 1) { out.ending = v }
        if let v = take(#"\b(?:starting|beginning|from|as of|effective)(?: on)? (?!now\b)(.+?)(?=\s+(?:at|every|until|till|for|through|to|and)\b|\s*$)"#, group: 1) { out.starting = v }
        // From now: "in 5 minutes", "in about 10 minutes", "5 minutes from now".
        if let v = take(#"\b(?:in|after|within) (?:about |around |roughly |approximately |like |another |the next )?("# + dur + #")\b"#, group: 1) { out.after = v }
        else if let v = take(#"\b("# + dur + #") from now\b"#, group: 1) { out.after = v }
        // A timer's length: "for the next 10 minutes", "a 25 minute timer", "timer for 5 minutes".
        if let v = take(#"\bfor (?:the next |another |)("# + dur + #")\b"#, group: 1) { out.length = v }
        else if let m = first(#"\b(\d+) ?(minute|min|hour|second)s? (timer|countdown)\b"#, s) { out.length = "\(m[1]) \(m[2])s"; s.replaceSubrange(m.range, with: " \(m[3]) ") }
        // How it repeats.
        let rep = [#"\bevery other (?:day|hour)\b"#, #"\bevery \d+ (?:days|hours?|hrs?)\b"#, #"\b(?:every hour|hourly|each hour)\b"#,
                   #"\b(?:every |on the )?(?:first|second|third|fourth|last|\d{1,2}th) "# + weekdayPattern + #" of (?:the|every|each|a)? ?month\b"#,
                   #"\b(?:every ?day|daily|each day|every (?:morning|night|evening|afternoon|single day)|each (?:morning|night|evening))\b"#,
                   #"\b(?:every |on |during the )?(?:week ?days?|work ?days?)\b|\bduring the week\b"#, #"\b(?:every |on )?weekends?\b"#]
        for p in rep { if let v = take(p) { out.repeats = out.repeats.isEmpty ? v : out.repeats + " " + v } }
        // "every monday wednesday and friday", "mondays", "on monday and wednesday": weekly; a single
        // plain weekday ("on tuesday", "next tuesday") is a day.
        let names = all(#"\b(?:every |each |on )?(?:next |this |coming )?"# + weekdayPattern + #"\b(?:,? (?:and |or |& )?(?:"# + weekdayPattern + #")\b)*"#, s)
        if let m = names.first {
            let list = all(#"\b("# + weekdayPattern + #")\b"#, m[0]).map { $0[1] }
            let weekly = list.count > 1 || m[0].contains("every") || m[0].contains("each") || list.contains { $0.hasSuffix("s") && weekday($0) != nil && $0.count > 4 }
                || !out.ending.isEmpty
            if weekly && out.repeats.isEmpty { out.repeats = list.joined(separator: " ") } else if !weekly { out.day = m[0].trimmingCharacters(in: .whitespaces) }
            if let r = s.range(of: m[0]) { s.replaceSubrange(r, with: " ") }
        }
        // Morning or evening said with "every": the repeat took it; keep it for the time.
        // So is "tonight at 7" or "at 7 ... in the morning" when the two aren't side by side.
        var part = out.repeats.contains("morning") ? " am" : out.repeats.contains("night") || out.repeats.contains("evening") ? " pm" : ""
        if part.isEmpty, first(#"\b(in the morning|this morning)\b"#, s) != nil { part = " am" }
        if part.isEmpty, first(#"\b(tonight|this (?:afternoon|evening)|in the (?:afternoon|evening)|at night)\b"#, s) != nil { part = " pm" }
        // One day.
        if out.day.isEmpty {
            if let v = take(#"\b(?:on )?(?:the )?(?:"# + monthPattern + #" (?:the )?"# + ordinalPattern + #"|"# + ordinalPattern + #" (?:of )?"# + monthPattern + #")\b"#) { out.day = v }
            else if let v = take(#"\bon (?:the )?\d{1,2}th\b|\bthe \d{1,2}th\b|\b\d{1,2}/\d{1,2}\b"#) { out.day = v }
            else if let v = take(#"\b(?:tomorrow|today|in \d+ (?:days?|weeks?)|in a week|next week|next month)\b"#) { out.day = v }
        }
        // Tonight, this evening: the day and the part of it.
        if out.day.isEmpty, first(#"\b(tonight|this (?:morning|afternoon|evening))\b"#, s) != nil { out.day = "today" }
        // The time of day.
        if let (c, r) = clockMatch(s) {
            let t = String(s[r]).trimmingCharacters(in: .whitespaces)
            out.time = t + (c.marked ? "" : part)
            s.replaceSubrange(r, with: " ")
        }
        s = sub(s, #"\b(tonight|this (?:morning|afternoon|evening)|in the (?:morning|afternoon|evening)|at night)\b"#, " ")

        // What to do.
        let low = s
        let timerCue = asksForTimer(low)
        let alarmCue = out.wake || first(#"\b(alarm|alarms)\b"#, low) != nil
        let remindCue = first(#"\b(remind|reminder|reminders|nudge me|ping me|tell me|notify me|alert me|don't let me forget|buzz me)\b"#, low) != nil
        let timing = !out.after.isEmpty || !out.time.isEmpty || !out.day.isEmpty || !out.repeats.isEmpty
        if alarmCue && !(timerCue && !timing && !out.length.isEmpty) { out.action = "alarm" }
        else if timerCue || (!out.length.isEmpty && !timing) { out.action = "timer" }
        // Without a word asking for one, a day alone ("today", "this weekend") is talk; a clock time or a delay is a reminder.
        else if remindCue || !out.time.isEmpty || !out.after.isEmpty { out.action = "reminder" }
        else { out.action = "none" } // talk, a thought, a bare phrase: nothing is set (Fru, 2026-10-30)
        // A habit to keep: said as one ("routine", "habit", "8 times a day"), or a repeat with nothing asking to be told.
        if out.count > 0 || first(#"\b(routine|habit)\b"#, low) != nil
            || (out.action == "reminder" && !remindCue && !out.repeats.isEmpty && out.after.isEmpty)
            || (out.action == "none" && first(#"\b(every|each|daily|weekdays)\b"#, out.repeats) != nil) { // not "about the weekend"
            out.action = "routine"
        }
        if out.action != "timer", out.after.isEmpty, !out.length.isEmpty, out.time.isEmpty, out.day.isEmpty, out.repeats.isEmpty {
            out.after = out.length; out.length = "" // "remind me for 10 minutes": read as in 10 minutes
        }
        if out.action == "timer", out.length.isEmpty, !out.after.isEmpty, out.time.isEmpty { out.length = out.after; out.after = "" }

        // What's left is the title.
        for f in ["set an alarm", "set up an alarm", "set alarm", "set the alarm", "set a reminder", "set reminder", "create an alarm",
                  "create a reminder", "add an alarm", "add a reminder", "make an alarm", "make a reminder", "an alarm", "a reminder", "alarms",
                  "alarm", "reminders", "reminder", "remind me", "remind", "wake me up", "wake me", "wake up", "get me up", "get me out of bed",
                  "have me out of bed", "out of bed", "i need a nudge", "give me a nudge", "a nudge", "nudge me",
                  "ping me", "tell me", "notify me", "alert me", "buzz me", "don't let me forget", "can you", "could you", "would you",
                  "will you", "i need you to", "i want you to", "i'd like you to", "i need to", "i have to", "i want to", "i gotta",
                  "i'm going to be working on", "i'm going to work on", "i am going to work on", "i'm working on", "i am working on",
                  "working on", "work on", "focus on", "focusing on", "time my", "start a timer", "start the timer", "set a timer", "start timing", "start tracking",
                  "a timer", "timer", "countdown", "count down", "start", "so i don't forget", "so i can", "so that i can", "for me",
                  "add a routine", "new routine", "a routine", "routine", "a habit", "habit", "every"] {
            s = sub(s, "\\b" + NSRegularExpression.escapedPattern(for: f) + "\\b", " ")
        }
        let lead: Set<String> = ["to", "about", "that", "me", "at", "on", "for", "in", "and", "the", "of", "i", "i'm", "it", "a", "an", "now",
                                 "let's", "lets", "then", "time", "is", "be", "set", "my", "go", "get", "should", "with", "by", "from", "can",
                                 "around", "before", "after", "something", "you"]
        var words = s.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        while let f = words.first, lead.contains(f) { words.removeFirst() }
        while let l = words.last, lead.contains(l) || Int(l) != nil { words.removeLast() }
        out.title = cased(words.joined(separator: " "), from: said)
        return out
    }

    /// The words with the capitals they were said with, the first letter up.
    static func cased(_ words: String, from said: String) -> String {
        guard !words.isEmpty else { return "" }
        let split = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-")).inverted
        let caps = Dictionary(said.components(separatedBy: split).filter { !$0.isEmpty }.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let joined = words.split(separator: " ").map { caps[String($0)] ?? String($0) }.joined(separator: " ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    // MARK: Forms

    /// "weekdays at 6 AM, stand up" -> 6:00, Monday to Friday, "Stand up" (the alarm sheet's talk bar).
    static func alarm(_ said: String) -> Alarm {
        let sl = slots(said)
        var out = Alarm()
        if let c = clock(sl.time) { out.hour = c.h; out.minute = c.m }
        if case .weekly(let d)? = repeats(sl.repeats) { out.days = d }
        out.label = sl.title.isEmpty ? (sl.wake ? "Wake up" : nil) : sl.title
        return out
    }

    /// "that was Acme from 9 to 11" -> project Acme (matched to a known one), 9:00 to 11:00.
    static func session(_ said: String, known: [String]) -> Session {
        var text = " " + said.lowercased() + " "
        var out = Session()
        let time = #"(?i)\b(\d{1,2})(?::(\d{2}))?\s*(a\.?\s?m\.?|p\.?\s?m\.?)?(?=\W|$)"#
        func matches(_ s: String) -> [(h: Int, m: Int, marked: Bool)] {
            let r = try! NSRegularExpression(pattern: time)
            return r.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
                guard let hr = Range(m.range(at: 1), in: s), var h = Int(s[hr]), h <= 23 else { return nil }
                let mi = Range(m.range(at: 2), in: s).flatMap { Int(s[$0]) } ?? 0
                let ap = Range(m.range(at: 3), in: s).map { s[$0].lowercased().filter(\.isLetter) }
                if ap == "pm", h < 12 { h += 12 }
                if ap == "am", h == 12 { h = 0 }
                return (h, min(59, mi), ap != nil)
            }
        }
        if let r = text.range(of: #"(?i)\b(?:from\s+)?(\d{1,2}(?::\d{2})?\s*(?:a\.?\s?m\.?|p\.?\s?m\.?)?)\s+(?:to|until|till|-)\s+(\d{1,2}(?::\d{2})?\s*(?:a\.?\s?m\.?|p\.?\s?m\.?)?)"#, options: .regularExpression) {
            let times = matches(String(text[r]))
            if times.count >= 2 {
                var a = times[0], b = times[1]
                // Without am or pm: a working-day reading (1 to 6 is afternoon), the end after the start.
                if !a.marked, a.h < 7 { a.h += 12 }
                if !b.marked, b.h + 12 <= 23, b.h < a.h || (b.h == a.h && b.m <= a.m) { b.h += 12 }
                out.start = (a.h, a.m); out.end = (b.h, b.m)
            }
            text.replaceSubrange(r, with: " ")
        } else if let r = text.range(of: time, options: .regularExpression), let t = matches(String(text[r])).first {
            out.start = (t.h, t.m)
            text.replaceSubrange(r, with: " ")
        }
        let drop: Set<String> = ["that", "was", "it", "this", "is", "i", "worked", "working", "on", "for", "the", "session", "at", "from", "project", "today"]
        var words = text.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-")).inverted).filter { !$0.isEmpty }
        while let f = words.first, drop.contains(f) { words.removeFirst() }
        while let l = words.last, drop.contains(l) { words.removeLast() }
        if !words.isEmpty {
            let w = words.joined(separator: " ")
            let said = cased(w, from: said)
            out.project = known.first { $0.lowercased() == w } ?? known.first { $0.lowercased().contains(w) || w.contains($0.lowercased()) } ?? said
        }
        return out
    }

}
