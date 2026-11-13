import Foundation

/// A scriptable `JJClient` for engine tests. An `actor` for race-free scripting
/// and call recording without launching `jj`.
public actor FakeJJClient: JJClient {

    public enum Call: Sendable, Equatable {
        case fetch, track, status, rebase, push, clone, isValid
    }

    private var scriptedState: RepoState
    private var scriptedPush: PushOutcome
    private var validRepo: Bool
    private var fetchError: (@Sendable () -> Error)?
    private var statusError: (@Sendable () -> Error)?
    private var calls: [Call] = []

    public init(
        state: RepoState = RepoState(
            hasConflict: false, localAheadOfRemote: false, remoteChangedSinceLastFetch: false),
        push: PushOutcome = .pushed,
        validRepo: Bool = false
    ) {
        self.scriptedState = state
        self.scriptedPush = push
        self.validRepo = validRepo
    }

    public func setState(_ s: RepoState) { scriptedState = s }
    public func setPush(_ p: PushOutcome) { scriptedPush = p }
    public func setValidRepo(_ v: Bool) { validRepo = v }
    public func setFetchError(_ e: (@Sendable () -> Error)?) { fetchError = e }
    public func setStatusError(_ e: (@Sendable () -> Error)?) { statusError = e }
    public func recordedCalls() -> [Call] { calls }

    public func fetch(repo: URL, remote: String) async throws {
        calls.append(.fetch)
        if let fetchError { throw fetchError() }
    }
    public func trackBookmark(_ bookmark: String, remote: String, repo: URL) async throws {
        calls.append(.track)
    }
    public func status(bookmark: String, remote: String, repo: URL) async throws -> RepoState {
        calls.append(.status)
        if let statusError { throw statusError() }
        return scriptedState
    }
    public func rebaseLocalOnto(bookmark: String, remote: String, repo: URL) async throws {
        calls.append(.rebase)
    }
    public func push(bookmark: String, remote: String, repo: URL) async throws -> PushOutcome {
        calls.append(.push)
        return scriptedPush
    }
    public func clone(remoteURL: String, into dir: URL) async throws {
        calls.append(.clone)
    }
    public func isValidRepo(_ dir: URL) async -> Bool {
        calls.append(.isValid)
        return validRepo
    }
}
