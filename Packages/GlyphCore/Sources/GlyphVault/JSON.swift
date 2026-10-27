import Foundation

/// JSON written the way Memosa's serde_json writes it (`to_string_pretty`): two-space
/// indent, `"key": value`, keys in field order, `12.0` for whole seconds, `/` and
/// non-ASCII left as they are, no newline at the end. Foundation's JSONEncoder differs
/// on every one of those, and a file both apps write must not churn in git diffs.
enum JSON {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSON])
    case object([(String, JSON)])

    var pretty: String {
        var out = ""
        write(&out, indent: "")
        return out
    }

    private func write(_ out: inout String, indent: String) {
        switch self {
        case .string(let s): out += JSON.quote(s)
        case .int(let i): out += String(i)
        case .double(let d): out += JSON.number(d)
        case .bool(let b): out += b ? "true" : "false"
        case .null: out += "null"
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (i, item) in items.enumerated() {
                out += indent + "  "
                item.write(&out, indent: indent + "  ")
                out += i < items.count - 1 ? ",\n" : "\n"
            }
            out += indent + "]"
        case .object(let pairs):
            guard !pairs.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (i, (key, value)) in pairs.enumerated() {
                out += indent + "  " + JSON.quote(key) + ": "
                value.write(&out, indent: indent + "  ")
                out += i < pairs.count - 1 ? ",\n" : "\n"
            }
            out += indent + "}"
        }
    }

    /// Rust prints a whole f64 as `12.0` and otherwise the shortest round-trip form, as Swift does.
    static func number(_ d: Double) -> String {
        guard d.isFinite else { return "null" }
        if d == d.rounded(), abs(d) < 1e16 { return String(Int64(d)) + ".0" }
        return String(d)
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }
}

extension Conversation {
    /// `meta.json` as written to disk.
    var json: JSON {
        var pairs: [(String, JSON)] = [
            ("schema", .int(schema)), ("id", .string(id)), ("title", .string(title)), ("created", .string(created)),
            ("duration_sec", .int(durationSec)),
            ("people", .array(people.map(JSON.string))), ("accounts", .array(accounts.map(JSON.string))),
            ("tags", .array(tags.map(JSON.string))),
        ]
        // Studio links only when there are some, so older files keep every byte.
        if !links.isEmpty { pairs.append(("links", .array(links.map(JSON.string)))) }
        if !suggested.isEmpty {
            pairs.append(("suggested", .object((suggested.links.isEmpty ? [] : [("links", .array(suggested.links.map(JSON.string)))]) + [
                ("people", .array(suggested.people.map(JSON.string))),
                ("accounts", .array(suggested.accounts.map(JSON.string))),
                ("tags", .array(suggested.tags.map(JSON.string))),
                ("dismissed", .array(suggested.dismissed.map(JSON.string))),
            ])))
        }
        pairs.append(("source", .string(source)))
        if let device { pairs.append(("device", .string(device))) }
        if let calendarEventId { pairs.append(("calendar_event_id", .string(calendarEventId))) }
        pairs.append(("audio", .string(audio)))
        if let updated { pairs.append(("updated", .string(updated))) }
        if !jots.isEmpty {
            pairs.append(("jots", .array(jots.map { j in
                var p: [(String, JSON)] = [("start", .double(j.start)), ("end", .double(j.end)), ("kind", .string(j.kind))]
                if let note = j.note { p.append(("note", .string(note))) }
                return .object(p)
            })))
        }
        return .object(pairs)
    }
}

extension Transcript {
    /// `transcript.json` as written to disk. Speakers sort by id, like Rust's BTreeMap.
    var json: JSON {
        .object([
            ("schema", .int(schema)), ("language", .string(language)), ("model", .string(model)),
            ("speakers", .object(speakers.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) })),
            ("segments", .array(segments.map { s in
                .object([("start", .double(s.start)), ("end", .double(s.end)), ("speaker", .string(s.speaker)), ("text", .string(s.text))])
            })),
        ])
    }
}
