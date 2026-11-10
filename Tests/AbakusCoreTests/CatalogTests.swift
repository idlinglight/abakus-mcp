import AbakusCore
import Testing

@Suite struct CatalogTests {
    /// `abakus tools` lists each tool by its title, so every tool needs one: a few words for people.
    @Test func everyToolHasAShortTitle() {
        for tool in Catalog.tools {
            let title = tool.annotations.title ?? ""
            #expect(!title.isEmpty && title.count <= 40, "\(tool.name) needs a title of a few words")
        }
    }

    /// An old name points to a tool that exists and is itself no tool any more.
    @Test func renamedToolsPointToTheirNewNames() {
        #expect(Catalog.renameNote(for: "tally_list") == "It was renamed to tallies_info in abakus 0.5.0.")
        #expect(Catalog.renameNote(for: "nope") == nil)
        for (old, new) in Catalog.renamed {
            #expect(Catalog.tool(named: old) == nil, "\(old)")
            #expect(Catalog.tool(named: new.name) != nil, "\(new.name)")
        }
    }
}
