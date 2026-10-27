import Foundation
import Testing
@testable import GlyphVault

/// A small Studio vault: two people, a company page, two apps (one is the company's), a
/// project and two domains. Made-up names only.
func studioVault() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "glyph-studio-\(UUID().uuidString)")
    func put(_ rel: String, _ text: String) throws {
        let url = root.appending(path: rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    try put("data/entities/people/sam-lee/entity.md", "---\nname: Sam Lee\nkind: person\naliases: [Sammy, \"S. Lee\"]\nsaved: true\n---\n\n## Your notes\n")
    try put("data/entities/people/kim-park.md", "---\nname: Kim Park\nkind: person\naliases: []\n---\n") // an older flat page
    try put("data/entities/people/_merged/old/entity.md", "---\nname: Gone\n---\n")
    try put("data/entities/orgs/acme/entity.md", "---\nname: Acme\nkind: org\naliases: [Acme Corp]\n---\n")
    try put("data/apps/acme-portal/manifest.json", #"{"id":"acme-portal","name":"Acme Portal","company":"Acme"}"#)
    try put("data/apps/globex/manifest.json", #"{"id":"globex","name":"Globex"}"#)
    try put("data/apps/_archive/x/manifest.json", #"{"name":"Archived"}"#)
    try put("data/missions/launch-day/mission.md", "---\nname: \"Launch day\"\nstatus: active\n---\n")
    try put("data/domains/career/manifest.json", #"{"identity":{"name":"career","label":"Career"}}"#)
    try put("data/domains/real-estate/memory/state.md", "")
    try put("data/domains/_meta/x.json", "{}")
    return root
}

@Test func studioObjectsUseStudiosIdsAndNames() throws {
    let s = StudioDirectory(root: try studioVault())
    #expect(s.objects(.person).map(\.id) == ["person/kim-park", "person/sam-lee"])
    #expect(s.object("person/sam-lee")?.aliases == ["Sammy", "S. Lee"])
    #expect(s.objects(.product).map(\.id) == ["org/acme", "org/globex"], "Acme Portal is Acme's app, Globex an app of its own")
    #expect(s.object("org/acme")?.aliases == ["Acme Corp", "Acme Portal"])
    #expect(s.object("mission/launch-day")?.name == "Launch day")
    #expect(s.objects(.domain).map(\.name) == ["Career", "Real Estate"], "the label when there is one; _meta is not a domain")
    #expect(StudioObject.Kind(id: "org/acme") == .product && StudioObject.Kind(id: "mission/x") == .project)
    #expect(StudioObject.Kind.product.label == "Products" && StudioObject.Kind.person.label == "People")
    #expect(StudioObject.isID("domain/career") && !StudioObject.isID("Sam Lee") && !StudioObject.isID("acme"))

    #expect(s.match("sammy", .person)?.id == "person/sam-lee", "an alias, any case")
    #expect(s.match("Acme Corp", .product)?.id == "org/acme")
    #expect(s.match("kim park", .person)?.id == "person/kim-park")
    #expect(s.match("Globex", .person) == nil, "kinds don't cross")
    #expect(s.name("person/pat-doe") == "Pat Doe", "an id Studio no longer has still reads")
    #expect(StudioDirectory.slug("Sam Lee, Jr.") == "sam-lee-jr")
}

@Test func capturesLinkByIdAndGuessAgainstStudio() throws {
    let s = StudioDirectory(root: try studioVault())
    let v = try scratchVault()
    let id = try v.createConversation(in: "Recordings", title: "Call with Sammy").id
    try v.writeTranscript(Transcript(language: "en", model: "test", segments: [.init(start: 0, end: 4, text: "Sammy and Pat Doe talked about Acme Corp and Globex pricing.")]), for: id)

    var meta = try v.suggest(id, heard: Heard(people: ["Pat Doe", "Pat", "Kim Park", "Nobody Said"], companies: ["Acme Corp", "Initech"], topics: ["Pricing", "Q4"]), studio: s)
    #expect(meta.suggested.links == ["person/sam-lee", "org/acme"], "Sammy is Sam Lee; Initech is not in Studio; Kim is never said")
    #expect(meta.suggested.people == ["Pat Doe"], "a new name only when the call says it, and Pat is short for Pat Doe")
    #expect(meta.suggested.tags == ["pricing", "q4"])

    meta = try v.answer(id, .object("person/sam-lee"), accept: true)
    meta = try v.answer(id, .person("Pat Doe"), accept: true, resolved: "person/pat-doe")
    meta = try v.answer(id, .object("org/acme"), accept: false)
    meta = try v.answer(id, .tag("pricing"), accept: true)
    #expect(meta.links == ["person/sam-lee", "person/pat-doe"])
    #expect(meta.tags == ["pricing"])
    #expect(meta.suggested.links.isEmpty && meta.suggested.people.isEmpty && meta.suggested.dismissed == ["org/acme"])

    meta = try v.suggest(id, heard: Heard(companies: ["Acme Corp"]), studio: s)
    #expect(meta.suggested.links.isEmpty, "linked and dismissed never come back")

    meta = try v.setStudioLinks(id, links: ["domain/career", "domain/career", "mission/launch-day"], tags: ["#Q4 Renewal"])
    #expect(meta.links == ["domain/career", "mission/launch-day"] && meta.tags == ["q4-renewal"])
    let json = try read(v, id + "/meta.json")
    #expect(json.contains("\"links\": [\n    \"domain/career\",\n    \"mission/launch-day\"\n  ]"))
    #expect(v.conversations(linkedTo: .object("domain/career")).map(\.id) == [id])
}

@Test func emptyLinksLeaveOlderFilesByteForByte() throws {
    let v = try scratchVault()
    let id = try v.createConversation(in: "Work", title: "Sync").id
    let json = try read(v, id + "/meta.json")
    #expect(!json.contains("links"))
    var meta = try v.conversation(id)
    meta.suggested.tags = ["x"]
    try v.write(meta)
    #expect(try read(v, id + "/meta.json").contains("\"suggested\": {\n    \"people\": []"), "no links key inside suggested either")
}

@Test func olderPeopleAndAccountsMoveOntoStudio() throws {
    let s = StudioDirectory(root: try studioVault())
    let v = try scratchVault()
    // The older vault: notes with aliases and a call that names people and accounts.
    try v.saveEntity({ var e = Entity(kind: .person, name: "Sam"); e.aliases = ["Sammy"]; return e }())
    try v.saveEntity({ var e = Entity(kind: .person, name: "Dana Cruz"); e.body = "Met at the expo."; return e }())
    try v.saveEntity(Entity(kind: .account, name: "Acme Corp"))
    try v.saveEntity(Entity(kind: .account, name: "Initech"))
    let a = try v.createConversation(in: "Recordings", title: "Kickoff").id
    var meta = try v.conversation(a)
    meta.people = ["sammy", "Dana Cruz"]
    meta.accounts = ["Acme Corp", "Initech"]
    meta.tags = ["kickoff"]
    meta.suggested.accounts = ["Globex"]
    try v.write(meta)

    var made: [(StudioObject.Kind, String, String)] = []
    let report = try v.migrateToStudio(s) { kind, name, notes in
        made.append((kind, name, notes))
        return name == "Initech" ? nil : "\(kind.prefix)/\(StudioDirectory.slug(name))"   // Initech: Studio refused
    }
    meta = try v.conversation(a)
    #expect(meta.links == ["person/sam-lee", "person/dana-cruz", "org/acme"], "Sam is Sam Lee through the alias Sammy")
    #expect(meta.people.isEmpty && meta.accounts == ["Initech"], "what Studio could not take stays")
    #expect(meta.tags == ["kickoff"] && meta.suggested.accounts.isEmpty)
    #expect(made.map(\.1) == ["Dana Cruz", "Initech"], "only names Studio has no page for are made")
    #expect(made.first?.2 == "Met at the expo.", "the note's text goes with it")
    #expect(report.rows.filter(\.created).map(\.id) == ["person/dana-cruz"])
    #expect(report.unresolved == ["Initech"] && report.conversations == 1 && report.notesMoved == 3)
    #expect(!FileManager.default.fileExists(atPath: v.root.appending(path: "People/Sam.md").path))
    #expect(FileManager.default.fileExists(atPath: v.root.appending(path: ".memosa/migrated-to-studio/People/Sam.md").path), "moved, never deleted")
    #expect(FileManager.default.fileExists(atPath: v.root.appending(path: "Accounts/Initech.md").path))

    // A second run only retries what is left.
    made = []
    let again = try v.migrateToStudio(s) { kind, name, _ in made.append((kind, name, "")); return nil }
    #expect(made.map(\.1) == ["Initech"] && again.rows.isEmpty)
    #expect(try v.conversation(a).links == ["person/sam-lee", "person/dana-cruz", "org/acme"])
}
