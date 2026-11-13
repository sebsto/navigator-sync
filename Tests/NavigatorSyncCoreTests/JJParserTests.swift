import Testing

@testable import NavigatorSyncCore

@Suite("JJParser")
struct JJParserTests {

    // MARK: conflict probe

    @Test("conflict probe: 1 is a conflict", arguments: ["1", "1\n", " 1 \n"])
    func conflictTrue(_ input: String) {
        #expect(JJParser.parseConflict(input))
    }

    @Test("conflict probe: 0 and empty are clean", arguments: ["0", "0\n", "", "\n"])
    func conflictFalse(_ input: String) {
        #expect(!JJParser.parseConflict(input))
    }

    // MARK: bookmark listing

    @Test("parses a local + remote row at the same commit")
    func localAndRemoteSame() {
        let out = "trunk\t\t976fcef56904\ntrunk\torigin\t976fcef56904\n"
        let rows = JJParser.parseBookmarks(out)
        #expect(rows.count == 2)
        #expect(rows[0] == BookmarkRow(name: "trunk", remote: nil, commitID: "976fcef56904"))
        #expect(rows[1] == BookmarkRow(name: "trunk", remote: "origin", commitID: "976fcef56904"))
    }

    @Test("empty remote field becomes nil")
    func emptyRemoteNil() {
        let rows = JJParser.parseBookmarks("main\t\tabc123\n")
        #expect(rows.count == 1)
        #expect(rows[0].remote == nil)
    }

    @Test("empty output yields no rows")
    func emptyOutput() {
        #expect(JJParser.parseBookmarks("").isEmpty)
        #expect(JJParser.parseBookmarks("\n\n").isEmpty)
    }

    @Test("malformed lines (wrong column count) are skipped")
    func malformedSkipped() {
        let out = "good\torigin\tdeadbeef\nbadline-no-tabs\nalso\tbad\n\t\t\n"
        let rows = JJParser.parseBookmarks(out)
        #expect(rows.count == 1)
        #expect(rows[0].name == "good")
    }

    @Test("multi-remote rows (origin and git) both parse")
    func multiRemote() {
        let out = "trunk\t\t976fcef5\ntrunk\tgit\t976fcef5\ntrunk\torigin\t976fcef5\n"
        let rows = JJParser.parseBookmarks(out)
        #expect(rows.count == 3)
        #expect(rows.contains(BookmarkRow(name: "trunk", remote: "git", commitID: "976fcef5")))
        #expect(rows.contains(BookmarkRow(name: "trunk", remote: "origin", commitID: "976fcef5")))
    }

    // MARK: repoState derivation

    @Test("same local and remote commit: not ahead, remote unchanged")
    func stateInSync() {
        let rows = [
            BookmarkRow(name: "main", remote: nil, commitID: "aaa"),
            BookmarkRow(name: "main", remote: "origin", commitID: "aaa"),
        ]
        let s = JJParser.repoState(rows: rows, bookmark: "main", remote: "origin", hasConflict: false)
        #expect(!s.localAheadOfRemote)
        #expect(!s.remoteChangedSinceLastFetch)
        #expect(!s.hasConflict)
    }

    @Test("different commits: ahead and remote changed")
    func stateDiverged() {
        let rows = [
            BookmarkRow(name: "main", remote: nil, commitID: "local1"),
            BookmarkRow(name: "main", remote: "origin", commitID: "remote2"),
        ]
        let s = JJParser.repoState(rows: rows, bookmark: "main", remote: "origin", hasConflict: false)
        #expect(s.localAheadOfRemote)
        #expect(s.remoteChangedSinceLastFetch)
    }

    @Test("no remote-tracking row: local ahead, remote unchanged")
    func stateNoRemoteYet() {
        let rows = [BookmarkRow(name: "main", remote: nil, commitID: "local1")]
        let s = JJParser.repoState(rows: rows, bookmark: "main", remote: "origin", hasConflict: false)
        #expect(s.localAheadOfRemote)
        #expect(!s.remoteChangedSinceLastFetch)
    }

    @Test("no local row but a remote exists: adopt remote")
    func stateNoLocal() {
        let rows = [BookmarkRow(name: "main", remote: "origin", commitID: "remote2")]
        let s = JJParser.repoState(rows: rows, bookmark: "main", remote: "origin", hasConflict: false)
        #expect(!s.localAheadOfRemote)
        #expect(s.remoteChangedSinceLastFetch)
    }

    @Test("conflict flag is carried through")
    func stateConflict() {
        let s = JJParser.repoState(rows: [], bookmark: "main", remote: "origin", hasConflict: true)
        #expect(s.hasConflict)
    }
}
