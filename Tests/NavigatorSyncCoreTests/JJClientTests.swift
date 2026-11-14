import Foundation
import Testing

@testable import NavigatorSyncCore

@Suite("SubprocessJJClient")
struct JJClientTests {

    private func client(_ fake: FakeCommandRunner) -> SubprocessJJClient {
        SubprocessJJClient(runner: fake, jjExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/jj"))
    }

    @Test("fetch runs `jj git fetch --remote origin`")
    func fetchArgv() async throws {
        let fake = FakeCommandRunner()
        try await client(fake).fetch(repo: URL(fileURLWithPath: "/w/m"), remote: "origin")
        let calls = await fake.invocations()
        #expect(calls.last?.arguments == ["git", "fetch", "--remote", "origin"])
        #expect(calls.last?.workingDirectory == "/w/m")
    }

    @Test("push success maps to .pushed")
    func pushSuccess() async throws {
        let fake = FakeCommandRunner()
        await fake.stub(when: { $0.contains("push") },
            return: CommandResult(exitCode: 0, standardOutput: "", standardError: ""))
        let outcome = try await client(fake).push(
            bookmark: "main", remote: "origin", repo: URL(fileURLWithPath: "/w/m"))
        #expect(outcome == .pushed)
    }

    @Test("push rejection (remote moved) maps to .rejected")
    func pushRejected() async throws {
        let fake = FakeCommandRunner()
        await fake.stub(when: { $0.contains("push") },
            return: CommandResult(exitCode: 1, standardOutput: "",
                standardError: "Error: The push was rejected because the remote moved"))
        let outcome = try await client(fake).push(
            bookmark: "main", remote: "origin", repo: URL(fileURLWithPath: "/w/m"))
        #expect(outcome == .rejected)
    }

    @Test("push auth failure maps to .authFailure")
    func pushAuth() async throws {
        let fake = FakeCommandRunner()
        await fake.stub(when: { $0.contains("push") },
            return: CommandResult(exitCode: 1, standardOutput: "",
                standardError: "fatal: Authentication failed for repo"))
        let outcome = try await client(fake).push(
            bookmark: "main", remote: "origin", repo: URL(fileURLWithPath: "/w/m"))
        #expect(outcome == .authFailure)
    }

    @Test("push nothing-to-push maps to .nothingToPush")
    func pushNothing() async throws {
        let fake = FakeCommandRunner()
        await fake.stub(when: { $0.contains("push") },
            return: CommandResult(exitCode: 1, standardOutput: "",
                standardError: "Nothing changed."))
        let outcome = try await client(fake).push(
            bookmark: "main", remote: "origin", repo: URL(fileURLWithPath: "/w/m"))
        #expect(outcome == .nothingToPush)
    }

    @Test("status parses conflict + bookmark templates into RepoState")
    func statusParses() async throws {
        let fake = FakeCommandRunner()
        await fake.stub(when: { $0.contains("log") },
            return: CommandResult(exitCode: 0, standardOutput: "0\n", standardError: ""))
        await fake.stub(when: { $0.contains("bookmark") && $0.contains("list") },
            return: CommandResult(
                exitCode: 0,
                standardOutput: "main\t\taaa\nmain\torigin\tbbb\n",
                standardError: ""))
        let state = try await client(fake).status(
            bookmark: "main", remote: "origin", repo: URL(fileURLWithPath: "/w/m"))
        #expect(!state.hasConflict)
        #expect(state.localAheadOfRemote)        // aaa != bbb
        #expect(state.remoteChangedSinceLastFetch)
    }

    @Test("a failed fetch throws commandFailed with stderr")
    func fetchFailsThrows() async {
        let fake = FakeCommandRunner()
        await fake.stub(when: { $0.contains("fetch") },
            return: CommandResult(exitCode: 1, standardOutput: "", standardError: "boom"))
        await #expect(throws: JJError.self) {
            try await client(fake).fetch(repo: URL(fileURLWithPath: "/w/m"), remote: "origin")
        }
    }

    @Test("clone runs `jj git clone <url> <dir>`")
    func cloneArgv() async throws {
        let fake = FakeCommandRunner()
        try await client(fake).clone(
            remoteURL: "file:///r/acme.git", into: URL(fileURLWithPath: "/w/acme"))
        let calls = await fake.invocations()
        #expect(calls.last?.arguments == ["git", "clone", "file:///r/acme.git", "/w/acme"])
    }

    @Test("rebase targets <bookmark>@<remote>")
    func rebaseArgv() async throws {
        let fake = FakeCommandRunner()
        try await client(fake).rebaseLocalOnto(
            bookmark: "main", remote: "origin", repo: URL(fileURLWithPath: "/w/m"))
        let calls = await fake.invocations()
        #expect(calls.last?.arguments == ["rebase", "-b", "@", "-d", "main@origin"])
    }
}
