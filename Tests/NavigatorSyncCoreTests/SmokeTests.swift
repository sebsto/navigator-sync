import Testing

@testable import NavigatorSyncCore

@Test("core library is linkable and reports its spec version")
func coreIsLinkable() {
    #expect(NavigatorSyncCore.specVersion == "0.1.0-dev")
}
