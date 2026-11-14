import Foundation

/// The outcome of a `jj git push`.
public nonisolated enum PushOutcome: Sendable, Equatable {
    case pushed
    case nothingToPush
    case rejected          // remote moved since fetch (force-with-lease safety check)
    case authFailure
}

/// Errors surfaced by the jj client that the engine maps to a matter status.
public nonisolated enum JJError: Error, Sendable, Equatable {
    case conflict
    case commandFailed(exitCode: Int32, stderr: String)
}

/// Drives the `jj` CLI for one matter repository. Behind a protocol so the sync
/// engine can be tested with a fake.
public nonisolated protocol JJClient: Sendable {
    /// `jj git fetch` the remote.
    nonisolated func fetch(repo: URL, remote: String) async throws
    /// Ensure the remote bookmark is tracked (a fresh clone is non-tracking).
    nonisolated func trackBookmark(_ bookmark: String, remote: String, repo: URL) async throws
    /// Read the repo state (conflict + ahead/behind) via templates.
    nonisolated func status(bookmark: String, remote: String, repo: URL) async throws -> RepoState
    /// Rebase local work onto the fetched remote bookmark position.
    nonisolated func rebaseLocalOnto(bookmark: String, remote: String, repo: URL) async throws
    /// Push the bookmark to the remote; classify the outcome.
    nonisolated func push(bookmark: String, remote: String, repo: URL) async throws -> PushOutcome
    /// Clone a remote into `dir`.
    nonisolated func clone(remoteURL: String, into dir: URL) async throws
    /// Whether `dir` is a valid jj repo.
    nonisolated func isValidRepo(_ dir: URL) async -> Bool
}

/// `JJClient` backed by the `jj` CLI via `CommandRunner`.
public nonisolated struct SubprocessJJClient: JJClient {
    private let runner: any CommandRunning
    private let jj: URL

    public init(runner: any CommandRunning, jjExecutable: URL) {
        self.runner = runner
        self.jj = jjExecutable
    }

    /// Convenience that resolves `jj` through a locator.
    public init(runner: any CommandRunning, locator: CLILocator) throws {
        self.runner = runner
        self.jj = try locator.locate(.jj)
    }

    public func fetch(repo: URL, remote: String) async throws {
        try await runExpectingSuccess(
            ["git", "fetch", "--remote", remote], in: repo)
    }

    public func trackBookmark(_ bookmark: String, remote: String, repo: URL) async throws {
        // Idempotent: tracking an already-tracked bookmark is a no-op error we
        // tolerate, so a non-zero exit here is not fatal.
        _ = try await runner.run(
            executable: jj,
            arguments: ["bookmark", "track", "\(bookmark)@\(remote)"],
            workingDirectory: repo,
            environment: nil,
            timeout: .seconds(60)
        )
    }

    public func status(bookmark: String, remote: String, repo: URL) async throws -> RepoState {
        let conflictOut = try await runExpectingSuccess(
            ["log", "--no-graph", "-r", "@", "-T", #"if(conflict,"1","0") ++ "\n""#],
            in: repo
        )
        let hasConflict = JJParser.parseConflict(conflictOut)

        let bookmarksOut = try await runExpectingSuccess(
            [
                "bookmark", "list", "--all-remotes",
                "-T",
                #"name ++ "\t" ++ remote ++ "\t" ++ normal_target.commit_id().short() ++ "\n""#,
            ],
            in: repo
        )
        let rows = JJParser.parseBookmarks(bookmarksOut)
        return JJParser.repoState(
            rows: rows, bookmark: bookmark, remote: remote, hasConflict: hasConflict)
    }

    public func rebaseLocalOnto(bookmark: String, remote: String, repo: URL) async throws {
        try await runExpectingSuccess(
            ["rebase", "-b", "@", "-d", "\(bookmark)@\(remote)"], in: repo)
    }

    public func push(bookmark: String, remote: String, repo: URL) async throws -> PushOutcome {
        let result = try await runner.run(
            executable: jj,
            arguments: ["git", "push", "--bookmark", bookmark, "--remote", remote],
            workingDirectory: repo,
            environment: nil,
            timeout: .seconds(120)
        )
        if result.isSuccess { return .pushed }
        let err = result.standardError.lowercased()
        if err.contains("nothing changed") || err.contains("no bookmarks to push") {
            return .nothingToPush
        }
        if err.contains("rejected") || err.contains("remote moved")
            || err.contains("safety check") || err.contains("stale")
        {
            return .rejected
        }
        if err.contains("auth") || err.contains("permission denied")
            || err.contains("credential") || err.contains("403")
        {
            return .authFailure
        }
        throw JJError.commandFailed(exitCode: result.exitCode, stderr: result.standardError)
    }

    public func clone(remoteURL: String, into dir: URL) async throws {
        try await runExpectingSuccess(
            ["git", "clone", remoteURL, dir.path], in: nil)
    }

    public func isValidRepo(_ dir: URL) async -> Bool {
        let result = try? await runner.run(
            executable: jj,
            arguments: ["root"],
            workingDirectory: dir,
            environment: nil,
            timeout: .seconds(30)
        )
        return result?.isSuccess ?? false
    }

    @discardableResult
    private func runExpectingSuccess(
        _ arguments: [String], in repo: URL?
    ) async throws -> String {
        let result = try await runner.run(
            executable: jj,
            arguments: arguments,
            workingDirectory: repo,
            environment: nil,
            timeout: .seconds(120)
        )
        guard result.isSuccess else {
            throw JJError.commandFailed(exitCode: result.exitCode, stderr: result.standardError)
        }
        return result.standardOutput
    }
}
