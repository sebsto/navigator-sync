import Foundation
import Testing

@testable import NavigatorSyncCore

@Suite("MatterActor")
struct MatterActorTests {

    private func makeActor(jj: FakeJJClient) -> MatterActor {
        let d = MatterDescriptor(id: "1", code: "acme", name: "Acme", repositoryURL: "file:///r/acme.git", status: "open")
        return MatterActor(descriptor: d, repo: URL(fileURLWithPath: "/w/acme"), jj: jj, bookmark: "main")
    }

    @Test("clean sync with local work pushes and goes up to date")
    func cleanSyncPushes() async {
        let jj = FakeJJClient(
            state: RepoState(hasConflict: false, localAheadOfRemote: true, remoteChangedSinceLastFetch: false),
            push: .pushed)
        let actor = makeActor(jj: jj)
        await actor.sync()
        if case .upToDate = await actor.currentStatus() {} else {
            Issue.record("expected upToDate, got \(await actor.currentStatus())")
        }
        let calls = await jj.recordedCalls()
        #expect(calls.contains(.push))
    }

    @Test("nothing to sync: up to date, no push")
    func nothingToSync() async {
        let jj = FakeJJClient(
            state: RepoState(hasConflict: false, localAheadOfRemote: false, remoteChangedSinceLastFetch: false))
        let actor = makeActor(jj: jj)
        await actor.sync()
        if case .upToDate = await actor.currentStatus() {} else {
            Issue.record("expected upToDate")
        }
        let calls = await jj.recordedCalls()
        #expect(!calls.contains(.push))
    }

    @Test("conflict flags needsAttention(.conflict) and does not push")
    func conflictFlagged() async {
        let jj = FakeJJClient(
            state: RepoState(hasConflict: true, localAheadOfRemote: true, remoteChangedSinceLastFetch: true))
        let actor = makeActor(jj: jj)
        await actor.sync()
        #expect(await actor.currentStatus() == .needsAttention(reason: .conflict))
        let calls = await jj.recordedCalls()
        #expect(!calls.contains(.push))
        #expect(!calls.contains(.rebase))
    }

    @Test("rebases when the remote moved")
    func rebaseOnRemoteChange() async {
        let jj = FakeJJClient(
            state: RepoState(hasConflict: false, localAheadOfRemote: true, remoteChangedSinceLastFetch: true),
            push: .pushed)
        let actor = makeActor(jj: jj)
        await actor.sync()
        let calls = await jj.recordedCalls()
        #expect(calls.contains(.rebase))
    }

    @Test("push rejected flags needsAttention(.pushRejected) and backs off")
    func pushRejected() async {
        let jj = FakeJJClient(
            state: RepoState(hasConflict: false, localAheadOfRemote: true, remoteChangedSinceLastFetch: false),
            push: .rejected)
        let actor = makeActor(jj: jj)
        await actor.sync()
        #expect(await actor.currentStatus() == .needsAttention(reason: .pushRejected))
        #expect(await actor.failureCount() == 1)
    }

    @Test("auth failure flags needsAttention(.authFailure)")
    func authFailure() async {
        let jj = FakeJJClient(
            state: RepoState(hasConflict: false, localAheadOfRemote: true, remoteChangedSinceLastFetch: false),
            push: .authFailure)
        let actor = makeActor(jj: jj)
        await actor.sync()
        #expect(await actor.currentStatus() == .needsAttention(reason: .authFailure))
    }

    @Test("a thrown network error on fetch goes offline and advances backoff")
    func fetchErrorOffline() async {
        struct Net: Error {}
        let jj = FakeJJClient()
        await jj.setFetchError { Net() }
        let actor = makeActor(jj: jj)
        let now = Date()
        await actor.sync(now: now)
        #expect(await actor.currentStatus() == .offline)
        #expect(await actor.failureCount() == 1)
        #expect(await actor.nextEligibleDate() > now)
    }

    @Test("tracks the remote bookmark only once across syncs")
    func tracksOnce() async {
        let jj = FakeJJClient(
            state: RepoState(hasConflict: false, localAheadOfRemote: false, remoteChangedSinceLastFetch: false))
        let actor = makeActor(jj: jj)
        await actor.sync()
        await actor.sync()
        let trackCount = await jj.recordedCalls().filter { $0 == .track }.count
        #expect(trackCount == 1)
    }

    @Test("a successful sync resets the backoff window to now")
    func successResetsBackoff() async {
        let jj = FakeJJClient(
            state: RepoState(hasConflict: false, localAheadOfRemote: true, remoteChangedSinceLastFetch: false),
            push: .rejected)
        let actor = makeActor(jj: jj)
        await actor.sync()
        #expect(await actor.failureCount() == 1)
        await jj.setPush(.pushed)
        await actor.sync()
        #expect(await actor.failureCount() == 0)
    }
}
