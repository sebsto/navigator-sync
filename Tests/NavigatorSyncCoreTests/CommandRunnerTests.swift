import Foundation
import Testing

@testable import NavigatorSyncCore

@Suite("CommandRunner (swift-subprocess)")
struct CommandRunnerTests {

    @Test("runs /bin/echo and collects stdout")
    func echoStdout() async throws {
        let runner = SubprocessCommandRunner()
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello world"],
            workingDirectory: nil,
            environment: nil,
            timeout: .seconds(10)
        )
        #expect(result.isSuccess)
        #expect(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "hello world")
    }

    @Test("captures a non-zero exit code")
    func nonZeroExit() async throws {
        let runner = SubprocessCommandRunner()
        // `false` exits 1.
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: [],
            workingDirectory: nil,
            environment: nil,
            timeout: .seconds(10)
        )
        #expect(!result.isSuccess)
        #expect(result.exitCode == 1)
    }

    @Test("times out and tears down a long-running process")
    func timeoutTearsDown() async {
        let runner = SubprocessCommandRunner()
        await #expect(throws: CommandTimeoutError.self) {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                workingDirectory: nil,
                environment: nil,
                timeout: .milliseconds(300)
            )
        }
    }

    @Test("working directory is honored")
    func workingDirectory() async throws {
        let runner = SubprocessCommandRunner()
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/pwd"),
            arguments: [],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            environment: nil,
            timeout: .seconds(10)
        )
        // /tmp is a symlink to /private/tmp on macOS; accept either.
        let out = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(out == "/tmp" || out == "/private/tmp")
    }
}

@Suite("FakeCommandRunner")
struct FakeCommandRunnerTests {

    @Test("returns a matching stub and records the invocation")
    func stubAndRecord() async throws {
        let fake = FakeCommandRunner()
        await fake.stub(when: { $0.contains("git") }, return:
            CommandResult(exitCode: 0, standardOutput: "ok", standardError: ""))

        let result = try await fake.run(
            executable: URL(fileURLWithPath: "/opt/homebrew/bin/jj"),
            arguments: ["git", "fetch"],
            workingDirectory: URL(fileURLWithPath: "/w/matter"),
            environment: nil,
            timeout: .seconds(1)
        )
        #expect(result.standardOutput == "ok")
        let calls = await fake.invocations()
        #expect(calls.count == 1)
        #expect(calls[0].executable == "jj")
        #expect(calls[0].arguments == ["git", "fetch"])
        #expect(calls[0].workingDirectory == "/w/matter")
    }

    @Test("falls back when no stub matches")
    func fallback() async throws {
        let fake = FakeCommandRunner()
        await fake.setFallback(CommandResult(exitCode: 2, standardOutput: "", standardError: "boom"))
        let result = try await fake.run(
            executable: URL(fileURLWithPath: "/x/navigator"),
            arguments: ["whoami"],
            workingDirectory: nil,
            environment: nil,
            timeout: .seconds(1)
        )
        #expect(result.exitCode == 2)
        #expect(result.standardError == "boom")
    }

    @Test("a throwing stub propagates its error")
    func throwingStub() async {
        struct Boom: Error {}
        let fake = FakeCommandRunner()
        await fake.stub(when: { _ in true }, throw: { Boom() })
        await #expect(throws: Boom.self) {
            try await fake.run(
                executable: URL(fileURLWithPath: "/x/jj"),
                arguments: ["status"],
                workingDirectory: nil,
                environment: nil,
                timeout: .seconds(1)
            )
        }
    }
}
