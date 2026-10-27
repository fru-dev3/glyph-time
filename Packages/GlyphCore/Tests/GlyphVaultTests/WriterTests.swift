import Foundation
import Testing
@testable import GlyphVault

let pinned = Date(timeIntervalSince1970: 1_792_000_000) // 2026-10-14T17:46:40Z, a fixed `updated`

/// An empty vault in a temp folder, or a copy of the fixture vault.
func scratchVault(copyFixture: Bool = false) throws -> Vault {
    let dir = FileManager.default.temporaryDirectory.appending(path: "glyph-vault-\(UUID().uuidString)")
    if copyFixture {
        try FileManager.default.copyItem(at: fixture.root, to: dir)
    } else {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return Vault(root: dir, now: { pinned })
}

func read(_ v: Vault, _ rel: String) throws -> String { try String(contentsOf: v.url(rel), encoding: .utf8) }

@Test func slugsAreDatedKebabAndNeverCollide() throws {
    #expect(Vault.slug("Acme Insurance review", created: "2026-06-17T11:02:00Z") == "2026-06-17-acme-insurance-review")
    #expect(Vault.slug("  Q4: pricing / renewal!! ", created: "2026-06-17T11:02:00Z") == "2026-06-17-q4-pricing-renewal")
    #expect(Vault.slug("Café über", created: "2026-06-17T11:02:00Z") == "2026-06-17-café-über")
    #expect(Vault.slug("???", created: "2026-06-17T11:02:00Z") == "2026-06-17")
    #expect(Vault.slug("x", created: "") == "undated-x")

    let v = try scratchVault()
    let at = try Date("2026-10-20T15:00:00Z", strategy: .iso8601)
    let ids = try (0..<3).map { _ in try v.createConversation(in: "Work/Acme", title: "Weekly sync", created: at).id }
    #expect(ids == ["Work/Acme/2026-10-20-weekly-sync", "Work/Acme/2026-10-20-weekly-sync-2", "Work/Acme/2026-10-20-weekly-sync-3"])
    #expect(try v.conversation(ids[0]).created == "2026-10-20T15:00:00Z")
    #expect(v.conversations(in: "Work/Acme").count == 3)
    #expect(try v.createConversation(in: "", title: "Loose", created: at).id == "2026-10-20-loose", "the vault root is a folder too")
}

@Test func writtenFilesReadBackWithTheReader() throws {
    let v = try scratchVault()
    let id = try v.createConversation(in: "Work", title: "Standup", created: try Date("2026-06-18T09:30:00Z", strategy: .iso8601)).id
    let t = Transcript(language: "en", model: "apple-speech", speakers: ["S1": "Kim Park"], segments: [
        .init(start: 12, end: 15.5, speaker: "S1", text: " hello world "),
        .init(start: 75, end: 80, text: "second line"),
    ])
    try v.writeTranscript(t, for: id)
    #expect(v.transcript(id) == t)
    #expect(try read(v, id + "/transcript.txt") == "[00:12] Kim Park: hello world\n[01:15] second line\n")
    #expect(try v.conversation(id).updated == Vault.iso(pinned), "a transcript write stamps updated")

    let notes = Notes(summary: "We met.", decisions: ["Ship it"], actions: [
        ActionItem(text: "Send the deck", owner: "Sam Lee", due: "2026-06-20"),
        ActionItem(text: "Book a room", done: true),
    ])
    try v.writeNotes(notes, for: id)
    let back = v.notes(id)
    #expect(back.summary == notes.summary && back.decisions == notes.decisions && back.actions == notes.actions)

    #expect(try v.setTask(id, text: "Send the deck", done: true))
    #expect(v.notes(id).actions.map(\.done) == [true, true])
    #expect(try read(v, id + "/notes.md").contains("- [x] Send the deck  <!-- owner: Sam Lee; due: 2026-06-20 -->"))
    #expect(try v.setTask(id, text: "Book a room", done: false))
    #expect(try !v.setTask(id, text: "Not a task", done: true))
    #expect(v.tasks().map(\.item.done) == [true, false])

    let tmp = try FileManager.default.contentsOfDirectory(atPath: v.url(id).path).filter { $0.hasSuffix(".tmp") }
    #expect(tmp.isEmpty, "atomic writes leave no temp files")
}

@Test func renameMoveTrashAndNoEscape() throws {
    let v = try scratchVault()
    let at = try Date("2026-06-17T10:00:00Z", strategy: .iso8601)
    let id = try v.createConversation(in: "Work", title: "Kickoff", created: at).id
    let renamed = try v.rename(id, title: "Northwind kickoff")
    #expect(renamed == "Work/2026-06-17-northwind-kickoff")
    #expect(try v.conversation(renamed).title == "Northwind kickoff")
    #expect(try v.conversation(renamed).id == renamed)
    #expect(try v.rename(renamed, title: "Northwind Kickoff") == renamed, "case-only rename keeps the folder")
    #expect(try v.conversation(renamed).title == "Northwind Kickoff")

    #expect(v.url("../../etc") == v.root.appending(path: "etc"))
    #expect(throws: VaultError.self) { try v.createFolder("..") }
    #expect(throws: VaultError.self) { try v.trash("..") }
    #expect(throws: VaultError.self) { try v.trash("Work") }

    try v.trash(renamed)
    let again = try v.createConversation(in: "Work", title: "Northwind kickoff", created: at).id
    #expect(again == renamed)
    try v.trash(again)
    let bin = try FileManager.default.contentsOfDirectory(atPath: v.url(".memosa/trash").path).sorted()
    #expect(bin == ["Work__2026-06-17-northwind-kickoff", "Work__2026-06-17-northwind-kickoff-2"])
    #expect(v.conversations().isEmpty, "trash is not in the tree")

    let a = try v.createConversation(in: "A", title: "Same", created: at).id
    let b = try v.createConversation(in: "B", title: "Same", created: at).id
    #expect(throws: VaultError.self) { try v.move(a, to: "B") }
    #expect(try v.move(b, to: "B") == b)
    let moved = try v.move(a, to: "C/Deep")
    #expect(moved == "C/Deep/2026-06-17-same")
    #expect(try v.conversation(moved).id == moved)
    #expect(v.conversations(in: "A").isEmpty)
    try v.createFolder("Home/Empty")
    #expect(v.tree().first { $0.name == "Home" }?.children.first?.kind == .folder)
}

@Test func linksCanonicalizeAndCreateStubNotes() throws {
    let v = try scratchVault(copyFixture: true)
    let id = "Work/Acme/2026-10-20-weekly-sync"
    let meta = try v.setLinks(id, people: ["sammy", "Kim Park", "kim park", " Pat Doe "], accounts: ["acme"], tags: ["#Q4 Renewal", "Pricing", "pricing", "  "])
    #expect(meta.people == ["Sam Lee", "Kim Park", "Pat Doe"])
    #expect(meta.accounts == ["Acme Corp"])
    #expect(meta.tags == ["q4-renewal", "pricing"])
    #expect(meta.suggested.people.isEmpty, "Kim Park is linked now, so no longer suggested")
    #expect(meta.suggested.dismissed == ["Globex"])
    #expect(try read(v, "People/Pat Doe.md") == "---\nkind: person\n---\n\n")
    #expect(try v.conversation(id) == meta)
    #expect(v.conversations(linkedTo: .tag("Q4-RENEWAL")).map(\.id) == [id])
    #expect(v.conversations(linkedTo: .person("Pat Doe")).map(\.id) == [id])
}

@Test func suggestionsAreAnsweredAndDismissalsRemembered() throws {
    let v = try scratchVault(copyFixture: true)
    let id = "Work/Acme/2026-10-20-weekly-sync"
    var meta = try v.answerSuggestion(id, .person("kim park"), accept: true)
    #expect(meta.people == ["Sam Lee", "Kim Park"])
    #expect(meta.suggested.people.isEmpty)
    meta = try v.answerSuggestion(id, .tag("q4"), accept: false)
    #expect(meta.suggested.tags.isEmpty && meta.suggested.dismissed == ["Globex", "q4"])
    #expect(!meta.tags.contains("q4"))

    // Suggest from the notes alone: the transcript says "Sammy" and "Acme".
    meta = try v.suggest(id, heard: Heard(people: ["Pat Doe"], companies: ["Acme"], topics: ["Renewal", "Pricing", "Q4", "Budget"]))
    #expect(meta.suggested.people.isEmpty, "Sam and Kim are linked; Pat Doe is never said")
    #expect(meta.suggested.accounts == ["Acme Corp"], "said as Acme, and Sam works there")
    #expect(meta.suggested.tags.isEmpty, "renewal and pricing are linked, q4 dismissed, and only three topics are read")
    #expect(meta.suggested.dismissed == ["Globex", "q4"])
}

@Test func renamingANoteRewritesEveryLink() throws {
    let v = try scratchVault(copyFixture: true)
    var globex = v.entities().first { $0.name == "Globex" }!
    globex.name = "Globex Inc"
    try v.saveEntity(globex, renamingFrom: "Globex")
    #expect(!FileManager.default.fileExists(atPath: v.url("Accounts/Globex.md").path))
    #expect(try read(v, "Accounts/Globex Inc.md").hasSuffix("Hand-written note, no front matter.\n"))
    #expect(try v.conversation("Work/2026-10-22-hiring-chat").accounts == ["Globex Inc"])
    #expect(v.entities().first { $0.name == "Kim Park" }?.account == "Globex Inc", "a person's account follows")

    var sam = v.entities().first { $0.name == "Sam Lee" }!
    sam.name = "Samuel Lee"
    try v.saveEntity(sam, renamingFrom: "Sam Lee")
    #expect(try v.conversation("Work/Acme/2026-10-20-weekly-sync").people == ["Samuel Lee"])
    #expect(EntityIndex(v.entities()).canonical(.person, "Sammy") == "Samuel Lee", "aliases travel with the note")

    sam.name = "samuel lee"
    try v.saveEntity(sam, renamingFrom: "Samuel Lee")
    #expect(v.entities().contains { $0.name == "samuel lee" }, "a case-only rename works on a case-insensitive disk")

    var clash = Entity(kind: .person, name: "Kim Park")
    clash.body = "x"
    #expect(throws: VaultError.self) { try v.saveEntity(clash, renamingFrom: "samuel lee") }
    #expect(throws: VaultError.self) { try v.saveEntity(Entity(kind: .person, name: " .. ")) }

    var pat = Entity(kind: .person, name: "Pat Doe")
    pat.account = " Initech "
    pat.aliases = [" ", "Pat"]
    try v.saveEntity(pat)
    #expect(v.entities().first { $0.name == "Pat Doe" }?.aliases == ["Pat"])
    #expect(FileManager.default.fileExists(atPath: v.url("Accounts/Initech.md").path), "a new account gets a stub note")
}

@Test func suggestionsPortOfMemosa() {
    var sam = Entity(kind: .person, name: "Sam Lee")
    sam.account = "Acme"
    let notes = [sam, Entity(kind: .account, name: "Acme")]
    let ix = EntityIndex(notes)
    var meta = Conversation(id: "Work/c", title: "Weekly sync", created: "2026-10-25T00:00:00Z")
    meta.suggested.dismissed = ["Globex"]
    let heard = Heard(people: ["Kim Park", "Made Up Person"], companies: ["Globex"], topics: ["Pricing", "q4 renewal", "a", "b"])
    var s = Vault.suggestions(meta, text: "Sam Lee and Kim Park talked about Globex pricing.", entities: notes, index: ix, heard: heard)
    #expect(s.people == ["Sam Lee", "Kim Park"], "known name found, AI name kept only if said")
    #expect(s.accounts == ["Acme"], "Sam brings Acme; dismissed Globex stays gone")
    #expect(s.tags == ["pricing", "q4-renewal", "a"])

    meta.people = ["Sam Lee"]
    s = Vault.suggestions(meta, text: "Sam Lee again.", entities: notes, index: ix, heard: Heard())
    #expect(s.people.isEmpty, "already linked is not suggested")
    #expect(s.accounts == ["Acme"])
}

@Test func firstNamesAreNotSecondPeople() {
    let notes = [Entity(kind: .person, name: "Sam Lee")]
    let ix = EntityIndex(notes)
    var meta = Conversation(id: "Work/c", title: "Sync", created: "2026-10-25T00:00:00Z")
    let text = "Sam Lee joined. Sam said Kim would call. Kim Park agreed."
    var s = Vault.suggestions(meta, text: text, entities: notes, index: ix, heard: Heard(people: ["Sam", "Kim", "Kim Park"]))
    #expect(s.people == ["Sam Lee", "Kim Park"], "Sam and Kim are short for people already suggested")
    s = Vault.suggestions(meta, text: text, entities: [], index: EntityIndex([]), heard: Heard(people: ["Kim", "Kim Park"]))
    #expect(s.people == ["Kim Park"], "a first name heard before the full name is dropped too")
    meta.people = ["Sam Lee"]
    s = Vault.suggestions(meta, text: text, entities: notes, index: ix, heard: Heard(people: ["Sam"]))
    #expect(s.people.isEmpty, "Sam next to a linked Sam Lee is not suggested")

    #expect(Entity.isShortForm("Sam", of: "Sam Lee"))
    #expect(Entity.isShortForm("sam l.", of: "Sam Lee"))
    #expect(!Entity.isShortForm("Sam Lee", of: "Sam Lee"))
    #expect(!Entity.isShortForm("Lee", of: "Sam Lee"))
    #expect(!Entity.isShortForm("Sam Lee Park", of: "Sam Lee"))
    #expect(Entity.fullName("Sam", among: ["Sam Lee", "Kim Park"]) == "Sam Lee")
    #expect(Entity.fullName("Sam", among: ["Sam Lee", "Sam Ortiz"]) == "Sam", "two Sams: left as said")
    #expect(Entity.fullName("Pat", among: ["Sam Lee"]) == "Pat")
}

@Test func tidyAndMentions() {
    #expect(tidyTags(["#Pricing", "Q4 renewal", "pricing"]) == ["pricing", "q4-renewal"])
    #expect(mentions("we spoke to sam lee today", "sam lee"))
    #expect(mentions("sam.", "sam"))
    #expect(!mentions("samsung phones", "sam"), "whole words only")
    #expect(mentions("samsung and sam", "sam"), "a later whole-word hit still counts")
    #expect(!mentions("a b c", "a"), "one letter never matches")
    #expect(Entity.cleanName(" ../a/b ") == "-a-b")
}

@Test func notesRenderLikeMemosa() {
    let n = Notes(summary: " Compared three policies. ", decisions: ["Proceed with Acme"], actions: [
        ActionItem(text: "Send the W-9", owner: "Kim Park", due: "2026-06-19"),
        ActionItem(text: "Request inventory", done: true, owner: "Kim Park"),
        ActionItem(text: "Call back"),
    ])
    #expect(n.rendered(title: "Acme review", date: "2026-06-17", people: ["Kim Park", "Sam Lee"], tags: ["insurance"]) == """
    ---
    title: Acme review
    date: 2026-06-17
    people: [Kim Park, Sam Lee]
    tags: [insurance]
    ---

    ## Summary
    Compared three policies.

    ## Decisions
    - Proceed with Acme

    ## Action items
    - [ ] Send the W-9  <!-- owner: Kim Park; due: 2026-06-19 -->
    - [x] Request inventory  <!-- owner: Kim Park -->
    - [ ] Call back

    """)
    #expect(!Notes(summary: "s").rendered(title: "t", date: "d", people: [], tags: []).contains("## Decisions"))

    let md = "## Action items\n  - [ ] Pay [ ] twice\n- [x] Done thing\n"
    #expect(Notes.toggling(md, text: "Pay", done: true) == "## Action items\n  - [x] Pay [ ] twice\n- [x] Done thing\n")
    #expect(Notes.toggling(md, text: "Done thing", done: false) == "## Action items\n  - [ ] Pay [ ] twice\n- [ ] Done thing\n")
    #expect(Notes.toggling(md, text: "Missing", done: true) == nil)
}

@Test func libraryFollowsTheDisk() async throws {
    let v = try scratchVault(copyFixture: true)
    let library = await Library(vault: v)
    await library.start()
    await library.settle()
    #expect(await library.conversations.count == 4)
    #expect(await library.tasks.filter { !$0.item.done }.map(\.item.text) == ["Pay the deposit", "Send the signed order form"])
    #expect(await library.directory.tags.map(\.name) == ["hiring", "pricing", "renewal"])
    #expect(await library.search("hold the price") == ["Work/Acme/2026-10-20-weekly-sync"])
    #expect(await library.conversations(linkedTo: .account("acme")).map(\.id) == ["Work/Acme/2026-10-20-weekly-sync"])

    // A change from outside (another app, a hand edit) shows up on its own.
    let before = await library.generation
    try Vault(root: v.root).createConversation(in: "Home", title: "New call")
    var waited = 0
    while await library.conversations.count < 5, waited < 100 {
        try await Task.sleep(for: .milliseconds(50))
        waited += 1
    }
    #expect(await library.conversations.count == 5)
    #expect(await library.generation > before)
    await library.stop()
}

/// Glyph never deletes: trash moves the whole folder into `.memosa/trash` inside the
/// vault, every file intact, and there is no retention or purge anywhere.
@Test func trashKeepsEveryFile() throws {
    let v = try scratchVault(copyFixture: true)
    let id = "Work/Acme/2026-10-20-weekly-sync"
    try Data("not really audio".utf8).write(to: v.url(id).appending(path: "audio.m4a"))
    let before = try FileManager.default.contentsOfDirectory(atPath: v.url(id).path).sorted()
    let bytes = try before.map { try Data(contentsOf: v.url(id).appending(path: $0)) }
    try v.trash(id)
    let kept = v.url(".memosa/trash/Work__Acme__2026-10-20-weekly-sync")
    #expect(try FileManager.default.contentsOfDirectory(atPath: kept.path).sorted() == before)
    #expect(try before.map { try Data(contentsOf: kept.appending(path: $0)) } == bytes)
    #expect(!FileManager.default.fileExists(atPath: v.url(id).path))
    #expect(v.entities().count == 4, "notes are untouched")
}

@Test func everyNewRecordingSaysWhichMachineItCameFrom() throws {
    let v = try scratchVault()
    let made = try v.createConversation(in: "", title: "Weekly sync with Acme")
    #expect(made.device == ThisDevice.name && !(made.device ?? "").isEmpty)
    let json = try read(v, made.id + "/meta.json")
    #expect(json.contains("\"device\""))
    // A file from before the field reads fine, with no device.
    let old = #"{"id": "a", "title": "Old", "created": "2026-01-01T00:00:00Z"}"#
    #expect(try JSONDecoder().decode(Conversation.self, from: Data(old.utf8)).device == nil)
}
