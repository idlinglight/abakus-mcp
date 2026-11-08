import AbakusCore
import AbakusMCP
import Testing

@Suite struct MCPServerPlaceholderTests {
    @Test func catalogIsReachable() {
        #expect(Catalog.tools.count >= 0)
    }
}
