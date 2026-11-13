import Foundation
import Testing

@testable import NavigatorSyncCore

@Suite("Models")
struct ModelsTests {

    @Test("SyncConfig defaults match the brief")
    func syncConfigDefaults() {
        let c = SyncConfig()
        #expect(c.intervalSeconds == 60)
        #expect(c.maxParallelSyncs == 4)
        #expect(c.defaultBookmark == "main")
        #expect(c.host == "https://www.neonlaw.com")
        #expect(c.workFolder == nil)
    }

    @Test("bookmark(forMatterCode:) uses override then default")
    func bookmarkOverride() {
        var c = SyncConfig(defaultBookmark: "main")
        #expect(c.bookmark(forMatterCode: "acme") == "main")
        c.bookmarkOverrides["acme"] = "user/acme"
        #expect(c.bookmark(forMatterCode: "acme") == "user/acme")
        #expect(c.bookmark(forMatterCode: "other") == "main")
    }

    @Test("MatterDescriptor.isOpen reflects status")
    func matterIsOpen() {
        let open = MatterDescriptor(id: "1", code: "a", name: "A", repositoryURL: nil, status: "open")
        let closed = MatterDescriptor(id: "2", code: "b", name: "B", repositoryURL: nil, status: "closed")
        #expect(open.isOpen)
        #expect(!closed.isOpen)
    }

    @Test("MatterStatus equality distinguishes cases")
    func statusEquality() {
        let now = Date()
        #expect(MatterStatus.syncing == .syncing)
        #expect(MatterStatus.upToDate(lastSynced: now) == .upToDate(lastSynced: now))
        #expect(MatterStatus.needsAttention(reason: .conflict) != .needsAttention(reason: .authFailure))
        #expect(MatterStatus.offline != .syncing)
    }
}
