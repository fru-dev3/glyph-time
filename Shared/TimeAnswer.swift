import Foundation
#if canImport(GlyphVault)
import GlyphVault
#endif

/// Chat questions about Time's own data, answered exactly in code (Fru, 2026-10-30: the chat answers, not only acts):
/// how much today, yesterday or this week, on a project, and the next alarm or reminder. Anything else that reads
/// as a question goes to Glyph Core Intelligence with `context` (decision d-mvvc6oj6-j4gnju: one Claude brain, no
/// on-device reasoning). nil from `reply` means "not one of mine".
enum TimeAnswer {
    static let askWords: Set<String> = ["what", "whats", "what's", "how", "hows", "how's", "when", "whens", "when's", "which",
                                        "who", "why", "where", "did", "do", "does", "am", "is", "are", "was", "were", "have",
                                        "has", "tell", "show", "give", "summarize", "summarise", "list", "any", "should", "and"]

    /// A question rather than something to do ("can you remind me" is an action, so "can" is not here).
    static func isQuestion(_ said: String) -> Bool {
        let s = said.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasSuffix("?") { return true }
        let first = s.split(whereSeparator: { !$0.isLetter && $0 != "'" }).first.map(String.init) ?? ""
        return askWords.contains(first)
    }

    static func reply(_ said: String, sessions: [TimeSession], upcoming: [TimeEvent], now: Date = .now, calendar: Calendar = .current) -> String? {
        let s = said.lowercased()
        guard isQuestion(said) else { return nil }
        if s.contains("next alarm") || s.contains("next reminder") || s.contains("alarm set") || s.contains("alarms set")
            || s.contains("when is my alarm") || s.contains("when's my alarm") {
            let want = s.contains("reminder") && !s.contains("alarm") ? "reminder" : s.contains("alarm") && !s.contains("reminder") ? "alarm" : nil
            guard let (e, at) = next(upcoming.filter { want == nil || $0.event == want }, now: now) else {
                return want == "reminder" ? "No reminders set" : "No alarms set"
            }
            let name = e.label?.isEmpty == false ? e.label! : (e.event == "alarm" ? "Alarm" : "Reminder")
            let when = calendar.isDate(at, inSameDayAs: now) ? at.formatted(date: .omitted, time: .shortened)
                : at.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            return "\(name) · \(when)"
        }
        let asksTotal = ["how much", "how long", "how many hours", "how many minutes", "total", "spent", "tracked", "time did i", "time have i", "time on", "worked"]
        guard asksTotal.contains(where: s.contains) else { return nil }
        if ["month", "last week", "year", "since", "average"].contains(where: s.contains) { return nil } // the hub's
        var cal = calendar
        cal.firstWeekday = 2 // as TimeLog.summary: weeks start on Monday
        let today = cal.startOfDay(for: now)
        let (title, from, to): (String, Date, Date) =
            s.contains("week") ? ("This week", cal.dateInterval(of: .weekOfYear, for: now)?.start ?? today, now.addingTimeInterval(1))
            : s.contains("yesterday") ? ("Yesterday", cal.date(byAdding: .day, value: -1, to: today)!, today)
            : ("Today", today, now.addingTimeInterval(1))
        let totals = TimeLog.totals(sessions, from: from, to: to, now: now)
        let projects = Set(sessions.compactMap(\.project).filter { !$0.isEmpty })
        if let p = projects.filter({ s.contains($0.lowercased()) }).max(by: { $0.count < $1.count }) {
            let secs = totals.first { $0.project == p }?.seconds ?? 0
            return "\(p) · \(title.lowercased()) · \(secs > 0 ? TimeLog.span(secs) : "nothing")"
        }
        let all = totals.reduce(0) { $0 + $1.seconds }
        guard all > 0 else { return "\(title) · nothing tracked" }
        return (["\(title) · \(TimeLog.span(all))"] + totals.prefix(3).map { "\($0.project) · \(TimeLog.span($0.seconds))" })
            .joined(separator: "\n")
    }

    /// What Glyph Core Intelligence gets beside a question: the week by project and the next few alarms and reminders.
    static func context(sessions: [TimeSession], upcoming: [TimeEvent], now: Date = .now) -> String {
        var lines = ["Glyph Time data (exact, use it to answer):", TimeLog.summary(sessions, now: now)]
        let soon = upcoming.compactMap { e in e.at.flatMap { Schedule.next(at: $0, days: e.days, rule: e.rule, until: e.end, after: now) }.map { (e, $0) } }
            .sorted { $0.1 < $1.1 }.prefix(5)
        lines.append(soon.isEmpty ? "No alarms or reminders set." :
            "Next: " + soon.map { "\($0.0.event) \($0.0.label ?? "") \($0.1.formatted(.dateTime.weekday(.abbreviated).hour().minute()))" }.joined(separator: "; "))
        return lines.joined(separator: "\n")
    }

    static func next(_ upcoming: [TimeEvent], now: Date) -> (TimeEvent, Date)? {
        upcoming.filter { $0.on != false }
            .compactMap { e in e.at.flatMap { Schedule.next(at: $0, days: e.days, rule: e.rule, until: e.end, after: now) }.map { (e, $0) } }
            .min { $0.1 < $1.1 }
    }
}
