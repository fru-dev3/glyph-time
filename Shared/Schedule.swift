import Foundation

/// What a sentence comes to, its dates worked out and checked: start a timer, stop, pause, resume,
/// set an alarm or a reminder (once, or repeating, maybe from a day and until a day), ask, or nothing
/// (`chat`: a test, a question, talk; only `reply` is said back, maybe with a handoff to another app).
struct Plan: Equatable {
    enum Kind: String { case alarm, reminder, timer, stop, pause, resume, ask, chat, routine }
    var kind: Kind
    /// The alarm's or reminder's label, or the timer's project ("" for none).
    var title = ""
    /// A timer's countdown, minutes.
    var countdown: Int?
    /// When it first goes off.
    var first: Date?
    /// Weekly on these days, 1 Monday ... 7 Sunday.
    var days: [Int] = []
    /// Any other repeat, as `Schedule.rule` writes it ("d2", "h2", "m1.1"); a routine's count, "x8" a day or "w3" a week.
    var rule: String?
    /// Said with a start ("starting next Monday"): the day it begins.
    var from: Date?
    /// The last moment it may go off ("for the next month", "until Friday").
    var until: Date?
    /// Minutes of warning, a second reminder before it.
    var lead: Int?
    /// For `.ask`: the one short question.
    var question: String?
    /// For `.chat`: the one line said back ("Got it. Nothing to set.", or a short answer).
    var reply: String?
    /// For `.chat`: what belongs to another app's agent ("I dreamed about flying" for Jot), offered with Save.
    var handoff: Handoff?

    /// Another app's job, found in what was said to this one: `agent` jot, well, crm or omega.
    struct Handoff: Equatable { var agent: String; var text: String; var reason = ""; var name = ""; var kind = "" }

    static let nothing = "Got it. Nothing to set."
}

