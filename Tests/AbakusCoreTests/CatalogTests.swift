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
}
