import CryptoKit
import Foundation

/// Filed documents' deadlines, rung by Time (GlyphCore's filer writes them into each document's
/// note; Time reads them with `Filing.index()`): one reminder each, 7 days before at 09:00, or on the
/// day at 09:00 when that has passed, for dates in the next 90 days. The id names the document, the
/// kind and the date, so each is rung once and a moved date is a new one.
enum FiledReminders {
    struct Item: Equatable { var id: String; var at: Date; var label: String }

    static func plan(_ deadlines: [(id: String, title: String, kind: String, date: String)], now: Date, rung: Set<String> = []) -> [Item] {
        let cal = Calendar.current
        let parse = DateFormatter()
        parse.calendar = cal; parse.locale = Locale(identifier: "en_US_POSIX"); parse.timeZone = .current; parse.dateFormat = "yyyy-MM-dd"
        let show = DateFormatter()
        show.dateFormat = "EEE MMM d"; show.locale = Locale(identifier: "en_US_POSIX")
        return deadlines.compactMap { d in
            guard let day = parse.date(from: d.date), day >= cal.startOfDay(for: now), day.timeIntervalSince(now) <= 90 * 86_400 else { return nil }
            let id = "filing-\(d.id)-\(d.kind)-\(d.date)"
            guard !rung.contains(id) else { return nil }
            let nine = { (x: Date) in cal.date(bySettingHour: 9, minute: 0, second: 0, of: x)! }
            let early = nine(cal.date(byAdding: .day, value: -7, to: day)!)
            guard let at = [early, nine(day)].first(where: { $0 > now }) else { return nil }
            let verb = ["due": "Due", "expires": "Expires", "renews": "Renews"][d.kind] ?? d.kind.capitalized
            return Item(id: id, at: at, label: "\(verb) \(show.string(from: day)): \(d.title)")
        }
        .sorted { $0.at < $1.at }
    }
}

extension FiledReminders {
    /// The deadlines in the vault's Expiring list (`data/domains/records/memory/expiring.md`, made by
    /// GlyphCore's filer), for the iPhone, which has no vault: "- 2026-11-15 due: [Title](<path>)".
    /// The id is a short hash of the note's path, so each deadline is rung once on this device.
    static func parseExpiring(_ text: String) -> [(id: String, title: String, kind: String, date: String)] {
        let re = try! NSRegularExpression(pattern: #"^- (\d{4}-\d{2}-\d{2}) (due|expires|renews): \[(.+)\]\(<(.+)>\)$"#)
        return text.split(separator: "\n").compactMap { sub in
            let line = String(sub), ns = line as NSString
            guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
            let g = (1...4).map { ns.substring(with: m.range(at: $0)) }
            let id = SHA256.hash(data: Data(g[3].utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
            return (id: id, title: g[2], kind: g[1], date: g[0])
        }
    }
}