enum Schedule {
    /// Slots (from the model or the rules) into a plan, against `now`. Nil when the words don't
    /// add up to anything that can be set; `.ask` when one thing is missing.
    static func resolve(_ s: VoiceForm.Slots, now: Date, cal: Calendar = .current) -> Plan? {
        let action = s.action.lowercased().trimmingCharacters(in: .whitespaces)
        let title = clean(s.title)
        switch action {
        case "stop": return Plan(kind: .stop)
        case "pause": return Plan(kind: .pause)
        case "resume": return Plan(kind: .resume)
        case "timer", "start", "countdown":
            let secs = VoiceForm.duration(s.length.isEmpty ? s.after : s.length)
            if !(s.length.isEmpty && s.after.isEmpty), secs == nil { return nil }
            return Plan(kind: .timer, title: title, countdown: secs.map { max(1, Int((Double($0) / 60).rounded())) })
        case "alarm", "reminder": break
        case "routine": return routine(s, title: title, now: now, cal: cal)
        case "unclear", "ask": return Plan(kind: .ask, question: s.question.isEmpty ? "What should I set?" : s.question)
        case "none", "chat": return Plan(kind: .chat, reply: s.reply.isEmpty ? Plan.nothing : s.reply)
        default: return nil
        }
        // "Remind me to take a break in 5 minutes" is an alarm (Fru: "set an alarm to alarm in 5
        // minutes"): it rings through silent mode, a notification may pass unseen.
        let kind: Plan.Kind = action == "alarm" || (!s.after.isEmpty && s.repeats.isEmpty) ? .alarm : .reminder
        var plan = Plan(kind: kind, title: title.isEmpty ? (s.wake ? "Wake up" : kind == .alarm ? "Alarm" : "Reminder") : title)
        plan.lead = s.lead > 0 && s.lead < 24 * 60 ? s.lead : nil
        func ask(_ q: String) -> Plan { Plan(kind: .ask, question: q) }

        // In 5 minutes: one time, from now.
        if !s.after.isEmpty && s.repeats.isEmpty {
            guard let secs = VoiceForm.duration(s.after), secs > 0, secs <= 366 * 86_400 else { return nil }
            plan.first = now.addingTimeInterval(Double(secs))
            return plan
        }
        let today = cal.startOfDay(for: now)
        // An end without a repeat ("at 7 this week only"): every day until then.
        let rep = s.repeats.isEmpty ? (s.ending.isEmpty ? nil : .weekly(Set(1...7))) : VoiceForm.repeats(s.repeats)
        if !s.repeats.isEmpty, rep == nil { return nil }
        let day = s.day.isEmpty ? nil : VoiceForm.day(s.day, now: now, cal: cal)
        if !s.day.isEmpty, day == nil { return nil }
        let start = s.starting.isEmpty ? nil : VoiceForm.day(s.starting, now: now, cal: cal)
        if !s.starting.isEmpty, start == nil { return nil }
        plan.from = start
        let clock = s.time.isEmpty ? nil : VoiceForm.clock(s.time)
        if !s.time.isEmpty, clock == nil { return nil }

        // Every N hours: from the time said (else N hours from now), until the end said, else the end of that day.
        if case .hours(let n)? = rep {
            guard (1...12).contains(n) else { return nil }
            let base = start ?? day ?? today
            var first = now.addingTimeInterval(Double(n) * 3600)
            if let c = clock, let t = at(base, pick(c, on: base, now: now, wake: s.wake, repeating: false, cal: cal), cal) { first = t }
            if !s.after.isEmpty, let secs = VoiceForm.duration(s.after) { first = now.addingTimeInterval(Double(secs)) }
            let end = s.ending.isEmpty ? cal.date(byAdding: .second, value: 86_399, to: cal.startOfDay(for: first))!
                : VoiceForm.ending(s.ending, start: max(now, first.addingTimeInterval(-1)), now: now, cal: cal, hourly: true)
            guard let end, end >= first, first > now else { return nil }
            plan.first = first; plan.rule = "h\(n)"; plan.until = end
            return plan
        }
        guard let c = clock else {
            return ask(kind == .alarm ? "What time should it ring?" : "What time should I remind you?")
        }
        let base = start ?? day ?? today
        let hm = pick(c, on: base, now: now, wake: s.wake, repeating: rep != nil, cal: cal)

        switch rep {
        case .weekly(let set)?:
            guard !set.isEmpty, set.allSatisfy({ (1...7).contains($0) }) else { return nil }
            plan.days = set.sorted()
        case .days(let n)?:
            guard (2...31).contains(n) else { return nil }
            plan.rule = "d\(n)"
        case .monthly(let o, let wd)?:
            guard [-1, 1, 2, 3, 4, 5].contains(o), (1...7).contains(wd) else { return nil }
            plan.rule = "m\(o).\(wd)"
        case .hours?: return nil
        case nil:
            // Once: on the day said, else the next time that hour comes round.
            guard var t = at(base, hm, cal) else { return nil }
            // Passed already today ("3 PM today" at 10 PM): the next one, tomorrow, and it says so.
            if t <= now {
                guard day == nil || cal.isDate(day!, inSameDayAs: now), start == nil else { return ask("That time has passed. When should it be?") }
                t = cal.date(byAdding: .day, value: 1, to: t)!
            }
            plan.first = t
            if let lead = plan.lead, t.addingTimeInterval(-Double(lead) * 60) <= now { plan.lead = nil }
            return plan
        }
        // A repeat: its first time on or after the start, then its end.
        let anchor = at(base, hm, cal)!
        plan.first = fires(first: anchor, days: plan.days, rule: plan.rule, until: nil, after: now, limit: 1, cal: cal).first
        if !s.ending.isEmpty {
            guard let end = VoiceForm.ending(s.ending, start: start ?? today, now: now, cal: cal, hourly: false) else { return nil }
            plan.until = end
        }
        guard let f = plan.first, f > now, plan.until.map({ $0 >= f }) ?? true else {
            return plan.first == nil ? nil : ask("Nothing falls in that time. When should it be?")
        }
        return plan
    }

    /// A habit to check off: its days (none is every day), its count, and the time of day if one was said
    /// (`first`, its next time, when a nudge is set).
    static func routine(_ s: VoiceForm.Slots, title: String, now: Date, cal: Calendar) -> Plan? {
        guard !title.isEmpty else { return Plan(kind: .ask, question: "What is the routine?") }
        var plan = Plan(kind: .routine, title: title)
        if !s.repeats.isEmpty {
            guard case .weekly(let set)? = VoiceForm.repeats(s.repeats), !set.isEmpty else { return nil }
            plan.days = set.count == 7 ? [] : set.sorted()
        }
        if s.count > 1 || s.perWeek { plan.rule = (s.perWeek ? "w" : "x") + String(s.count) }
        if !s.time.isEmpty {
            guard let c = VoiceForm.clock(s.time) else { return nil }
            let hm = pick(c, on: cal.startOfDay(for: now), now: now, wake: s.wake, repeating: true, cal: cal)
            guard let anchor = at(cal.startOfDay(for: now), hm, cal) else { return nil }
            plan.first = fires(first: anchor, days: plan.days, rule: nil, until: nil, after: now, limit: 1, cal: cal).first
        }
        return plan
    }

