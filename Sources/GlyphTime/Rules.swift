import Foundation

enum Style: String, CaseIterable {
    case formal, casual, veryCasual

    var name: String {
        switch self {
        case .formal: "Formal"
        case .casual: "Casual"
        case .veryCasual: "Very casual"
        }
    }

    var example: String {
        switch self {
        case .formal: "Hey, are you free for lunch tomorrow? Let's do 12."
        case .casual: "Hey, are you free for lunch tomorrow? Let's do 12"
        case .veryCasual: "hey are you free for lunch tomorrow? let's do 12"
        }
    }
}

/// The plain-text rules, kept free of the app so they can be checked alone:
/// `cat Mac/Rules.swift Mac/RulesCheck.swift | swift -`
enum Rules {
    /// "first line new line second" -> two lines. "new paragraph" -> a blank line between.
    static func spokenBreaks(_ text: String) -> String {
        var s = text
        for (said, gap) in [("new paragraph", "\n\n"), ("new line", "\n")] {
            s = s.replacingOccurrences(of: ",?\\s*\\b\(said)\\b[,.;]?\\s*", with: gap,
                                       options: [.regularExpression, .caseInsensitive])
        }
        // Capitalize the first letter of each new line.
        let lines = s.components(separatedBy: "\n").map { line in
            line.first.map { $0.uppercased() + line.dropFirst() } ?? line
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The AI pass costs half a second or more, so it runs only where rules can't do the job:
    /// a correction ("no wait") or a spoken list. On plain speech it only added mistakes.
    static func wantsAI(_ text: String) -> Bool {
        let lower = text.lowercased()
        // ponytail: the on-device model is slow on long text (a few seconds per 100 words), so a
        // long dictation keeps the rule-based cleanup only. Raise it if the model gets faster.
        guard lower.split(separator: " ").count <= 300 else { return false }
        if cues(text) > 0 { return true }
        return lower.range(of: "\\bone\\b.*\\btwo\\b", options: .regularExpression) != nil
    }

    /// Small models sometimes answer the question instead of typing it, or wander off.
    /// Keep the cleaned text only if it's still the speaker's words.
    static func accept(raw: String, cleaned: String) -> Bool {
        let c = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return false }
        // A correction pass that left every "no wait" in place didn't correct anything (or half did).
        if cues(raw) > 0, cues(c) >= cues(raw) { return false }
        let ratio = Double(c.count) / Double(max(raw.count, 1))
        guard ratio > 0.4, ratio < 1.3 else { return false }
        if raw.contains("?"), !c.contains("?") { return false }
        let said = Set(words(raw))
        let new = words(c).filter { !said.contains($0) && Int($0) == nil }
        return Double(new.count) <= Double(max(words(c).count, 1)) * 0.15
    }

    /// How many times the speaker changed their mind ("no wait", "actually", "make that").
    static func cues(_ text: String) -> Int {
        let lower = text.lowercased()
        return ["no wait", "wait no", "actually", "i mean", "scratch that", "never mind", "or rather", "make that", "sorry,"]
            .reduce(0) { $0 + lower.components(separatedBy: $1).count - 1 }
    }

    // MARK: Terminals and code (Category.code)

    /// Spoken symbols, for terminals and editors: "dash dash no dash verify" -> "--no-verify",
    /// "scripts slash ship dot sh" -> "scripts/ship.sh", "file underscore name" -> "file_name".
    private static let little = "the|a|an|in|on|of|to|and|or|is|are|was|this|that|with|for|at|by|from|as|it|my|your|its|be|each|every|some|any|per|then|than"

    static func codeSpeak(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\\b(?:dash|hyphen)[\\s,]+(?:dash|hyphen)[\\s,]+", with: "--",
                                          options: [.regularExpression, .caseInsensitive])
        for (said, symbol) in [("dash|hyphen", "-"), ("dot", "."), ("slash", "/"), ("underscore", "_")] {
            var before = ""
            while before != s { // "a dash b dash c" overlaps, so repeat until nothing changes
                before = s
                // Never next to a little word: "the dash in the title" is prose, not a name.
                let pattern = "\\b(?!(?:\(little))\\b)([\\w./~-]+)[\\s,]+(?:\(said))[\\s,]+(?!(?:\(little))\\b)(?=[\\w-])"
                s = s.replacingOccurrences(of: pattern, with: "$1\(symbol)", options: [.regularExpression, .caseInsensitive])
            }
        }
        s = s.replacingOccurrences(of: "\\btilde\\s*/", with: "~/", options: [.regularExpression, .caseInsensitive])
        // Speech hears "git commit" as "get commit".
        return s.replacingOccurrences(of: "\\bget\\s+(commit|push|pull|status|checkout|switch|add|diff|log|stash|rebase|merge|clone|fetch|reset|branch|tag)\\b",
                                      with: "git $1", options: [.regularExpression, .caseInsensitive])
    }

