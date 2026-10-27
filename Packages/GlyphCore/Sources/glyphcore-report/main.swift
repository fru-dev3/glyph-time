// Prints what GlyphCore reads from a vault as JSON, the same shape as Memosa's
// `cargo run --example vault_report`, so the two readers can be compared:
// glyphcore-report <vault> [search phrase...]
import Foundation
import GlyphVault

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: glyphcore-report <vault> [search phrase...]\n".utf8))
    exit(1)
}
let vault = Vault(root: URL(fileURLWithPath: args[1]))
let any = { (v: Any?) -> Any in v ?? NSNull() }
let conversations: [[String: Any]] = vault.conversations().map { c in
    let n = vault.notes(c.id)
    return [
        "id": c.id, "title": c.title, "created": c.created, "duration_sec": c.durationSec,
        "people": c.people, "accounts": c.accounts, "tags": c.tags,
        "summary": n.summary, "decisions": n.decisions.count,
        "actions": n.actions.map { ["text": $0.text, "done": $0.done, "owner": any($0.owner), "due": any($0.due)] },
        "segments": vault.transcript(c.id).segments.count,
    ]
}
let dir = vault.directory()
let report: [String: Any] = [
    "conversations": conversations,
    "entities": dir.entities.map { ["kind": $0.entity.kind.rawValue, "name": $0.entity.name, "aliases": $0.entity.aliases, "account": any($0.entity.account), "count": $0.count] },
    "tags": dir.tags.map { ["name": $0.name, "count": $0.count] },
    "searches": args.dropFirst(2).map { ["query": $0, "hits": vault.search($0)] },
]
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