    /// "weekdays 7:00 AM", "8 a day", "3 a week": a routine's when.
    static func routineText(_ p: Plan, cal: Calendar) -> String {
        var parts: [String] = []
        if let r = p.rule, r.hasPrefix("w") { parts.append("\(r.dropFirst()) a week") } else {
            if !p.days.isEmpty || p.rule == nil { parts.append(p.days.isEmpty ? "every day" : daysText(p.days)) }
            if let r = p.rule, r.hasPrefix("x") { parts.append("\(r.dropFirst()) a day") }
        }
        if let f = p.first { parts.append(timeText(f, cal)) }
        return parts.joined(separator: " ")
    }

    /// The hour to use: as said when marked (am, pm, noon, 19:00); "wake me at 7" is 7 in the
    /// morning; once today, the next one of 7 and 19 to come; on a later day or repeating, 1 to 6
    /// is the afternoon and 7 to 11 the morning.
    static func pick(_ c: VoiceForm.Clock, on day: Date, now: Date, wake: Bool, repeating: Bool, cal: Calendar) -> (Int, Int) {
        if c.marked || c.h >= 12 || c.h == 0 { return (c.h, c.m) }
        if wake { return (c.h, c.m) }
        if !repeating, cal.isDate(day, inSameDayAs: now) {
            if let t = at(day, (c.h, c.m), cal), t > now { return (c.h, c.m) }
            return (c.h + 12, c.m)
        }
        return c.h <= 6 ? (c.h + 12, c.m) : (c.h, c.m)
    }

    static func at(_ day: Date, _ hm: (Int, Int), _ cal: Calendar) -> Date? {
        cal.date(bySettingHour: hm.0, minute: hm.1, second: 0, of: day)
    }

    /// Every time it goes off after `after`, soonest first, at most `limit`, from `first` on (its
    /// hour and minute are every time's; a weekly or monthly repeat need not fall on its day).
    static func fires(first: Date, days: [Int], rule: String?, until: Date?, after: Date, limit: Int,
                      cal: Calendar = .current) -> [Date] {
        var out: [Date] = []
        let hm = (cal.component(.hour, from: first), cal.component(.minute, from: first))
        func keep(_ d: Date) -> Bool { // false once past the end
            if let until, d > until { return false }
            if d > after, d >= first { out.append(d) }
            return true
        }
        if let rule, rule.hasPrefix("h"), let n = Int(rule.dropFirst()) {
            var d = first
            for _ in 0..<2000 where out.count < limit { if !keep(d) { break }; d = d.addingTimeInterval(Double(n) * 3600) }
        } else if let rule, rule.hasPrefix("d"), let n = Int(rule.dropFirst()) {
            var d = first
            for _ in 0..<2000 where out.count < limit {
                if !keep(d) { break }
                d = at(cal.date(byAdding: .day, value: n, to: cal.startOfDay(for: d))!, hm, cal)!
            }
        } else if let rule, rule.hasPrefix("m") {
            let p = rule.dropFirst().split(separator: ".").compactMap { Int($0) }
            guard p.count == 2 else { return [] }
            var month = cal.date(from: cal.dateComponents([.year, .month], from: first))!
            for _ in 0..<240 where out.count < limit {
                if let d = nth(p[0], weekday: p[1], in: month, cal: cal).flatMap({ at($0, hm, cal) }) { if !keep(d) { break } }
                month = cal.date(byAdding: .month, value: 1, to: month)!
            }
        } else if !days.isEmpty {
            var day = cal.startOfDay(for: first)
            for _ in 0..<3000 where out.count < limit {
                let wd = (cal.component(.weekday, from: day) + 5) % 7 + 1 // Calendar's 1 Sunday -> 7, 2 Monday -> 1
                if days.contains(wd), let d = at(day, hm, cal) { if !keep(d) { break } }
                else if let until, day > until { break }
                day = cal.date(byAdding: .day, value: 1, to: day)!
            }
        } else if first > after, until.map({ first <= $0 }) ?? true {
            out = [first]
        }
        return out
    }