    /// "... press enter" at the very end (or "send it" in a terminal) presses Return after pasting.
    static func splitEnter(_ text: String, code: Bool) -> (text: String, enter: Bool) {
        var cues = "(?:press|hit)\\s+(?:enter|return)"
        if code { cues += "|(?:and\\s+)?send(?:\\s+it)?" }
        let pattern = "[\\s,.;]*\\b(?:\(cues))[.!]?\\s*$"
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return (text, false) }
        return (String(text[..<range.lowerBound]), true)
    }

    // MARK: Which project (History)

    private static let editorsFileFirst: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
                                                        "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf"]
    private static let editorsProjectFirst: Set<String> = ["com.apple.dt.Xcode", "dev.zed.Zed"]
    private static let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
                                                 "dev.warp.Warp-Stable", "net.kovidgoyal.kitty"]
    private static let chats: Set<String> = ["com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex"]
    static let projectApps = editorsFileFirst.union(editorsProjectFirst).union(terminals).union(chats)

    /// The project or repo a terminal, editor or AI app window is on, from its title (and the
    /// file or folder it shows, `AXDocument`). Best effort, nil if unknown. Editors read
    /// "Rules.swift \u{2014} acme-api" (Xcode and Zed the other way round), terminals show the
    /// folder ("acme-api \u{2014} -zsh \u{2014} 80x24", "sam@laptop:~/code/acme-api"), AI apps
    /// "acme-api \u{2014} Codex". `user` is the home folder's name: a shell at home is no project.
    static func project(title: String, document: String? = nil, bundle: String, app: String, user: String = "") -> String? {
        guard projectApps.contains(bundle) else { return nil }
        func clean(_ s: String?) -> String? {
            guard var s = s?.trimmingCharacters(in: .whitespaces) else { return nil }
            for suffix in [".xcodeproj", ".xcworkspace", ".code-workspace"] where s.hasSuffix(suffix) { s.removeLast(suffix.count) }
            return s.isEmpty || s == "~" || s == user || s.count > 60 ? nil : s
        }
        // A folder (a terminal's cwd) or an Xcode project; an open file says nothing.
        if let document, let url = URL(string: document), url.isFileURL,
           document.hasSuffix("/") || [".xcodeproj/", ".xcworkspace/"].contains(where: document.hasSuffix) {
            if let name = clean(url.lastPathComponent) { return name }
        }
        // "sam@laptop:~/code/acme-api", "~/code/acme-api": the path's last folder.
        if terminals.contains(bundle) || chats.contains(bundle),
           let range = title.range(of: "(?<=^|[\\s:])~?/[^\\s:()\\[\\]]*", options: .regularExpression) {
            return clean(title[range].split(separator: "/").last.map(String.init))
        }
        // "\u{25CF} Rules.swift \u{2014} acme-api [SSH: box] \u{2014} Visual Studio Code" -> the parts that matter.
        let bare = title.replacingOccurrences(of: "\\s*[\\[(][^\\])]*[\\])]\\s*", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "^[\u{25CF}\u{2022}*]\\s*", with: "", options: .regularExpression)
        let names: Set<String> = [app, "Visual Studio Code", "Cursor", "Windsurf", "Zed", "Xcode", "Claude", "ChatGPT", "Codex"]
        let all = bare.components(separatedBy: " \u{2014} ").flatMap { $0.components(separatedBy: " - ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let parts = all.filter { !names.contains($0) }
        let looksLikeFile = { (s: String) in s.range(of: "\\.[A-Za-z0-9]{1,6}$", options: .regularExpression) != nil }
        if editorsFileFirst.contains(bundle) {
            guard let last = parts.last, parts.count > 1 || !looksLikeFile(last) else { return nil }
            return clean(last)
        }
        if editorsProjectFirst.contains(bundle) { return clean(parts.first) }
        // Terminal names the folder first; an AI app only when its own name is in the title too.
        if bundle == "com.apple.Terminal", parts.count > 1, let first = parts.first, !first.hasPrefix("-") { return clean(first) }
        if chats.contains(bundle), parts.count < all.count, parts.count == 1 { return clean(parts.first) }
        return nil
    }

    // MARK: Forms

    /// "Fill the form, name Sam, city Austin" -> "name Sam, city Austin". Nil for plain dictation.
    static func formRequest(_ text: String) -> String? {
        let pattern = "^\\s*(?:please\\s+)?fill\\s+(?:in\\s+|out\\s+)?(?:the\\s+|this\\s+)?form\\b[\\s,.:;]*"
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let rest = String(text[range.upperBound...])
        return rest.isEmpty ? nil : rest
    }

    // MARK: Learning your words

    /// A misheard name, one or two letters off ("Quilo", "Zentro"), becomes the name from your
    /// dictionary. Real words are left alone (`isWord`), so "quill" never turns into "Quillo".
    static func fuzzyNames(_ text: String, names: [String], isWord: (String) -> Bool = { _ in false }) -> String {
        let names = names.filter { $0.count >= 5 && !$0.contains(" ") }
        guard !names.isEmpty, let regex = try? NSRegularExpression(pattern: "\\b[\\p{L}][\\p{L}']*\\b") else { return text }
        var out = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let word = String(text[range]), lower = word.lowercased()
            let hit = names.first { name in
                let n = name.lowercased()
                return n != lower && n.first == lower.first && abs(n.count - lower.count) <= 2
                    && distance(n, lower) <= (n.count >= 8 ? 2 : 1)
            }
            if let hit, !isWord(word) { out.replaceSubrange(range, with: hit) }
        }
        return out
    }

    /// What you fixed by hand after Jot pasted: `pasted` was typed into a field that now reads
    /// `field`. If exactly one word of it changed into a similar word, that's a misheard word
    /// to learn ("harbor" -> "Harbr"). Anything bigger is an edit, not a correction.
    static func correction(pasted: String, field: String) -> (heard: String, write: String)? {
        func tokens(_ s: String) -> [String] {
            s.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
        }
        let p = tokens(pasted), f = tokens(String(field.suffix(5000)))
        guard p.count >= 3, f.count >= p.count, !field.contains(pasted) else { return nil }
        for start in stride(from: f.count - p.count, through: 0, by: -1) {
            let window = f[start..<start + p.count]
            let diffs = zip(p, window).filter { $0 != $1 }
            guard diffs.count == 1, let (old, new) = diffs.first else { continue }
            let o = old.lowercased(), n = new.lowercased()
            // A respelling keeps most letters (or at least the first); "Friday" -> "Monday" is a new word.
            let d = distance(o, n), longer = max(o.count, n.count)
            guard new.count >= 3, d <= max(1, longer / 3) || (o.first == n.first && d * 2 <= longer) else { continue }
            return (old, new)
        }
        return nil
    }

    /// Levenshtein edit distance.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]
            row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[b.count]
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Casual drops the closing period; very casual also starts lowercase, as people text.
    /// Names keep their capital ("Quillo", "I").
    static func style(_ text: String, _ style: Style, names: [String] = []) -> String {
        guard style != .formal, !text.contains("\n") else { return text } // lists and paragraphs stay as written
        var s = text
        if s.hasSuffix("."), !s.hasSuffix("..") { s.removeLast() }
        let first = String(s.prefix { $0.isLetter || $0 == "'" })
        if style == .veryCasual, first != "I", !first.hasPrefix("I'"), !names.contains(first) {
            s = s.prefix(1).lowercased() + s.dropFirst()
        }
        return s
    }
}