    /// The `n`th `weekday` (1 Monday ... 7 Sunday) of the month starting `month`; -1 the last.
    static func nth(_ n: Int, weekday: Int, in month: Date, cal: Calendar) -> Date? {
        let count = cal.range(of: .day, in: .month, for: month)!.count
        let hits = (0..<count).map { cal.date(byAdding: .day, value: $0, to: month)! }
            .filter { (cal.component(.weekday, from: $0) + 5) % 7 + 1 == weekday }
        return n == -1 ? hits.last : n >= 1 && n <= hits.count ? hits[n - 1] : nil
    }

    /// The next time an alarm or reminder line goes off after `now`; nil once it never will again.
    static func next(at: Date, days: [Int]?, rule: String?, until: Date?, after now: Date = .now, cal: Calendar = .current) -> Date? {
        let d = days ?? []
        if d.isEmpty && rule == nil { return at > now && (until.map { at <= $0 } ?? true) ? at : nil }
        return fires(first: at, days: d, rule: rule, until: until, after: now, limit: 1, cal: cal).first
    }

    // MARK: Saying it back

    /// "Mon Wed Fri at 7:30 AM, until Nov 27", "today at 9:17 AM, in 5 min", "every other day at 8:00 AM".
    static func describe(first: Date, days: [Int], rule: String?, from: Date? = nil, until: Date?, now: Date = .now, cal: Calendar = .current) -> String {
        let time = timeText(first, cal)
        var parts: [String] = []
        if let rule, rule.hasPrefix("h"), let n = Int(rule.dropFirst()) {
            parts.append((n == 1 ? "every hour" : "every \(n) hours") + " from \(time) \(dayText(first, now: now, cal: cal))")
            if let until { parts.append("until \(timeText(until, cal))" + (cal.isDate(until, inSameDayAs: first) ? "" : " \(dayText(until, now: now, cal: cal))")) }
            return parts.joined(separator: ", ")
        }
        if rule != nil || !days.isEmpty {
            parts.append("\(repeatText(days: days, rule: rule)) at \(time)")
        } else {
            let mins = Int((first.timeIntervalSince(now) / 60).rounded())
            parts.append("\(dayText(first, now: now, cal: cal)) at \(time)")
            if mins > 0 && mins < 120 { parts.append("in \(mins) min") }
            return parts.joined(separator: ", ")
        }
        if let from, from > cal.startOfDay(for: now) { parts.append("starting \(shortDate(from, cal))") }
        else if cal.startOfDay(for: first) > cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))! { parts.append("first \(shortDate(first, cal))") }
        if let until { parts.append("until \(shortDate(until, cal))") }
        return parts.joined(separator: ", ")
    }

    /// How it repeats, in a few words: "every other day", "every 2 hours", "first Monday of each month", "Mon Wed Fri"; "" for once.
    static func repeatText(days: [Int], rule: String?) -> String {
        guard let rule else { return days.isEmpty ? "" : daysText(days) }
        let n = Int(rule.dropFirst()) ?? 0
        if rule.hasPrefix("h") { return n == 1 ? "every hour" : "every \(n) hours" }
        if rule.hasPrefix("d") { return n == 2 ? "every other day" : "every \(n) days" }
        let p = rule.dropFirst().split(separator: ".").compactMap { Int($0) }
        guard p.count == 2, (-1...5).contains(p[0]), (1...7).contains(p[1]) else { return "" }
        return "\(["last", "", "first", "second", "third", "fourth", "fifth"][p[0] + 1]) \(weekdayName(p[1])) of each month"
    }

    static func daysText(_ days: [Int]) -> String {
        let d = Set(days)
        if d.count == 7 { return "every day" }
        if d == [1, 2, 3, 4, 5] { return "weekdays" }
        if d == [6, 7] { return "weekends" }
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return d.sorted().map { names[$0 - 1] }.joined(separator: " ")
    }

    static func weekdayName(_ d: Int) -> String { ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][d - 1] }

    static func timeText(_ d: Date, _ cal: Calendar) -> String {
        var f = Date.FormatStyle(date: .omitted, time: .shortened); f.timeZone = cal.timeZone
        return d.formatted(f)
    }

    static func shortDate(_ d: Date, _ cal: Calendar) -> String {
        var f = Date.FormatStyle().month(.abbreviated).day(); f.timeZone = cal.timeZone
        return d.formatted(f)
    }

    static func dayText(_ d: Date, now: Date, cal: Calendar) -> String {
        if cal.isDate(d, inSameDayAs: now) { return "today" }
        if cal.isDate(d, inSameDayAs: cal.date(byAdding: .day, value: 1, to: now)!) { return "tomorrow" }
        var f = Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day(); f.timeZone = cal.timeZone
        return d.formatted(f)
    }

    /// The title as it should read: filler and timing words gone, short, first letter up.
    static func clean(_ title: String) -> String {
        // "Wake up and go to the gym": the gym is what it's for (the kind shows as the icon).
        var n = VoiceForm.normalize(title)
        if let r = n.range(of: #"^\s*(wake (me )?up|get (me )?up) and "#, options: .regularExpression) { n.removeSubrange(r) }
        var words = n.split(separator: " ").map(String.init)
        let edge: Set<String> = ["to", "about", "that", "me", "at", "on", "for", "in", "and", "the", "of", "i", "a", "an", "now", "then", "my", "is", "go"]
        while let f = words.first, edge.contains(f) { words.removeFirst() }
        while let l = words.last, edge.contains(l) { words.removeLast() }
        let s = VoiceForm.cased(words.prefix(6).joined(separator: " "), from: title)
        return s
    }

    /// The chat's one line, title first, never wrapping: "Call Ken · Sat 8:00 AM", "Wake up · 7:00 AM",
    /// "Acme · 25 min"; the kind stands in for a missing title. The rest (`say`) shows on a tap.
    static func short(_ p: Plan, now: Date = .now, cal: Calendar = .current) -> String {
        switch p.kind {
        case .timer:
            guard let m = p.countdown else { return p.title.isEmpty ? "Timer · Running" : p.title }
            return (p.title.isEmpty ? "Timer" : p.title) + " · \(m) min"
        case .alarm, .reminder:
            let kind = p.title.isEmpty ? (p.kind == .alarm ? "Alarm" : "Reminder") : p.title
            guard let f = p.first else { return kind }
            var day = ""
            if p.rule == nil, !p.days.isEmpty {
                let d = daysText(p.days)
                day = p.days.count == 1 || !d.contains(" ") || d == "every day" ? d.prefix(1).uppercased() + d.dropFirst() : "Weekly"
            } else if !cal.isDate(f, inSameDayAs: now) {
                var w = Date.FormatStyle().weekday(.abbreviated); w.timeZone = cal.timeZone
                day = f.timeIntervalSince(now) < 6 * 86_400 ? f.formatted(w) : shortDate(f, cal)
            }
            return "\(kind) · " + (day.isEmpty ? "" : day + " ") + timeText(f, cal)
        case .routine: return "\(p.title) · " + routineText(p, cal: cal)
        default: return say(p, now: now, cal: cal)
        }
    }

    /// What the confirmation line says: "Alarm: Wake up, Mon Wed Fri at 7:30 AM, until Nov 27".
    static func say(_ p: Plan, now: Date = .now, cal: Calendar = .current) -> String {
        switch p.kind {
        case .stop: return "Stopped"
        case .pause: return "Paused"
        case .resume: return "Going again"
        case .ask: return p.question ?? "Say that again?"
        case .chat: return p.reply ?? Plan.nothing
        case .routine: return "Routine: \(p.title), " + routineText(p, cal: cal)
        case .timer: return "Timer: \(p.title.isEmpty ? "Unnamed" : p.title)" + (p.countdown.map { ", \($0) min, a reminder at the end" } ?? "")
        case .alarm, .reminder:
            guard let f = p.first else { return p.title }
            return "\(p.kind == .alarm ? "Alarm" : "Reminder"): \(p.title), "
                + describe(first: f, days: p.days, rule: p.rule, from: p.from, until: p.until, now: now, cal: cal)
                + (p.lead.map { ", and \($0) min before" } ?? "")
        }
    }
}
